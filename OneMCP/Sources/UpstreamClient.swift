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
    
    // Session management for HTTP transport
    private var sessionId: String?
    private var sessionInvalidated = false
    
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
        
        // Create client (following official SDK pattern)
        let newClient = MCP.Client(
            name: "onemcp-client",
            version: "1.0.0"
        )
        
        // Create transport based on configuration
        let transport = try await createTransport()
        
        // Connect to server with retry logic using circuit breaker
        _ = try await circuitBreaker.execute {
            return try await newClient.connect(transport: transport)
        }
        
        // Update state after successful connection
        client = newClient
        isConnected = true
        retryCount = 0
        
        // Extract session ID if this is an HTTP transport
        // Note: Session ID is typically provided by the server in the initialize response
        // For now, we'll extract it when we implement proper session tracking
        
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
        
        // Send session termination request if we have a session ID and it's an HTTP transport
        await terminateSessionIfNeeded()
        
        // TODO: Find correct method to close client connection
        // client?.close() does not exist in this SDK version
        client = nil
        isConnected = false
        
        // Clear session state
        sessionId = nil
        sessionInvalidated = false
        
        // Clear cached capabilities
        tools.removeAll()
        resources.removeAll()
        prompts.removeAll()
    }
    
    /// Sends HTTP DELETE request to terminate the session explicitly
    /// According to MCP spec: "Clients that no longer need a particular session SHOULD send an HTTP DELETE 
    /// to the MCP endpoint with the Mcp-Session-Id header, to explicitly terminate the session."
    private func terminateSessionIfNeeded() async {
        // Only send termination for HTTP transports with active sessions
        guard let sessionId = sessionId,
              case .streamableHttp(let httpConfig) = config.config else {
            return
        }
        
        do {
            var request = URLRequest(url: httpConfig.url)
            request.httpMethod = "DELETE"
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let session = URLSession.shared
            let (_, response) = try await session.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                if 200..<300 ~= httpResponse.statusCode {
                    logger.info("Successfully terminated session \(sessionId) for \(config.name)")
                } else {
                    logger.warning("Session termination returned status \(httpResponse.statusCode) for \(config.name)")
                }
            }
        } catch {
            // Log but don't throw - session termination is best effort
            logger.warning("Failed to terminate session for \(config.name): \(error)")
        }
    }
    
    /// Handles session invalidation and attempts to reconnect with new session
    /// This method is called when receiving HTTP 404 with Mcp-Session-Id header
    private func handleSessionInvalidation() async throws {
        logger.warning("Session invalidated for \(config.name), attempting to reconnect with new session")
        
        // Mark session as invalidated
        sessionInvalidated = true
        sessionId = nil
        
        // Disconnect current connection
        await disconnect()
        
        // Clear circuit breaker state to allow immediate retry
        await circuitBreaker.reset()
        
        // Attempt to reconnect
        try await connect()
        
        logger.info("Successfully reconnected to \(config.name) with new session")
    }
    
    private func createTransport() async throws -> any Transport {
        switch config.config {
        case .stdio(let stdioConfig):
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
            // Use our custom LegacySSETransport for servers that use separate SSE and POST endpoints
            let transport = LegacySSETransport(
                sseEndpoint: sseConfig.url,
                logger: logger
            )
            return transport
            
        case .streamableHttp(let httpConfig):
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
            return 
        }
        
        do {
            // Load tools (most servers support this)
            do {
                let toolsResult = try await circuitBreaker.execute {
                    return try await client.listTools()
                }
                tools = toolsResult.tools
            } catch {
                logger.warning("Failed to load tools from \(config.name): \(error)")
                tools = []
            }
            
            // Load resources (try but don't fail if unsupported)
            do {
                let resourcesResult = try await circuitBreaker.execute {
                    return try await client.listResources()
                }
                resources = resourcesResult.resources
            } catch {
                resources = []
            }
            
            // Load prompts (try but don't fail if unsupported)
            do {
                let promptsResult = try await circuitBreaker.execute {
                    return try await client.listPrompts()
                }
                prompts = promptsResult.prompts
            } catch {
                prompts = []
            }
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
                prefixedName: "\(serverName)___\(resource.uri)",
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
        return try await executeWithSessionRetry {
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
        
        return try await executeWithSessionRetry {
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
        return try await executeWithSessionRetry {
            return try await client.getPrompt(name: name, arguments: mcpArguments)
        }
    }
    
    // MARK: - Session Recovery
    
    /// Executes an operation with automatic session retry on HTTP 404 errors
    private func executeWithSessionRetry<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await circuitBreaker.execute {
                return try await operation()
            }
        } catch {
            // Check if this is a session invalidation error (HTTP 404 with session ID)
            if isSessionInvalidationError(error) {
                logger.info("Detected session invalidation for \(config.name), attempting to recover")
                
                // Attempt session recovery
                try await handleSessionInvalidation()
                
                // Retry the operation once after session recovery
                return try await circuitBreaker.execute {
                    return try await operation()
                }
            } else {
                // Re-throw the original error for non-session related issues
                throw error
            }
        }
    }
    
    /// Checks if an error indicates session invalidation (HTTP 404 with Mcp-Session-Id)
    /// According to MCP spec: "When a client receives HTTP 404 in response to a request containing an Mcp-Session-Id, 
    /// it MUST start a new session by sending a new InitializeRequest without a session ID attached."
    private func isSessionInvalidationError(_ error: Swift.Error) -> Bool {
        // First check if this is a URLError that might contain HTTP status code information
        if let urlError = error as? URLError {
            // URLError.Code.fileDoesNotExist often corresponds to HTTP 404
            if urlError.code == .fileDoesNotExist {
                return true
            }
            
            // Check the underlying error for HTTP status code
            if let httpResponse = urlError.userInfo["NSURLErrorFailingURLResponseKey"] as? HTTPURLResponse {
                return httpResponse.statusCode == 404
            }
        }
        
        // Check if this is an MCPError that wraps an HTTP 404 error
        if let mcpError = error as? MCPError {
            let errorMessage = mcpError.localizedDescription
            return errorMessage.contains("404") || errorMessage.contains("Not Found")
        }
        
        // For other error types, check if the error description contains HTTP 404 indicators
        // This is a fallback for cases where the HTTP status code is embedded in the error message
        let errorDescription = error.localizedDescription
        return errorDescription.contains("404") || 
               errorDescription.contains("Not Found") ||
               errorDescription.range(of: "HTTP.*404", options: .regularExpression) != nil
    }
    
    // MARK: - Health Check
    
    func isHealthy() async -> Bool {
        return isConnected && client != nil && !sessionInvalidated
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