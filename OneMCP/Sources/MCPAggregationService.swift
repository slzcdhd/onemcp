import Foundation
import MCP
import ServiceLifecycle
import Logging
import Network

protocol MCPAggregationServiceDelegate: AnyObject, Sendable {
    func serviceDidUpdateServerStatus(_ status: ServerStatus) async
    func serviceDidUpdateCapabilities(_ capabilities: [AggregatedCapability]) async
    func serviceDidLogMessage(_ message: String, level: LogLevel) async
}

@MainActor
class MCPAggregationService: ObservableObject {
    weak var delegate: MCPAggregationServiceDelegate?
    
    private let logger = Logger(label: "com.onemcp.aggregationservice")
    private var mcpServer: MCP.Server?
    private var upstreamManager: UpstreamManager?
    private var serviceGroup: ServiceGroup?
    private var isRunning = false
    
    private var currentConfig: AppConfig?
    
    func start(config: AppConfig) async throws {
        guard !isRunning else { return }
        
        currentConfig = config
        
        // For now, always use the configured port to avoid false positives
        // Port conflicts will be handled by the actual server startup
        logger.info("Using configured port: \(config.server.port)")
        currentConfig = config
        
        // Create upstream manager
        upstreamManager = UpstreamManager(delegate: self)
        
        // Create and configure MCP server
        mcpServer = await createMCPServer(config: currentConfig!)
        
        // Start services in background task to avoid blocking
        Task {
            do {
                let services: [any Service] = [
                    upstreamManager!,
                    MCPServerService(server: mcpServer!, config: currentConfig!, aggregationService: self)
                ]
                
                serviceGroup = ServiceGroup(
                    services: services,
                    gracefulShutdownSignals: [.sigterm, .sigint],
                    logger: logger
                )
                
                try await serviceGroup!.run()
            } catch {
                logger.error("ServiceGroup failed: \(error)")
                await delegate?.serviceDidLogMessage("MCP service group failed: \(error.localizedDescription)", level: .error)
                
                // Attempt to restart with a different port if it's a port conflict
                if error.localizedDescription.contains("Address already in use") {
                    logger.info("Port conflict detected, attempting to restart with alternative port...")
                    await restartWithAlternativePort()
                }
            }
        }
        
        // Mark as running and continue setup
        isRunning = true
        
        // Connect to upstream servers
        await upstreamManager!.connectToServers(currentConfig!.upstreamServers)
        
        await delegate?.serviceDidLogMessage("MCP aggregation service started on \(currentConfig!.server.host):\(currentConfig!.server.port)", level: .info)
    }
    
    func stop() async throws {
        guard isRunning else { return }
        
        isRunning = false
        
        // Gracefully stop all services
        if let upstream = upstreamManager {
            await upstream.gracefulShutdown()
        }
        
        // Note: ServiceGroup doesn't have a direct shutdown method in this version
        // We rely on service cancellation to clean up
        serviceGroup = nil
        upstreamManager = nil
        mcpServer = nil
        
        await delegate?.serviceDidLogMessage("MCP aggregation service stopped", level: .info)
    }
    
    func restart(config: AppConfig) async throws {
        if isRunning {
            try await stop()
            // Add a small delay to ensure clean shutdown
            try await Task.sleep(for: .milliseconds(500))
        }
        try await start(config: config)
    }
    
    private func restartWithAlternativePort() async {
        guard let config = currentConfig else { return }
        
        do {
            try await stop()
            try await Task.sleep(for: .seconds(1)) // Wait a bit before retrying
            
            let alternativePort = await findAvailablePort(startingFrom: config.server.port + 1)
            var updatedConfig = config
            updatedConfig.server.port = alternativePort
            
            try await start(config: updatedConfig)
            
            await delegate?.serviceDidLogMessage("Service restarted successfully on port \(alternativePort)", level: .info)
        } catch {
            logger.error("Failed to restart with alternative port: \(error)")
            await delegate?.serviceDidLogMessage("Failed to restart service: \(error.localizedDescription)", level: .error)
        }
    }
    
    private func checkPortAvailability(host: String, port: Int) async -> Bool {
        return await withCheckedContinuation { continuation in
            let parameters = NWParameters.tcp
            let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: UInt16(port))!)
            
