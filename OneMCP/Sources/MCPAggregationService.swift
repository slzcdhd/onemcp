import Foundation
import MCP
import Logging
import Network

protocol MCPAggregationServiceDelegate: AnyObject, Sendable {
    func serviceDidUpdateServerStatuses(_ statuses: [ServerStatus]) async
    func serviceDidUpdateCapabilities(_ capabilities: [AggregatedCapability]) async
    func serviceDidLogMessage(_ message: String, level: LogLevel) async
}

@MainActor
class MCPAggregationService: ObservableObject {
    weak var delegate: MCPAggregationServiceDelegate?
    
    private let logger = Logger(label: "com.onemcp.aggregationservice")
    private var mcpServer: MCP.Server?
    private var upstreamManager: UpstreamManager?
    private var serverTask: Task<Void, Never>?
    private var isRunning = false
    
    private var currentConfig: AppConfig?
    
    func start(with config: AppConfig) async throws {
        guard !isRunning else { return }
        
        currentConfig = config
        
        // Initialize server and upstream manager
        mcpServer = MCP.Server(
            name: "onemcp-aggregator",
            version: "1.0.0",
            capabilities: .init(
                prompts: .init(listChanged: true),
                resources: .init(subscribe: true, listChanged: true),
                tools: .init(listChanged: true)
            )
        )
        
        // Register method handlers
        await setupServerHandlers(mcpServer!)
        
        upstreamManager = UpstreamManager(delegate: self)
        
        // Start the server
        serverTask = Task {
            var retryCount = 0
            let maxRetries = 3
            let retryDelay: TimeInterval = 2.0
            
            while retryCount < maxRetries && !Task.isCancelled {
                do {
                    let transport = HTTPServerTransport(
                        host: config.server.host,
                        port: config.server.port,
                        enableCORS: config.server.enableCors,
                        aggregationService: self,
                        logger: logger
                    )
                    
                    try await transport.start(with: mcpServer!)
                    
                    // Keep the service running
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(1))
                    }
                    break
                    
                } catch {
                    retryCount += 1
                    logger.error("MCP server start attempt \(retryCount) failed: \(error)")
                    await delegate?.serviceDidLogMessage("MCP server start attempt \(retryCount) failed: \(error.localizedDescription)", level: .error)
                    
                    if retryCount < maxRetries {
                        try? await Task.sleep(for: .seconds(retryDelay))
                    } else {
                        // Final failure - attempt to restart with a different port if it's a port conflict
                        if error.localizedDescription.contains("Address already in use") {
                            await restartWithAlternativePort()
                        }
                        break
                    }
                }
            }
        }
        
        // Mark as running and continue setup
        isRunning = true
        
        // Connect to upstream servers
        await upstreamManager!.connectToServers(currentConfig!.upstreamServers)
        
        await delegate?.serviceDidLogMessage("MCP aggregation service started on \(currentConfig!.server.host):\(currentConfig!.server.port)", level: .info)
    }
    
    func connectNewServer(_ serverConfig: ServerConfig) async {
        guard isRunning else { 
            logger.warning("Cannot connect new server - service not running")
            return 
        }
        
        // Connect only the new server without affecting existing connections
        await upstreamManager?.connectSpecificServer(serverConfig)
        
        await delegate?.serviceDidLogMessage("Connected new server: \(serverConfig.name)", level: .info)
    }
    
    func disconnectSpecificServer(id: UUID) async {
        guard isRunning else { return }
        
        await upstreamManager?.disconnectSpecificServer(id: id)
    }
    
    func stop() async throws {
        guard isRunning else { return }
        
        isRunning = false
        
        // Gracefully stop all services
        if let upstream = upstreamManager {
            await upstream.shutdown()
        }
        
        // Cancel the server task
        serverTask?.cancel()
        serverTask = nil
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
        try await start(with: config)
    }
    
    private func restartWithAlternativePort() async {
        guard let config = currentConfig else { return }
        
        do {
            try await stop()
            try await Task.sleep(for: .seconds(1)) // Wait a bit before retrying
            
            let alternativePort = await findAvailablePort(startingFrom: config.server.port + 1)
            var updatedConfig = config
            updatedConfig.server.port = alternativePort
            
            try await start(with: updatedConfig)
            
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
    
    nonisolated func getTools() async -> [MCP.Tool] {
        guard let upstreamManager = await self.upstreamManager else {
            return []
        }
        return await upstreamManager.getAggregatedTools()
    }
    
    nonisolated func getResources() async -> [MCP.Resource] {
        guard let upstreamManager = await self.upstreamManager else {
            return []
        }
        return await upstreamManager.getAggregatedResources()
    }
    
    nonisolated func getPrompts() async -> [MCP.Prompt] {
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
        let result = try await upstreamManager.callTool(name: name, arguments: mcpArgs.toAnyDict())
        return (content: result.content, isError: result.isError ?? false)
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
}

// MARK: - UpstreamManagerDelegate

extension MCPAggregationService: UpstreamManagerDelegate {
    func upstreamManagerDidUpdateStatuses(_ statuses: [ServerStatus]) async {
        await delegate?.serviceDidUpdateServerStatuses(statuses)
    }
    
    func upstreamManagerDidUpdateCapabilities(_ capabilities: [AggregatedCapability]) async {
        await delegate?.serviceDidUpdateCapabilities(capabilities)
    }
    
    func upstreamManagerDidLogMessage(_ message: String, level: LogLevel) async {
        await delegate?.serviceDidLogMessage(message, level: level)
    }
}

// MARK: - HTTPServerTransport is now implemented in HTTPServerTransport.swift