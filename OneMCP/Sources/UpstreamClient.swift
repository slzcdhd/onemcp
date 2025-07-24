import Foundation
import MCP
import Logging

actor UpstreamClient {
    private let config: ServerConfig
    private let logger: Logger
    private var client: MCP.Client?
    private var isConnected = false
    private let circuitBreaker: CircuitBreaker
    private var retryCount = 0
    
    // Cached capabilities
    private var tools: [MCP.Tool] = []
    private var resources: [MCP.Resource] = []
    private var prompts: [MCP.Prompt] = []
    
    init(config: ServerConfig, logger: Logger) {
        self.config = config
        self.logger = logger
        self.circuitBreaker = CircuitBreaker()
    }
    
    func connect() async throws {
        guard !isConnected else { return }
        
        logger.info("Attempting to connect to \(config.name)")
        
        // Create client (following official SDK pattern)
        let newClient = MCP.Client(
            name: "onemcp-client",
            version: "1.0.0"
        )
        
        // Create transport based on configuration
        let transport = try await createTransport()
        
        // Connect to server with retry logic using circuit breaker
        let result = try await circuitBreaker.execute {
            return try await newClient.connect(transport: transport)
        }
        
        // Update state after successful connection
        client = newClient
        isConnected = true
        retryCount = 0
        
        logger.info("Connected to \(config.name), server capabilities: \(result.capabilities)")
        
        // Load capabilities with timeout - if this fails, we should still consider the connection successful
        do {
            // Add timeout for capability loading to prevent hanging
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.loadCapabilities()
                }
                
                group.addTask {
                    try await Task.sleep(for: .seconds(10)) // 10 second timeout
                    throw OneMCPError.networkError("Capability loading timeout")
                }
                
                try await group.next()
                group.cancelAll()
            }
        } catch {
            logger.warning("Failed to load capabilities from \(config.name), but connection is established: \(error)")
            // Don't throw here - the connection is still valid even if we can't load capabilities yet
        }
    }
    
    func disconnect() async {
        guard isConnected else { return }
        
        logger.info("Disconnecting from \(config.name)")
        
        // TODO: Find correct method to close client connection
        // client?.close() does not exist in this SDK version
        client = nil
        isConnected = false
        
        // Clear cached capabilities
        tools.removeAll()
        resources.removeAll()
        prompts.removeAll()
    }
    
    private func createTransport() async throws -> any Transport {
        logger.info("Creating transport for \(config.name) of type \(config.type)")
        
        switch config.config {
        case .stdio(let stdioConfig):
            logger.info("Creating stdio transport: \(stdioConfig.command) \(stdioConfig.arguments.joined(separator: " "))")
            // Use our custom subprocess transport for stdio servers
            let transport = SubprocessStdioTransport(
                command: stdioConfig.command,
                arguments: stdioConfig.arguments,
                environment: stdioConfig.environment ?? [:],
                workingDirectory: stdioConfig.workingDirectory,
                logger: logger
            )
            return transport
            
        case .sse(let sseConfig):
            logger.info("Creating Legacy SSE transport to: \(sseConfig.url)")
            // Use our custom LegacySSETransport for servers that use separate SSE and POST endpoints
            let transport = LegacySSETransport(
                sseEndpoint: sseConfig.url,
                logger: logger
            )
            return transport
            
        case .streamableHttp(let httpConfig):
            logger.info("Creating HTTP transport to: \(httpConfig.url)")
            // Use HTTPClientTransport for streamable HTTP
            let transport = HTTPClientTransport(
                endpoint: httpConfig.url,
                streaming: true,
                logger: logger
            )
            return transport
        }
    }
    
    private func loadCapabilities() async throws {
        guard let client = client, isConnected else { 
            logger.warning("Cannot load capabilities - client not connected")
            return 
        }
        
        logger.info("Starting to load capabilities from \(config.name)")
        
        do {
            // Load tools (most servers support this)
            logger.debug("Loading tools from \(config.name)")
            do {
                let toolsResult = try await circuitBreaker.execute {
                    return try await client.listTools()
                }
                tools = toolsResult.tools
                logger.info("Loaded \(tools.count) tools from \(config.name): \(tools.map { $0.name }.joined(separator: ", "))")
            } catch {
                logger.warning("Failed to load tools from \(config.name): \(error)")
                tools = []
            }
            
            // Load resources (try but don't fail if unsupported)
            logger.debug("Loading resources from \(config.name)")
            do {
                let resourcesResult = try await circuitBreaker.execute {
                    return try await client.listResources()
                }
                resources = resourcesResult.resources
                logger.info("Loaded \(resources.count) resources from \(config.name)")
            } catch {
                logger.debug("Resources not supported by \(config.name): \(error)")
                resources = []
            }
            
            // Load prompts (try but don't fail if unsupported)
            logger.debug("Loading prompts from \(config.name)")
            do {
                let promptsResult = try await circuitBreaker.execute {
                    return try await client.listPrompts()
                }
                prompts = promptsResult.prompts
                logger.info("Loaded \(prompts.count) prompts from \(config.name)")
            } catch {
                logger.debug("Prompts not supported by \(config.name): \(error)")
                prompts = []
            }
            
            logger.info("Successfully loaded capabilities from \(config.name) - Tools: \(tools.count), Resources: \(resources.count), Prompts: \(prompts.count)")
        }
    }
    
    // MARK: - Capability Access
    
    func getCapabilityCount() async -> CapabilityCount {
        return CapabilityCount(
            tools: tools.count,
            resources: resources.count,
            prompts: prompts.count
        )
    }
    
    func getAggregatedCapabilities(serverName: String) async -> [AggregatedCapability] {
        var capabilities: [AggregatedCapability] = []
        
        // Add tools
        for tool in tools {
            capabilities.append(AggregatedCapability(
                originalName: tool.name,
                prefixedName: "\(serverName)___\(tool.name)",
                serverId: config.id,
                serverName: serverName,
                type: .tool,
                description: tool.description
            ))
        }
        
        // Add resources
        for resource in resources {
            capabilities.append(AggregatedCapability(
                originalName: resource.uri,
                prefixedName: "\(serverName)://\(resource.uri)",
                serverId: config.id,
                serverName: serverName,
                type: .resource,
                description: resource.description
            ))
        }
        
        // Add prompts
        for prompt in prompts {
            capabilities.append(AggregatedCapability(
                originalName: prompt.name,
                prefixedName: "\(serverName)___\(prompt.name)",
                serverId: config.id,
                serverName: serverName,
                type: .prompt,
                description: prompt.description
            ))
        }
        
        return capabilities
    }
    
    // MARK: - MCP Method Implementations
    
    func getTools() async -> [MCP.Tool] {
        return tools
    }
    
    func callTool(name: String, arguments: [String: Any]?) async throws -> (content: [MCP.Tool.Content], isError: Bool?) {
        guard let client = client, isConnected else {
            throw OneMCPError.serviceError("Client not connected to \(config.name)")
        }
        
        let mcpArguments = arguments?.toMCPValue()
        return try await circuitBreaker.execute {
            return try await client.callTool(name: name, arguments: mcpArguments)
        }
    }
    
    func getResources() async -> [MCP.Resource] {
        return resources
    }
    
    func readResource(uri: String) async throws -> [MCP.Resource.Content] {
        guard let client = client, isConnected else {
            throw OneMCPError.serviceError("Client not connected to \(config.name)")
        }
        
        return try await circuitBreaker.execute {
            return try await client.readResource(uri: uri)
        }
    }
    
    func getPrompts() async -> [MCP.Prompt] {
        return prompts
    }
    
    func getPrompt(name: String, arguments: [String: Any]?) async throws -> (description: String?, messages: [MCP.Prompt.Message]) {
        guard let client = client, isConnected else {
            throw OneMCPError.serviceError("Client not connected to \(config.name)")
        }
        
        let mcpArguments = arguments?.toMCPValue()
        return try await circuitBreaker.execute {
            return try await client.getPrompt(name: name, arguments: mcpArguments)
        }
    }
    
    // MARK: - Health Check
    
    func isHealthy() async -> Bool {
        return isConnected && client != nil
    }
    
    // MARK: - Retry Logic
    
    private func connectWithRetry(transport: any Transport, client: MCP.Client) async throws -> MCP.Initialize.Result {
        let maxRetries = config.retryConfig?.maxRetries ?? 3
        let initialDelay = config.retryConfig?.initialDelay ?? 1.0
        let backoffMultiplier = config.retryConfig?.backoffMultiplier ?? 2.0
        
        var lastError: Swift.Error?
        
        for attempt in 0..<maxRetries {
            do {
                let result = try await client.connect(transport: transport)
                return result
            } catch let error {
                lastError = error
                
                logger.warning("Connection attempt \(attempt + 1)/\(maxRetries) failed for \(config.name): \(error.localizedDescription)")
                
                if attempt < maxRetries - 1 {
                    let delay = initialDelay * pow(backoffMultiplier, Double(attempt))
                    logger.info("Retrying connection to \(config.name) in \(delay) seconds")
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        }
        
        throw lastError ?? OneMCPError.networkError("Failed to connect to \(config.name) after \(maxRetries) attempts")
    }
    
    func getConnectionMetrics() -> ConnectionMetrics {
        return ConnectionMetrics(
            isConnected: isConnected,
            retryCount: retryCount,
            circuitBreakerState: Task { await circuitBreaker.getState() }
        )
    }
}

// MARK: - Connection Metrics

struct ConnectionMetrics {
    let isConnected: Bool
    let retryCount: Int
    let circuitBreakerState: Task<CircuitBreaker.State, Never>
}