            let completionBox = CompletionBox(continuation: continuation)
            
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // If listener starts successfully, port is available
                    listener?.cancel()
                    completionBox.complete(with: true)
                case .failed:
                    // If listener fails to start, port is likely occupied
                    completionBox.complete(with: false)
                default:
                    break
                }
            }
            
            listener?.start(queue: .global())
            
            // Timeout after 2 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                listener?.cancel()
                completionBox.complete(with: false)
            }
        }
    }
    
    private final class CompletionBox: @unchecked Sendable {
        private var hasCompleted = false
        private let lock = NSLock()
        private let continuation: CheckedContinuation<Bool, Never>
        
        init(continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }
        
        func complete(with result: Bool) {
            lock.lock()
            defer { lock.unlock() }
            
            if !hasCompleted {
                hasCompleted = true
                continuation.resume(returning: result)
            }
        }
    }
    
    private func findAvailablePort(startingFrom: Int) async -> Int {
        var port = startingFrom
        let maxPort = startingFrom + 100 // Try up to 100 ports
        
        while port < maxPort {
            let isAvailable = await checkPortAvailability(host: "localhost", port: port)
            if isAvailable {
                return port
            }
            port += 1
        }
        
        // Fallback to a random high port
        return Int.random(in: 8000...9999)
    }
    
    private func createMCPServer(config: AppConfig) async -> MCP.Server {
        let server = MCP.Server(
            name: "onemcp-aggregator",
            version: "1.0.0",
            capabilities: .init(
                prompts: .init(listChanged: true),
                resources: .init(subscribe: true, listChanged: true),
                tools: .init(listChanged: true)
            )
        )
        
        // Register method handlers
        await setupServerHandlers(server)
        
        return server
    }
    
    private func setupServerHandlers(_ server: MCP.Server) async {
        // List tools handler
        await server.withMethodHandler(MCP.ListTools.self) { [weak self] _ in
            guard let self = self else {
                throw MCPError.internalError("Service not available")
            }
            
            let tools = await self.upstreamManager?.getAggregatedTools() ?? []
            return MCP.ListTools.Result(tools: tools)
        }
        
        // Call tool handler
        await server.withMethodHandler(MCP.CallTool.self) { [weak self] params in
            guard let self = self else {
                throw MCPError.internalError("Service not available")
            }
            
            let result = try await self.upstreamManager?.callTool(name: params.name, arguments: params.arguments) ?? (content: [], isError: true)
            return MCP.CallTool.Result(content: result.content, isError: result.isError)
        }
        
        // List resources handler
        await server.withMethodHandler(MCP.ListResources.self) { [weak self] _ in
            guard let self = self else {
                throw MCPError.internalError("Service not available")
            }
            
            let resources = await self.upstreamManager?.getAggregatedResources() ?? []
            return MCP.ListResources.Result(resources: resources)
        }
        
        // Read resource handler
        await server.withMethodHandler(MCP.ReadResource.self) { [weak self] params in
            guard let self = self else {
                throw MCPError.internalError("Service not available")
            }
            
            let contents = try await self.upstreamManager?.readResource(uri: params.uri) ?? []
            return MCP.ReadResource.Result(contents: contents)
        }
        
        // List prompts handler
        await server.withMethodHandler(MCP.ListPrompts.self) { [weak self] _ in
            guard let self = self else {
                throw MCPError.internalError("Service not available")
            }
            
            let prompts = await self.upstreamManager?.getAggregatedPrompts() ?? []
            return MCP.ListPrompts.Result(prompts: prompts)
        }
        
        // Get prompt handler
        await server.withMethodHandler(MCP.GetPrompt.self) { [weak self] params in
            guard let self = self else {
                throw MCPError.internalError("Service not available")
            }
            
            if let result = try await self.upstreamManager?.getPrompt(name: params.name, arguments: params.arguments) {
                return result
            } else {
                return MCP.GetPrompt.Result(description: nil, messages: [])
            }
        }
    }
    
    // MARK: - Public API for HTTP Server
    
    nonisolated func getAggregatedTools() async -> [MCP.Tool] {
        guard let upstreamManager = await self.upstreamManager else {
            return []
        }
        return await upstreamManager.getAggregatedTools()
    }
    
    nonisolated func getAggregatedResources() async -> [MCP.Resource] {
        guard let upstreamManager = await self.upstreamManager else {
            return []
        }
        return await upstreamManager.getAggregatedResources()
    }
    
    nonisolated func getAggregatedPrompts() async -> [MCP.Prompt] {
        guard let upstreamManager = await self.upstreamManager else {
            return []
        }
        return await upstreamManager.getAggregatedPrompts()
    }
    
    nonisolated func callTool(name: String, arguments: [String: Any]?) async throws -> (content: [MCP.Tool.Content], isError: Bool) {
        guard let upstreamManager = await self.upstreamManager else {
            return (content: [], isError: true)
        }
        // Use MCPArguments wrapper for thread-safe argument passing
        let mcpArgs = MCPArguments(arguments)
        return try await upstreamManager.callTool(name: name, arguments: mcpArgs.toAnyDict())
    }
    
    nonisolated func readResource(uri: String) async throws -> [MCP.Resource.Content] {
        guard let upstreamManager = await self.upstreamManager else {
            return []
        }
        return try await upstreamManager.readResource(uri: uri)
    }
    
    nonisolated func getPrompt(name: String, arguments: [String: Any]?) async throws -> MCP.GetPrompt.Result? {
        guard let upstreamManager = await self.upstreamManager else {
            return nil
        }
        // Use MCPArguments wrapper for thread-safe argument passing
        let mcpArgs = MCPArguments(arguments)
        return try await upstreamManager.getPrompt(name: name, arguments: mcpArgs.toAnyDict())
    }
    
    func connectSpecificServer(_ serverConfig: ServerConfig) async {
        guard isRunning, let upstreamManager = upstreamManager else {
            logger.warning("Cannot connect server \(serverConfig.name) - service not running")
            return
        }
        
        logger.info("Connecting specific server: \(serverConfig.name)")
        await upstreamManager.connectSpecificServer(serverConfig)
    }
    
    func disconnectSpecificServer(id: UUID) async {
        guard isRunning, let upstreamManager = upstreamManager else {
            logger.warning("Cannot disconnect server with id \(id) - service not running")
            return
        }
        
        logger.info("Disconnecting specific server with id: \(id)")
        await upstreamManager.disconnectSpecificServer(id: id)
    }
}

