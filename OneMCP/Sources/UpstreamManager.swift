import Foundation
import MCP
import ServiceLifecycle
import Logging

protocol UpstreamManagerDelegate: AnyObject, Sendable {
    func upstreamManagerDidUpdateServerStatus(_ status: ServerStatus) async
    func upstreamManagerDidUpdateCapabilities(_ capabilities: [AggregatedCapability]) async
    func upstreamManagerDidLogMessage(_ message: String, level: LogLevel) async
}

actor UpstreamManager: Service {
    weak var delegate: UpstreamManagerDelegate?
    
    private let logger = Logger(label: "com.onemcp.upstreammanager")
    private var upstreamClients: [UUID: UpstreamClient] = [:]
    private var serverStatuses: [UUID: ServerStatus] = [:]
    private var aggregatedCapabilities: [AggregatedCapability] = []
    
    init(delegate: UpstreamManagerDelegate?) {
        self.delegate = delegate
    }
    
    func run() async throws {
        logger.info("Upstream manager started")
    }
    
    func gracefulShutdown() async {
        logger.info("Upstream manager shutting down")
        
        // Disconnect all clients
        for client in upstreamClients.values {
            await client.disconnect()
        }
        upstreamClients.removeAll()
        serverStatuses.removeAll()
        aggregatedCapabilities.removeAll()
    }
    
    func connectToServers(_ serverConfigs: [ServerConfig]) async {
        logger.info("connectToServers called with \(serverConfigs.count) configs, \(serverConfigs.filter(\.enabled).count) enabled")
        
        // Remove connections for servers that are no longer configured or disabled
        let configuredIds = Set(serverConfigs.filter(\.enabled).map(\.id))
        let currentIds = Set(upstreamClients.keys)
        
        let idsToRemove = currentIds.subtracting(configuredIds)
        logger.info("Will disconnect \(idsToRemove.count) servers")
        
        for removedId in idsToRemove {
            await disconnectServer(id: removedId)
        }
        
        // Connect to new or updated servers
        for config in serverConfigs.filter(\.enabled) {
            if upstreamClients[config.id] == nil {
                await connectServer(config: config)
            }
        }
        
        await updateAggregatedCapabilities()
    }
    
    func connectSpecificServer(_ serverConfig: ServerConfig) async {
        guard serverConfig.enabled else {
            logger.info("Server \(serverConfig.name) is disabled, not connecting")
            return
        }
        
        // If server is already connected, disconnect first
        if upstreamClients[serverConfig.id] != nil {
            logger.info("Server \(serverConfig.name) already connected, reconnecting...")
            await disconnectSpecificServer(id: serverConfig.id)
        }
        
        await connectServer(config: serverConfig)
        await updateAggregatedCapabilities()
    }
    
    func disconnectSpecificServer(id: UUID) async {
        await disconnectServer(id: id)
        await updateAggregatedCapabilities()
    }
    
    private func connectServer(config: ServerConfig) async {
        logger.info("Connecting to server: \(config.name)")
        
        // Update status to connecting
        let status = ServerStatus(id: config.id, name: config.name, status: .connecting)
        serverStatuses[config.id] = status
        await notifyStatusUpdate(status)
        
        do {
            let client = UpstreamClient(config: config, logger: logger)
            upstreamClients[config.id] = client
            
            try await client.connect()
            
            // Wait a moment for capabilities to load if possible
            try? await Task.sleep(for: .milliseconds(500))
            
            // Update status to connected
            let connectedStatus = ServerStatus(
                id: config.id,
                name: config.name,
                status: .connected,
                lastConnected: Date(),
                capabilities: await client.getCapabilityCount()
            )
            serverStatuses[config.id] = connectedStatus
            await notifyStatusUpdate(connectedStatus)
            
            logger.info("Successfully connected to server: \(config.name) with capabilities: tools=\(connectedStatus.capabilities.tools), resources=\(connectedStatus.capabilities.resources), prompts=\(connectedStatus.capabilities.prompts)")
            await logMessage("Successfully connected to server: \(config.name)", level: .info)
            
        } catch {
            logger.error("Failed to connect to server \(config.name): \(error)")
            
            // Update status to error
            let errorStatus = ServerStatus(
                id: config.id,
                name: config.name,
                status: .error,
                lastError: error.localizedDescription
            )
            serverStatuses[config.id] = errorStatus
            await notifyStatusUpdate(errorStatus)
            
            await logMessage("Failed to connect to server: \(config.name) - \(error.localizedDescription)", level: .error)
        }
    }
    
    private func disconnectServer(id: UUID) async {
        guard let client = upstreamClients[id] else { return }
        
        logger.info("Disconnecting server with id: \(id)")
        
        await client.disconnect()
        upstreamClients.removeValue(forKey: id)
        
        if let status = serverStatuses[id] {
            let disconnectedStatus = ServerStatus(
                id: status.id,
                name: status.name,
                status: .disconnected
            )
            serverStatuses[id] = disconnectedStatus
            logger.info("Server \(status.name) disconnected, notifying status update")
            await notifyStatusUpdate(disconnectedStatus)
        }
    }
    
    private func updateAggregatedCapabilities() async {
        var capabilities: [AggregatedCapability] = []
        
        for (id, client) in upstreamClients {
            guard let status = serverStatuses[id] else { continue }
            
            let clientCapabilities = await client.getAggregatedCapabilities(serverName: status.name)
            capabilities.append(contentsOf: clientCapabilities)
        }
        
        aggregatedCapabilities = capabilities
        await notifyCapabilitiesUpdate(capabilities)
    }
    
    // MARK: - MCP Method Implementations
    
    func getAggregatedTools() async -> [MCP.Tool] {
        var tools: [MCP.Tool] = []
        
        for (id, client) in upstreamClients {
            guard let status = serverStatuses[id], status.status == .connected else { continue }
            
            let clientTools = await client.getTools()
            for tool in clientTools {
                let prefixedTool = MCP.Tool(
                    name: "\(status.name)___\(tool.name)",
                    description: tool.description,
                    inputSchema: tool.inputSchema
                )
                tools.append(prefixedTool)
            }
        }
        
        return tools
    }
    
    func callTool(name: String, arguments: [String: Any]?) async throws -> (content: [MCP.Tool.Content], isError: Bool) {
        let (serverName, toolName) = parsePrefix(name)
        
        guard let serverId = serverStatuses.first(where: { $0.value.name == serverName })?.key,
              let client = upstreamClients[serverId] else {
            throw MCPError.invalidRequest("Server not found: \(serverName)")
        }
        
        let mcpArgs = MCPArguments(arguments)
        let result = try await client.callTool(name: toolName, arguments: mcpArgs.toAnyDict())
        
        return (content: result.content, isError: result.isError ?? false)
    }
    
    func getAggregatedResources() async -> [MCP.Resource] {
        var resources: [MCP.Resource] = []
        
        for (id, client) in upstreamClients {
            guard let status = serverStatuses[id], status.status == .connected else { continue }
            
            let clientResources = await client.getResources()
            for resource in clientResources {
                let prefixedResource = MCP.Resource(
                    name: resource.name,
                    uri: "\(status.name)://\(resource.uri)",
                    description: resource.description,
                    mimeType: resource.mimeType
                )
                resources.append(prefixedResource)
            }
        }
        
        return resources
    }
    
    func readResource(uri: String) async throws -> [MCP.Resource.Content] {
        let (serverName, resourceUri) = parseResourcePrefix(uri)
        
        guard let serverId = serverStatuses.first(where: { $0.value.name == serverName })?.key,
              let client = upstreamClients[serverId] else {
            throw MCPError.invalidRequest("Server not found: \(serverName)")
        }
        
        let result = try await client.readResource(uri: resourceUri)
        return result
    }
    
    func getAggregatedPrompts() async -> [MCP.Prompt] {
        var prompts: [MCP.Prompt] = []
        
        for (id, client) in upstreamClients {
            guard let status = serverStatuses[id], status.status == .connected else { continue }
            
            let clientPrompts = await client.getPrompts()
            for prompt in clientPrompts {
                let prefixedPrompt = MCP.Prompt(
                    name: "\(status.name)___\(prompt.name)",
                    description: prompt.description,
                    arguments: prompt.arguments
                )
                prompts.append(prefixedPrompt)
            }
        }
        
        return prompts
    }
    
    func getPrompt(name: String, arguments: [String: Any]?) async throws -> MCP.GetPrompt.Result? {
        let (serverName, promptName) = parsePrefix(name)
        
        guard let serverId = serverStatuses.first(where: { $0.value.name == serverName })?.key,
              let client = upstreamClients[serverId] else {
            throw MCPError.invalidRequest("Server not found: \(serverName)")
        }
        
        let mcpArgs = MCPArguments(arguments)
        let result = try await client.getPrompt(name: promptName, arguments: mcpArgs.toAnyDict())
        
        // Convert to MCP.GetPrompt.Result
        return MCP.GetPrompt.Result(
            description: result.description,
            messages: result.messages
        )
    }
    
    // MARK: - Helper Methods
    
    private func parsePrefix(_ name: String) -> (serverName: String, itemName: String) {
        let components = name.components(separatedBy: "___")
        if components.count >= 2 {
            let serverName = components[0]
            let itemName = components[1...].joined(separator: "___")
            return (serverName, itemName)
        }
        return ("", name)
    }
    
    private func parseResourcePrefix(_ uri: String) -> (serverName: String, resourceUri: String) {
        if let colonIndex = uri.firstIndex(of: ":"),
           let slashIndex = uri.range(of: "://") {
            let serverName = String(uri[..<colonIndex])
            let resourceUri = String(uri[slashIndex.upperBound...])
            return (serverName, resourceUri)
        }
        return ("", uri)
    }
    
    private func notifyStatusUpdate(_ status: ServerStatus) async {
        if let currentDelegate = delegate {
            await currentDelegate.upstreamManagerDidUpdateServerStatus(status)
        }
    }
    
    private func notifyCapabilitiesUpdate(_ capabilities: [AggregatedCapability]) async {
        if let currentDelegate = delegate {
            await currentDelegate.upstreamManagerDidUpdateCapabilities(capabilities)
        }
    }
    
    private func logMessage(_ message: String, level: LogLevel) async {
        if let currentDelegate = delegate {
            await currentDelegate.upstreamManagerDidLogMessage(message, level: level)
        }
    }
}