import Foundation
import MCP
import Logging

protocol UpstreamManagerDelegate: AnyObject, Sendable {
    func upstreamManagerDidUpdateStatuses(_ statuses: [ServerStatus]) async
    func upstreamManagerDidUpdateCapabilities(_ capabilities: [AggregatedCapability]) async
    func upstreamManagerDidLogMessage(_ message: String, level: LogLevel) async
}

actor UpstreamManager {
    weak var delegate: UpstreamManagerDelegate?
    
    private let logger = Logger(label: "com.onemcp.upstreammanager")
    private var upstreamClients: [UUID: UpstreamClient] = [:]
    private var serverStatuses: [UUID: ServerStatus] = [:]
    private var aggregatedCapabilities: [AggregatedCapability] = []
    
    init(delegate: UpstreamManagerDelegate?) {
        self.delegate = delegate
    }
    
    func shutdown() async {
        // Disconnect all clients
        for client in upstreamClients.values {
            await client.disconnect()
        }
        upstreamClients.removeAll()
        serverStatuses.removeAll()
        aggregatedCapabilities.removeAll()
    }
    
    func connectToServers(_ serverConfigs: [ServerConfig]) async {
        // First, create or update status for all servers (including disabled ones)
        for config in serverConfigs {
            if serverStatuses[config.id] == nil {
                // Create initial status for new servers
                let status = ServerStatus(
                    id: config.id,
                    name: config.name,
                    status: config.enabled ? .disconnected : .disconnected,
                    lastError: nil,
                    capabilities: CapabilityCount(tools: 0, resources: 0, prompts: 0)
                )
                serverStatuses[config.id] = status
            }
        }
        
        // Remove connections for servers that are no longer configured
        let configuredIds = Set(serverConfigs.map(\.id))
        let currentIds = Set(upstreamClients.keys)
        let statusIds = Set(serverStatuses.keys)
        let idsToRemove = currentIds.subtracting(configuredIds)
        let statusIdsToRemove = statusIds.subtracting(configuredIds)
        
        for id in idsToRemove {
            if let client = upstreamClients[id] {
                await client.disconnect()
                upstreamClients.removeValue(forKey: id)
            }
        }
        
        // Remove status for servers that are no longer configured
        for id in statusIdsToRemove {
            serverStatuses.removeValue(forKey: id)
        }
        
        // Connect to enabled servers only
        let enabledIds = Set(serverConfigs.filter(\.enabled).map(\.id))
        let disabledIds = configuredIds.subtracting(enabledIds)
        
        // Disconnect disabled servers
        for id in disabledIds {
            if let client = upstreamClients[id] {
                await client.disconnect()
                upstreamClients.removeValue(forKey: id)
                // Update status to disconnected
                if var status = serverStatuses[id] {
                    status.status = .disconnected
                    status.lastError = nil
                    serverStatuses[id] = status
                }
            }
        }
        
        // Connect to enabled servers
        for config in serverConfigs where config.enabled {
            if upstreamClients[config.id] == nil {
                await connectSpecificServer(config)
            }
        }
        
        // Notify delegate of all status updates
        await delegate?.upstreamManagerDidUpdateStatuses(Array(serverStatuses.values))
        
        // Update aggregated capabilities
        await updateAggregatedCapabilities()
    }
    
    func connectSpecificServer(_ serverConfig: ServerConfig) async {
        let clientLogger = Logger(label: "com.onemcp.upstreamclient.\(serverConfig.name)")
        let client = UpstreamClient(config: serverConfig, logger: clientLogger)
        
        upstreamClients[serverConfig.id] = client
        
        // Update status to connecting
        let status = ServerStatus(
            id: serverConfig.id,
            name: serverConfig.name,
            status: .connecting,
            lastError: nil,
            capabilities: CapabilityCount(tools: 0, resources: 0, prompts: 0)
        )
        serverStatuses[serverConfig.id] = status
        await delegate?.upstreamManagerDidUpdateStatuses(Array(serverStatuses.values))
        
        // Connect to the server
        do {
            try await client.connect()
            
            // Update status to connected
            let connectedStatus = ServerStatus(
                id: serverConfig.id,
                name: serverConfig.name,
                status: .connected,
                lastError: nil,
                capabilities: CapabilityCount(
                    tools: await client.getTools().count,
                    resources: await client.getResources().count,
                    prompts: await client.getPrompts().count
                )
            )
            serverStatuses[serverConfig.id] = connectedStatus
            await delegate?.upstreamManagerDidUpdateStatuses(Array(serverStatuses.values))
            
            // Update aggregated capabilities
            await updateAggregatedCapabilities()
            
        } catch {
            // Update status to error
            let errorStatus = ServerStatus(
                id: serverConfig.id,
                name: serverConfig.name,
                status: .error,
                lastError: error.localizedDescription,
                capabilities: CapabilityCount(tools: 0, resources: 0, prompts: 0)
            )
            serverStatuses[serverConfig.id] = errorStatus
            await delegate?.upstreamManagerDidUpdateStatuses(Array(serverStatuses.values))
            
            // Log error
            logger.error("Failed to connect to \(serverConfig.name): \(error)")
            await delegate?.upstreamManagerDidLogMessage("Failed to connect to \(serverConfig.name): \(error.localizedDescription)", level: .error)
        }
    }
    
    func disconnectSpecificServer(id: UUID) async {
        if let client = upstreamClients[id] {
            await client.disconnect()
            upstreamClients.removeValue(forKey: id)
            serverStatuses.removeValue(forKey: id)
            await delegate?.upstreamManagerDidUpdateStatuses(Array(serverStatuses.values))
            await updateAggregatedCapabilities()
        }
    }
    
    private func updateAggregatedCapabilities() async {
        var toolsByName: [String: AggregatedCapability] = [:]
        var resourcesByUri: [String: AggregatedCapability] = [:]
        var promptsByName: [String: AggregatedCapability] = [:]
        
        for (serverId, client) in upstreamClients {
            guard let serverName = serverStatuses[serverId]?.name else { continue }
            
            // Aggregate tools
            let tools = await client.getTools()
            for tool in tools {
                let prefixedName = "\(serverName)___\(tool.name)"
                toolsByName[prefixedName] = AggregatedCapability(
                    originalName: tool.name,
                    prefixedName: prefixedName,
                    serverId: serverId,
                    serverName: serverName,
                    type: .tool,
                    description: tool.description
                )
            }
            
            // Aggregate resources
            let resources = await client.getResources()
            for resource in resources {
                let prefixedUri = "\(serverName)___\(resource.uri)"
                resourcesByUri[prefixedUri] = AggregatedCapability(
                    originalName: resource.uri,
                    prefixedName: prefixedUri,
                    serverId: serverId,
                    serverName: serverName,
                    type: .resource,
                    description: resource.description
                )
            }
            
            // Aggregate prompts
            let prompts = await client.getPrompts()
            for prompt in prompts {
                let prefixedName = "\(serverName)___\(prompt.name)"
                promptsByName[prefixedName] = AggregatedCapability(
                    originalName: prompt.name,
                    prefixedName: prefixedName,
                    serverId: serverId,
                    serverName: serverName,
                    type: .prompt,
                    description: prompt.description
                )
            }
        }
        
        aggregatedCapabilities = Array(toolsByName.values) + 
                               Array(resourcesByUri.values) + 
                               Array(promptsByName.values)
        
        await delegate?.upstreamManagerDidUpdateCapabilities(aggregatedCapabilities)
    }
    
    // MARK: - Capability Access
    
    func getAggregatedTools() async -> [MCP.Tool] {
        var tools: [MCP.Tool] = []
        
        for (serverId, client) in upstreamClients {
            guard let serverName = serverStatuses[serverId]?.name else { continue }
            
            let clientTools = await client.getTools()
            for tool in clientTools {
                let prefixedName = "\(serverName)___\(tool.name)"
                let modifiedTool = MCP.Tool(
                    name: prefixedName,
                    description: tool.description,
                    inputSchema: tool.inputSchema
                )
                tools.append(modifiedTool)
            }
        }
        
        return tools
    }
    
    func getAggregatedResources() async -> [MCP.Resource] {
        var resources: [MCP.Resource] = []
        
        for (serverId, client) in upstreamClients {
            guard let serverName = serverStatuses[serverId]?.name else { continue }
            
            let clientResources = await client.getResources()
            for resource in clientResources {
                var modifiedResource = resource
                modifiedResource.uri = "\(serverName)___\(resource.uri)"
                resources.append(modifiedResource)
            }
        }
        
        return resources
    }
    
    func getAggregatedPrompts() async -> [MCP.Prompt] {
        var prompts: [MCP.Prompt] = []
        
        for (serverId, client) in upstreamClients {
            guard let serverName = serverStatuses[serverId]?.name else { continue }
            
            let clientPrompts = await client.getPrompts()
            for prompt in clientPrompts {
                let prefixedName = "\(serverName)___\(prompt.name)"
                let modifiedPrompt = MCP.Prompt(
                    name: prefixedName,
                    description: prompt.description,
                    arguments: prompt.arguments
                )
                prompts.append(modifiedPrompt)
            }
        }
        
        return prompts
    }
    
    // MARK: - Method Calls
    
    func callTool(name: String, arguments: [String: Any]?) async throws -> (content: [MCP.Tool.Content], isError: Bool?) {
        let (serverName, toolName) = parsePrefix(name)
        
        guard let serverId = serverStatuses.first(where: { $0.value.name == serverName })?.key,
              let client = upstreamClients[serverId] else {
            throw MCPError.invalidRequest("Tool not found: \(name)")
        }
        
        do {
            // Use MCPArguments wrapper for thread-safe argument passing
            let mcpArgs = MCPArguments(arguments)
            return try await client.callTool(name: toolName, arguments: mcpArgs.toAnyDict())
        } catch {
            // Log the error for debugging
            logger.error("Tool call failed for \(serverName): \(error)")
            await delegate?.upstreamManagerDidLogMessage("Tool call failed for \(serverName): \(error.localizedDescription)", level: .error)
            throw error
        }
    }
    
    func readResource(uri: String) async throws -> [MCP.Resource.Content] {
        let (serverName, resourceUri) = parseResourcePrefix(uri)
        
        guard let serverId = serverStatuses.first(where: { $0.value.name == serverName })?.key,
              let client = upstreamClients[serverId] else {
            throw MCPError.invalidRequest("Resource not found: \(uri)")
        }
        
        do {
            return try await client.readResource(uri: resourceUri)
        } catch {
            // Log the error for debugging
            logger.error("Resource read failed for \(serverName): \(error)")
            await delegate?.upstreamManagerDidLogMessage("Resource read failed for \(serverName): \(error.localizedDescription)", level: .error)
            throw error
        }
    }
    
    func getPrompt(name: String, arguments: [String: Any]?) async throws -> MCP.GetPrompt.Result {
        let (serverName, promptName) = parsePrefix(name)
        
        guard let serverId = serverStatuses.first(where: { $0.value.name == serverName })?.key,
              let client = upstreamClients[serverId] else {
            throw MCPError.invalidRequest("Prompt not found: \(name)")
        }
        
        do {
            // Use MCPArguments wrapper for thread-safe argument passing
            let mcpArgs = MCPArguments(arguments)
            let result = try await client.getPrompt(name: promptName, arguments: mcpArgs.toAnyDict())
            return MCP.GetPrompt.Result(description: result.description, messages: result.messages)
        } catch {
            // Log the error for debugging
            logger.error("Prompt get failed for \(serverName): \(error)")
            await delegate?.upstreamManagerDidLogMessage("Prompt get failed for \(serverName): \(error.localizedDescription)", level: .error)
            throw error
        }
    }
    
    // MARK: - Helper Methods
    
    private func parsePrefix(_ name: String) -> (serverName: String, itemName: String) {
        let components = name.components(separatedBy: "___")
        if components.count >= 2 {
            let serverName = components[0]
            let itemName = components.dropFirst().joined(separator: "___")
            return (serverName, itemName)
        }
        return ("", name)
    }
    
    private func parseResourcePrefix(_ uri: String) -> (serverName: String, resourceUri: String) {
        let components = uri.components(separatedBy: "___")
        if components.count >= 2 {
            let serverName = components[0]
            let resourceUri = components.dropFirst().joined(separator: "___")
            return (serverName, resourceUri)
        }
        return ("", uri)
    }
} 