// MARK: - UpstreamManagerDelegate

extension MCPAggregationService: UpstreamManagerDelegate {
    func upstreamManagerDidUpdateServerStatus(_ status: ServerStatus) async {
        await delegate?.serviceDidUpdateServerStatus(status)
    }
    
    func upstreamManagerDidUpdateCapabilities(_ capabilities: [AggregatedCapability]) async {
        await delegate?.serviceDidUpdateCapabilities(capabilities)
        
        // Notify MCP server of capability changes
        if mcpServer != nil {
            // Send notifications to connected clients about capability changes
            // Note: Notifications implementation depends on the specific MCP SDK version
        }
    }
    
    func upstreamManagerDidLogMessage(_ message: String, level: LogLevel) async {
        await delegate?.serviceDidLogMessage(message, level: level)
    }
}

// MARK: - MCPServerService

struct MCPServerService: Service {
    let server: MCP.Server
    let config: AppConfig
    weak var aggregationService: MCPAggregationService?
    private let logger = Logger(label: "com.onemcp.serverservice")
    private let maxRetries = 3
    private let retryDelay: TimeInterval = 2.0
    
    init(server: MCP.Server, config: AppConfig, aggregationService: MCPAggregationService?) {
        self.server = server
        self.config = config
        self.aggregationService = aggregationService
    }
    
    func run() async throws {
        logger.info("Starting MCP streamable HTTP server on \(config.server.host):\(config.server.port)")
        
        var retryCount = 0
        var lastError: Swift.Error?
        
        while retryCount < maxRetries {
            do {
                // Use the existing port availability check from the service
                let finalPort = config.server.port
                // For now, just use the configured port
                
                let transport = HTTPServerTransport(
                    host: config.server.host,
                    port: finalPort,
                    enableCORS: config.server.enableCors,
                    aggregationService: aggregationService,
                    logger: logger
                )
                
                try await transport.start(with: server)
                logger.info("MCP streamable HTTP server started successfully on port \(finalPort)")
                
                // Keep the service running indefinitely
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1))
                }
                break
                
            } catch {
                retryCount += 1
                lastError = error
                logger.warning("MCP server start attempt \(retryCount) failed: \(error)")
                
                if retryCount < maxRetries {
                    logger.info("Retrying in \(retryDelay) seconds...")
                    try await Task.sleep(for: .seconds(retryDelay))
                } else {
                    logger.error("Failed to start MCP server after \(maxRetries) attempts")
                    throw lastError ?? MCPError.internalError("Unknown error during server startup")
                }
            }
        }
    }
}

// MARK: - HTTPServerTransport is now implemented in HTTPServerTransport.swift