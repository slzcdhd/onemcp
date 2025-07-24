import Foundation
import Network
import MCP
import Logging

/// HTTP transport implementation for serving downstream MCP clients
class HTTPServerTransport: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let enableCORS: Bool
    private let logger: Logger
    
    private var listener: NWListener?
    private var connections: Set<HTTPConnection> = []
    private var server: MCP.Server?
    private weak var aggregationService: MCPAggregationService?
    private let maxConnections: Int = 100
    private let performanceMonitor = PerformanceMonitor()
    
    init(host: String, port: Int, enableCORS: Bool = true, aggregationService: MCPAggregationService? = nil, logger: Logger) {
        self.host = host
        self.port = port
        self.enableCORS = enableCORS
        self.aggregationService = aggregationService
        self.logger = logger
    }
    
    func start(with server: MCP.Server) async throws {
        self.server = server
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        guard let port = NWEndpoint.Port(rawValue: UInt16(self.port)) else {
            throw HTTPTransportError.invalidPort(self.port)
        }
        
        listener = try NWListener(using: parameters, on: port)
        
        listener?.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.handleNewConnection(connection)
            }
        }
        
        // Use a simpler approach to wait for server startup
        try await withCheckedThrowingContinuation { continuation in
            let serverStatus = ServerStartupStatus()
            
            listener?.stateUpdateHandler = { [weak self] state in
                self?.logger.info("HTTP server state: \(state)")
                switch state {
                case .ready:
                    self?.logger.info("HTTP server listening on \(self?.host ?? "unknown"):\(self?.port ?? 0)")
                    serverStatus.complete(success: true, continuation: continuation)
                case .failed(let error):
                    self?.logger.error("HTTP server failed: \(error)")
                    serverStatus.complete(success: false, error: error, continuation: continuation)
                case .cancelled:
                    self?.logger.info("HTTP server cancelled")
                    serverStatus.complete(success: false, error: HTTPTransportError.serverCancelled, continuation: continuation)
                default:
                    break
                }
            }
            
            listener?.start(queue: .global(qos: .userInitiated))
        }
        
        // Start performance monitoring task only after successful startup
        Task {
            await startPerformanceMonitoring()
        }
    }
    
    func stop() async {
        listener?.cancel()
        
        // Close all connections
        for connection in connections {
            connection.close()
        }
        connections.removeAll()
        
        logger.info("HTTP server stopped")
    }
    
    private func startPerformanceMonitoring() async {
        while listener?.state != .cancelled {
            try? await Task.sleep(for: .seconds(60)) // Log metrics every minute
            
            await performanceMonitor.logMetrics()
            
            // Check for performance alerts
            let alerts = await performanceMonitor.checkAlerts()
            for alert in alerts {
                logger.log(level: alert.severity == .critical ? .critical : .warning, 
                          "Performance Alert [\(alert.severity.displayName)]: \(alert.message)")
            }
        }
    }
    
    private func handleNewConnection(_ nwConnection: NWConnection) async {
        // Check connection limit
        if connections.count >= maxConnections {
            logger.warning("Maximum connections reached (\(maxConnections)), rejecting new connection")
            nwConnection.cancel()
            return
        }
        
        let connection = HTTPConnection(
            nwConnection: nwConnection,
            server: server,
            aggregationService: aggregationService,
            enableCORS: enableCORS,
            logger: logger
        )
        
        connections.insert(connection)
        await performanceMonitor.connectionOpened()
        
        nwConnection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.connections.remove(connection)
                Task {
                    await self?.performanceMonitor.connectionClosed()
                }
            }
        }
        
        await connection.start(performanceMonitor: performanceMonitor)
    }
}

// MARK: - HTTP Connection Handler

class HTTPConnection: Hashable, @unchecked Sendable {
    private let nwConnection: NWConnection
    private let server: MCP.Server?
    private weak var aggregationService: MCPAggregationService?
    private let enableCORS: Bool
    private let logger: Logger
    private let id = UUID()
    private var buffer = Data()
    
    init(nwConnection: NWConnection, server: MCP.Server?, aggregationService: MCPAggregationService?, enableCORS: Bool, logger: Logger) {
        self.nwConnection = nwConnection
        self.server = server
        self.aggregationService = aggregationService
        self.enableCORS = enableCORS
        self.logger = logger
    }
    
