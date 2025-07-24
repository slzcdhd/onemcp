import Foundation
import MCP
import Logging

#if !os(Linux)
    import EventSource
#endif

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A custom transport for legacy SSE servers that use separate endpoints for SSE and POST
public actor LegacySSETransport: Transport {
    private let sseEndpoint: URL
    private let session: URLSession
    
    /// Session ID for communicating with the server
    public private(set) var sessionID: String?
    private var messageEndpoint: URL?
    
    public nonisolated let logger: Logger
    
    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    
    private var sseTask: Task<Void, Never>?
    #if !os(Linux)
    private var eventSource: EventSource?
    #endif
    
    public init(
        sseEndpoint: URL,
        configuration: URLSessionConfiguration = .default,
        logger: Logger? = nil
    ) {
        self.sseEndpoint = sseEndpoint
        self.session = URLSession(configuration: configuration)
        self.logger = logger ?? Logger(label: "mcp.transport.legacy-sse")
        
        // Create message stream
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }
    
    public func connect() async throws {
        guard !isConnected else { return }
        
        // Start SSE connection to get session and message endpoint
        sseTask = Task { await startSSEConnection() }
        
        // Wait for session to be established
        var attempts = 0
        while sessionID == nil && attempts < 100 { // Increased attempts
            try await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
        
        guard sessionID != nil, messageEndpoint != nil else {
            throw MCPError.internalError("Failed to establish session with legacy SSE server after \(attempts) attempts")
        }
        
        isConnected = true
    }
    
    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        
        // Cancel SSE task
        sseTask?.cancel()
        sseTask = nil
        
        #if !os(Linux)
        // Close EventSource
        if let eventSource = eventSource {
            await eventSource.close()
            self.eventSource = nil
        }
        #endif
        
        // Clean up message stream
        messageContinuation.finish()
        
        // Invalidate session
        session.invalidateAndCancel()
    }
    
    public func send(_ data: Data) async throws {
        guard isConnected else {
            throw MCPError.internalError("Transport not connected")
        }
        
        guard let messageEndpoint = messageEndpoint else {
            throw MCPError.internalError("Message endpoint not available")
        }
        
        var request = URLRequest(url: messageEndpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        
        let (responseData, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPError.internalError("Invalid HTTP response")
        }
        
        guard 200..<300 ~= httpResponse.statusCode else {
            let responseText = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw MCPError.internalError("HTTP error \(httpResponse.statusCode): \(responseText)")
        }
        
        // For legacy SSE, the response comes through the SSE stream, not the POST response
        // So we don't process the POST response data here
    }
    
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return messageStream
    }
    
    private func startSSEConnection() async {
        guard !isConnected || sessionID == nil else { 
            return 
        }
        
        #if os(Linux)
            logger.error("EventSource not supported on Linux")
            messageContinuation.yield(with: .failure(MCPError.internalError("EventSource not supported on Linux")))
        #else
            eventSource = EventSource(url: sseEndpoint)
            
            // Set up event handlers
            eventSource!.onMessage = { [weak self] event in
                Task {
                    await self?.handleSSEEvent(type: event.event, data: event.data)
                }
            }
            
            eventSource!.onError = { [weak self] error in
                Task {
                    if let error = error {
                        self?.logger.error("EventSource error: \(error)")
                        self?.messageContinuation.yield(with: .failure(error))
                    }
                }
            }
            
            eventSource!.onOpen = {
                // Connection opened - no logging needed
            }
            
            // EventSource starts automatically upon initialization
        #endif
    }
    
    private func handleSSEEvent(type: String?, data: String?) async {
        guard let eventType = type else { 
            return 
        }
        
        switch eventType {
        case "endpoint":
            // Parse endpoint data to extract session and message endpoint
            if let data = data {
                await parseEndpointData(data)
            }
            
        case "message":
            // This is an actual MCP message response
            if let data = data,
               let messageData = data.data(using: .utf8) {
                messageContinuation.yield(messageData)
            }
            
        default:
            // Unknown event type - ignore silently
            break
        }
    }
    
    private func parseEndpointData(_ data: String) async {
        // Expected format: /mcp/messages/?session_id=xxx
        if data.hasPrefix("/mcp/messages/?session_id=") {
            let sessionId = String(data.dropFirst("/mcp/messages/?session_id=".count))
            
            // Construct full message endpoint URL from SSE endpoint
            // If SSE endpoint is http://127.0.0.1:11235/mcp/sse
            // Message endpoint should be http://127.0.0.1:11235/mcp/messages/?session_id=xxx
            var components = URLComponents(url: sseEndpoint, resolvingAgainstBaseURL: false)!
            components.path = "/mcp/messages/"
            components.query = "session_id=\(sessionId)"
            
            guard let messageURL = components.url else {
                logger.error("Failed to construct message endpoint URL")
                return
            }
            
            self.sessionID = sessionId
            self.messageEndpoint = messageURL
            
            logger.info("Extracted session ID: \(sessionId)")
            logger.info("Message endpoint: \(messageURL)")
        }
    }
} 