    func start(performanceMonitor: PerformanceMonitor? = nil) async {
        nwConnection.start(queue: .global(qos: .userInitiated))
        await receiveData(performanceMonitor: performanceMonitor)
    }
    
    func close() {
        nwConnection.cancel()
    }
    
    private func receiveData(performanceMonitor: PerformanceMonitor? = nil) async {
        nwConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task {
                await self?.handleReceivedData(data, isComplete: isComplete, error: error, performanceMonitor: performanceMonitor)
            }
        }
    }
    
    private func handleReceivedData(_ data: Data?, isComplete: Bool, error: NWError?, performanceMonitor: PerformanceMonitor? = nil) async {
        if let error = error {
            logger.error("Connection error: \(error)")
            await performanceMonitor?.connectionError()
            return
        }
        
        guard let data = data, !data.isEmpty else {
            if isComplete {
                close()
            }
            return
        }
        
        // Append to buffer
        buffer.append(data)
        
        // Try to parse HTTP request from buffer
        if let (request, remainingData) = parseCompleteHTTPRequest(from: buffer) {
            // Update buffer with remaining data
            buffer = remainingData
            
            // Track request performance
            let startTime = await performanceMonitor?.requestStarted() ?? Date()
            
            // Handle the complete request
            await handleMCPRequest(request)
            await performanceMonitor?.requestCompleted(startTime: startTime, success: true)
        }
        
        // Continue receiving data
        if !isComplete {
            await receiveData(performanceMonitor: performanceMonitor)
        }
    }
    
    private func parseCompleteHTTPRequest(from data: Data) -> (HTTPRequest, Data)? {
        guard let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        // Look for the end of headers (double CRLF)
        guard let headerEndRange = string.range(of: "\r\n\r\n") else {
            // Headers not complete yet
            return nil
        }
        
        _ = headerEndRange.upperBound
        let headerString = String(string[..<headerEndRange.lowerBound])
        let lines = headerString.components(separatedBy: "\r\n")
        
        guard let requestLine = lines.first else {
            return nil
        }
        
        let components = requestLine.components(separatedBy: " ")
        guard components.count >= 3 else {
            return nil
        }
        
        let method = components[0]
        let path = components[1]
        
        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key.lowercased()] = value
            }
        }
        
        // Calculate body start position in data
        let headerEndByteIndex = headerString.utf8.count + 4 // +4 for "\r\n\r\n"
        
        // Check if we have the complete body
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let totalExpectedLength = headerEndByteIndex + contentLength
        
        guard data.count >= totalExpectedLength else {
            // Body not complete yet
            return nil
        }
        
        // Extract body
        let bodyData = data[headerEndByteIndex..<(headerEndByteIndex + contentLength)]
        
        // Calculate remaining data
        let remainingData = data.count > totalExpectedLength ? data[totalExpectedLength...] : Data()
        
        let request = HTTPRequest(method: method, path: path, headers: headers, body: Data(bodyData))
        return (request, Data(remainingData))
    }
    
    private func handleMCPRequest(_ request: HTTPRequest) async {
        // Handle CORS preflight
        if request.method == "OPTIONS" {
            await sendCORSResponse()
            return
        }
        
        switch request.method {
        case "POST":
            await handleStreamableHTTPPost(request)
        case "GET":
            await handleStreamableHTTPGet(request)
        default:
            await sendMethodNotAllowed()
        }
    }
    
    private func handleStreamableHTTPPost(_ request: HTTPRequest) async {
        // Parse JSON-RPC request
        guard let jsonRequest = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            await sendBadRequest()
            return
        }
        
        // Extract or create session ID  
        let sessionID = request.headers["mcp-session-id"] ?? UUID().uuidString
        
        logger.debug("Processing MCP POST request with session: \(sessionID)")
        
        // Check if this is a notification (no id field) or a request
        if jsonRequest["id"] != nil {
            // This is a request - call aggregation service and return response
            await handleMCPJSONRequest(jsonRequest, sessionID: sessionID)
        } else {
            // This is a notification - process but return 202 Accepted
            await sendAcceptedResponse()
        }
    }
    
    private func handleStreamableHTTPGet(_ request: HTTPRequest) async {
        // For GET requests, return 405 Method Not Allowed for now
        // Real implementation would support SSE streams for server-initiated messages
        await sendMethodNotAllowed()
    }
    
    private func handleMCPJSONRequest(_ jsonRequest: [String: Any], sessionID: String) async {
        guard let method = jsonRequest["method"] as? String else {
            await sendBadRequest()
            return
        }
        
        // Use aggregation service to handle the request
        do {
            let response: [String: Any]
            
            switch method {
            case "initialize":
                response = try await handleInitializeRequest(jsonRequest, sessionID: sessionID)
            case "tools/list":
                response = await handleListToolsRequest(jsonRequest)
            case "tools/call":
                response = await handleCallToolRequest(jsonRequest)
            case "resources/list":
                response = await handleListResourcesRequest(jsonRequest)
            case "resources/read":
                response = await handleReadResourceRequest(jsonRequest)
            case "prompts/list":
                response = await handleListPromptsRequest(jsonRequest)
            case "prompts/get":
                response = await handleGetPromptRequest(jsonRequest)
            default:
                response = [
                    "jsonrpc": "2.0",
                    "id": jsonRequest["id"] ?? NSNull(),
                    "error": [
                        "code": -32601,
                        "message": "Method '\(method)' not found"
                    ]
                ]
            }
            
            // Send response with session ID for initialize, regular response for others
            if method == "initialize" {
                await sendMCPInitializeResponse(response, sessionID: sessionID)
            } else {
                await sendJSONResponse(response)
            }
            
        } catch {
            logger.error("Error handling MCP request: \(error)")
            await sendJSONResponse([
                "jsonrpc": "2.0",
                "id": jsonRequest["id"] ?? NSNull(),
                "error": [
                    "code": -32603,
                    "message": "Internal error: \(error.localizedDescription)"
                ]
            ])
        }
    }
    
    // MARK: - MCP Method Handlers
    
    private func convertValueToJSON(_ value: MCP.Value?) -> Any? {
        guard let value = value else { return nil }
        
        switch value {
        case .null:
            return NSNull()
        case .bool(let b):
            return b
        case .int(let i):
            return i
        case .double(let d):
            return d
        case .string(let s):
            return s
        case .array(let arr):
            return arr.compactMap { convertValueToJSON($0) }
        case .object(let dict):
            var result: [String: Any] = [:]
            for (key, val) in dict {
                if let converted = convertValueToJSON(val) {
                    result[key] = converted
                }
            }
            return result
        case .data(let mimeType, let data):
            // Convert data to base64 string with mimeType info
            return [
                "type": "data",
                "mimeType": mimeType,
                "data": data.base64EncodedString()
            ]
        @unknown default:
            // Handle any future cases
            return String(describing: value)
        }
    }
    
    private func handleListToolsRequest(_ jsonRequest: [String: Any]) async -> [String: Any] {
        logger.info("Returning aggregated tools")
        
        if let aggregationService = aggregationService {
            let tools = await aggregationService.getAggregatedTools()
            logger.info("Returning \(tools.count) aggregated tools")
            
            // Convert MCP.Tool to JSON-safe dictionary
            let toolsArray = tools.map { tool -> [String: Any] in
                var toolDict: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description
                ]
                
                // Convert inputSchema from Value? to JSON
                if let schemaJSON = convertValueToJSON(tool.inputSchema) {
                    toolDict["inputSchema"] = schemaJSON
                }
                
                return toolDict
            }
            
            return [
                "jsonrpc": "2.0",
                "id": jsonRequest["id"] ?? NSNull(),
                "result": [
                    "tools": toolsArray
                ]
            ]
        } else {
            return [
                "jsonrpc": "2.0",
                "id": jsonRequest["id"] ?? NSNull(),
                "result": [
                    "tools": []
                ]
            ]
        }
    }
    
    private func handleCallToolRequest(_ jsonRequest: [String: Any]) async -> [String: Any] {
        guard let params = jsonRequest["params"] as? [String: Any],
              let toolName = params["name"] as? String else {
            return [
                "jsonrpc": "2.0",
                "id": jsonRequest["id"] ?? NSNull(),
                "error": [
                    "code": -32602,
                    "message": "Invalid params: missing tool name"
                ]
            ]
        }
        
        let arguments = params["arguments"] as? [String: Any]
        
        // Try to call tool through aggregation service
        if let aggregationService = aggregationService {
            do {
                let result = try await aggregationService.callTool(name: toolName, arguments: arguments)
                
                // Convert MCP.Tool.Content to JSON - simplified for now
                let contentArray = result.content.map { content -> [String: Any] in
                    switch content {
                    case .text(let text):
                        return ["type": "text", "text": text]
                    default:
                        // For now, convert all other types to text representation
                        return ["type": "text", "text": String(describing: content)]
                    }
                }
                
                return [
                    "jsonrpc": "2.0",
                    "id": jsonRequest["id"] ?? NSNull(),
                    "result": [
                        "content": contentArray,
                        "isError": result.isError
                    ]
                ]
            } catch {
                return [
                    "jsonrpc": "2.0",
                    "id": jsonRequest["id"] ?? NSNull(),
                    "error": [
                        "code": -32603,
                        "message": "Tool execution failed: \(error.localizedDescription)"
                    ]
                ]
            }
        } else {
            return [
                "jsonrpc": "2.0",
                "id": jsonRequest["id"] ?? NSNull(),
                "error": [
                    "code": -32601,
                    "message": "Tool '\(toolName)' not found"
                ]
            ]
        }
    }
    
    private func handleListResourcesRequest(_ jsonRequest: [String: Any]) async -> [String: Any] {
        logger.info("Returning aggregated resources")
        
        if let aggregationService = aggregationService {
            let resources = await aggregationService.getAggregatedResources()
            logger.info("Returning \(resources.count) aggregated resources")
            
            // Convert MCP.Resource to JSON-safe dictionary
            let resourcesArray = resources.map { resource -> [String: Any] in
                var resourceDict: [String: Any] = [
                    "uri": resource.uri,
                    "name": resource.name
                ]
                
                if let description = resource.description {
                    resourceDict["description"] = description
                }
                
                if let mimeType = resource.mimeType {
                    resourceDict["mimeType"] = mimeType
                }
                
                return resourceDict
            }
            
            return [
                "jsonrpc": "2.0",
                "id": jsonRequest["id"] ?? NSNull(),
                "result": [
                    "resources": resourcesArray
                ]
            ]
        } else {
            return [
                "jsonrpc": "2.0",
                "id": jsonRequest["id"] ?? NSNull(),
                "result": [
                    "resources": []
                ]
            ]
        }
    }
    
    private func handleReadResourceRequest(_ jsonRequest: [String: Any]) async -> [String: Any] {
        guard let params = jsonRequest["params"] as? [String: Any],
              let uri = params["uri"] as? String else {
            return [
                "jsonrpc": "2.0",
                "id": jsonRequest["id"] ?? NSNull(),
                "error": [
                    "code": -32602,
                    "message": "Invalid params: missing resource URI"
                ]
            ]
        }
        
        if let aggregationService = aggregationService {
            do {
                let contents = try await aggregationService.readResource(uri: uri)
                
                // Convert MCP.Resource.Content to JSON
                let contentsArray = contents.map { content -> [String: Any] in
                    // For now, convert all content to text representation
                    return ["type": "text", "text": String(describing: content)]
                }
                
                return [
                    "jsonrpc": "2.0",
                    "id": jsonRequest["id"] ?? NSNull(),
                    "result": [
                        "contents": contentsArray
                    ]
                ]
            } catch {
                return [
                    "jsonrpc": "2.0",
                    "id": jsonRequest["id"] ?? NSNull(),
                    "error": [
                        "code": -32603,
                        "message": "Resource reading failed: \(error.localizedDescription)"
                    ]
                ]
            }
        } else {
            return [
                "jsonrpc": "2.0",
                "id": jsonRequest["id"] ?? NSNull(),
                "error": [
                    "code": -32601,
                    "message": "Resource '\(uri)' not found"
                ]
            ]
        }
    }
    
    private func handleListPromptsRequest(_ jsonRequest: [String: Any]) async -> [String: Any] {
        logger.info("Returning aggregated prompts")
        
        if let aggregationService = aggregationService {
            let prompts = await aggregationService.getAggregatedPrompts()
            logger.info("Returning \(prompts.count) aggregated prompts")
            
            // Convert MCP.Prompt to JSON-safe dictionary
            let promptsArray = prompts.map { prompt -> [String: Any] in
                var promptDict: [String: Any] = [
                    "name": prompt.name
                ]
                
                if let description = prompt.description {
                    promptDict["description"] = description
                }
                
                if let arguments = prompt.arguments {
                    // Convert prompt arguments to JSON
                    let argumentsArray = arguments.map { arg -> [String: Any] in
                        var argDict: [String: Any] = ["name": arg.name]
                        if let description = arg.description {
                            argDict["description"] = description
                        }
                        if let required = arg.required {
                            argDict["required"] = required
                        }
                        return argDict
                    }
                    promptDict["arguments"] = argumentsArray
                }
                
                return promptDict
            }
            
            return [
                "jsonrpc": "2.0",
                "id": jsonRequest["id"] ?? NSNull(),
                "result": [
                    "prompts": promptsArray
                ]
            ]
        } else {
            return [
                "jsonrpc": "2.0",
                "id": jsonRequest["id"] ?? NSNull(),
                "result": [
                    "prompts": []
                ]
            ]
        }
    }
    
    private func handleGetPromptRequest(_ jsonRequest: [String: Any]) async -> [String: Any] {
        guard let params = jsonRequest["params"] as? [String: Any],
              let promptName = params["name"] as? String else {
            return [
                "jsonrpc": "2.0",
                "id": jsonRequest["id"] ?? NSNull(),
                "error": [
                    "code": -32602,
                    "message": "Invalid params: missing prompt name"
                ]
            ]
        }
        
        let arguments = params["arguments"] as? [String: Any]
        
        if let aggregationService = aggregationService {
            do {
                if let result = try await aggregationService.getPrompt(name: promptName, arguments: arguments) {
                    // Convert MCP.GetPrompt.Result to JSON
                    var responseDict: [String: Any] = [:]
                    
                    if let description = result.description {
                        responseDict["description"] = description
                    }
                    
                    // Convert prompt messages to JSON
                    let messagesArray = result.messages.map { message -> [String: Any] in
                        var messageDict: [String: Any] = [
                            "role": message.role.rawValue
                        ]
                        
                        // Convert message content to simple text representation for now
                        messageDict["content"] = String(describing: message.content)
                        
                        return messageDict
                    }
                    responseDict["messages"] = messagesArray
                    
                    return [
                        "jsonrpc": "2.0",
                        "id": jsonRequest["id"] ?? NSNull(),
                        "result": responseDict
                    ]
                } else {
                    return [
                        "jsonrpc": "2.0",
                        "id": jsonRequest["id"] ?? NSNull(),
                        "error": [
                            "code": -32601,
                            "message": "Prompt '\(promptName)' not found"
                        ]
                    ]
                }
            } catch {
                return [
                    "jsonrpc": "2.0",
                    "id": jsonRequest["id"] ?? NSNull(),
                    "error": [
                        "code": -32603,
                        "message": "Prompt retrieval failed: \(error.localizedDescription)"
                    ]
                ]
            }
        } else {
            return [
                "jsonrpc": "2.0",
                "id": jsonRequest["id"] ?? NSNull(),
                "error": [
                    "code": -32601,
                    "message": "Prompt '\(promptName)' not found"
                ]
            ]
        }
    }
    
    private func handleInitializeRequest(_ jsonRequest: [String: Any], sessionID: String) async throws -> [String: Any] {
        // Extract client info from params
        let params = jsonRequest["params"] as? [String: Any] ?? [:]
        let protocolVersion = params["protocolVersion"] as? String ?? "2024-11-05"
        let clientInfo = params["clientInfo"] as? [String: Any] ?? [:]
        let clientName = clientInfo["name"] as? String ?? "unknown"
        let clientVersion = clientInfo["version"] as? String ?? "1.0.0"
        
        logger.info("MCP initialize request from client: \(clientName) v\(clientVersion), protocol: \(protocolVersion)")
        
        return [
            "jsonrpc": "2.0",
            "id": jsonRequest["id"] ?? NSNull(),
            "result": [
                "protocolVersion": protocolVersion,
                "capabilities": [
                    "tools": ["listChanged": true],
                    "resources": [
                        "subscribe": true, 
                        "listChanged": true
                    ],
                    "prompts": ["listChanged": true],
                    "logging": [:]
                ],
                "serverInfo": [
                    "name": "OneMCP Aggregation Server",
                    "version": "1.0.0"
                ],
                "instructions": "This server aggregates capabilities from multiple upstream MCP servers. Tool names are prefixed with server names (e.g., 'playwright___browser_close')."
            ]
        ]
    }
    

    
    private func sendMCPInitializeResponse(_ response: [String: Any], sessionID: String) async {
        let headers: [String: String] = [
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "mcp-session-id, Content-Type, Authorization, Accept",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Mcp-Session-Id": sessionID  // Include session ID in response header
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: response) else {
            await sendBadRequest()
            return
        }
        
        await sendHTTPResponse(statusCode: 200, headers: headers, body: data)
    }
    
    private func sendAcceptedResponse() async {
        let headers: [String: String] = [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "mcp-session-id, Content-Type, Authorization, Accept",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS"
        ]
        
        await sendHTTPResponse(statusCode: 202, headers: headers, body: Data())
    }
    
    private func sendCORSResponse() async {
        var headers = [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Authorization",
            "Content-Length": "0"
        ]
        
        if !enableCORS {
            headers.removeValue(forKey: "Access-Control-Allow-Origin")
            headers.removeValue(forKey: "Access-Control-Allow-Methods")
            headers.removeValue(forKey: "Access-Control-Allow-Headers")
        }
        
        await sendHTTPResponse(statusCode: 200, headers: headers, body: Data())
    }
    
    private func sendBadRequest() async {
        await sendHTTPResponse(
            statusCode: 400,
            headers: ["Content-Type": "text/plain"],
            body: "Bad Request".data(using: .utf8) ?? Data()
        )
    }
    
    private func sendMethodNotAllowed() async {
        await sendHTTPResponse(
            statusCode: 405,
            headers: ["Content-Type": "text/plain"],
            body: "Method Not Allowed".data(using: .utf8) ?? Data()
        )
    }
    
    private func sendJSONResponse(_ json: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            await sendBadRequest()
            return
        }
        
        await sendRawJSONResponse(data)
    }
    
    private func sendRawJSONResponse(_ data: Data) async {
        var headers = [
            "Content-Type": "application/json",
            "Content-Length": "\(data.count)"
        ]
        
        if enableCORS {
            headers["Access-Control-Allow-Origin"] = "*"
        }
        
        await sendHTTPResponse(statusCode: 200, headers: headers, body: data)
    }
    
    private func sendHTTPResponse(statusCode: Int, headers: [String: String], body: Data) async {
        let statusLine = "HTTP/1.1 \(statusCode) \(HTTPStatus.phrase(for: statusCode))\r\n"
        var response = statusLine
        
        // Add Connection: close header to ensure connection is closed after response
        var finalHeaders = headers
        finalHeaders["Connection"] = "close"
        
        for (key, value) in finalHeaders {
            response += "\(key): \(value)\r\n"
        }
        
        response += "\r\n"
        
        var responseData = response.data(using: .utf8) ?? Data()
        responseData.append(body)
        
        nwConnection.send(content: responseData, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to send response: \(error)")
            } else {
                // Close connection after sending response for HTTP/1.1 with Connection: close
                self?.close()
            }
        })
    }
    
    // MARK: - Hashable
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: HTTPConnection, rhs: HTTPConnection) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Supporting Types

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}



enum HTTPTransportError: LocalizedError {
    case invalidPort(Int)
    case serverNotStarted
    case serverCancelled
    
    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Invalid port number: \(port)"
        case .serverNotStarted:
            return "HTTP server not started"
        case .serverCancelled:
            return "HTTP server was cancelled"
        }
    }
}

struct HTTPStatus {
    static func phrase(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}

private final class ServerStartupStatus: @unchecked Sendable {
    private var isCompleted = false
    private let lock = NSLock()
    
    func complete(success: Bool, error: Swift.Error? = nil, continuation: CheckedContinuation<Void, Swift.Error>) {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isCompleted else { return }
        isCompleted = true
        
        if success {
            continuation.resume()
        } else {
            continuation.resume(throwing: error ?? HTTPTransportError.serverNotStarted)
        }
    }
}