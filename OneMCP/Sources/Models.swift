import Foundation
import SwiftUI

// MARK: - Configuration Models

struct ServerConfig: Codable, Identifiable {
    let id: UUID
    var name: String
    var type: ServerType
    var enabled: Bool
    var config: ServerTransportConfig
    var retryConfig: RetryConfig?
    
    init(id: UUID = UUID(), name: String, type: ServerType, enabled: Bool = true, config: ServerTransportConfig, retryConfig: RetryConfig? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.enabled = enabled
        self.config = config
        self.retryConfig = retryConfig
    }
}

enum ServerType: String, Codable, CaseIterable {
    case stdio = "stdio"
    case sse = "sse"
    case streamableHttp = "streamable-http"
    
    var displayName: String {
        switch self {
        case .stdio: return "Standard I/O"
        case .sse: return "Server-Sent Events"
        case .streamableHttp: return "Streamable HTTP"
        }
    }
    
    var iconName: String {
        switch self {
        case .stdio: return "command"
        case .sse: return "globe"
        case .streamableHttp: return "network"
        }
    }
}

enum ServerTransportConfig: Codable {
    case stdio(StdioConfig)
    case sse(SseConfig)
    case streamableHttp(HttpConfig)
}

struct StdioConfig: Codable {
    var command: String
    var arguments: [String]
    var environment: [String: String]?
    var workingDirectory: String?
    
    init(command: String, arguments: [String] = [], environment: [String: String]? = nil, workingDirectory: String? = nil) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

struct SseConfig: Codable {
    var url: URL
    var headers: [String: String]?
    
    init(url: URL, headers: [String: String]? = nil) {
        self.url = url
        self.headers = headers
    }
}

struct HttpConfig: Codable {
    var url: URL
    var headers: [String: String]?
    
    init(url: URL, headers: [String: String]? = nil) {
        self.url = url
        self.headers = headers
    }
}

struct RetryConfig: Codable {
    var maxRetries: Int = 3
    var initialDelay: TimeInterval = 1.0
    var maxDelay: TimeInterval = 30.0
    var backoffMultiplier: Double = 2.0
}

// MARK: - Application Configuration

struct AppConfig: Codable {
    var server: ServerSettings
    var ui: UISettings
    var logging: LoggingSettings
    var upstreamServers: [ServerConfig]
    
    init(server: ServerSettings = ServerSettings(), ui: UISettings = UISettings(), logging: LoggingSettings = LoggingSettings(), upstreamServers: [ServerConfig] = []) {
        self.server = server
        self.ui = ui
        self.logging = logging
        self.upstreamServers = upstreamServers
    }
}

struct ServerSettings: Codable, Equatable {
    var port: Int = 3000
    var host: String = "localhost"
    var enableCors: Bool = true
}

struct UISettings: Codable, Equatable {
    var startMinimized: Bool = false
    var showInDock: Bool = true
    var enableNotifications: Bool = true
    var theme: AppTheme = .system
}

struct LoggingSettings: Codable, Equatable {
    var level: LogLevel = .info
    var enableFileLogging: Bool = true
    var maxLogSize: Int = 10_000_000 // 10MB
}

enum AppTheme: String, Codable, CaseIterable {
    case light, dark, system
    
    var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }
}

enum LogLevel: String, Codable, CaseIterable {
    case debug, info, warn, error
    
    var displayName: String {
        self.rawValue.capitalized
    }
}

// MARK: - Runtime Models

struct ServerStatus: Identifiable {
    let id: UUID
    var name: String
    var status: ConnectionStatus
    var lastConnected: Date?
    var lastError: String?
    var capabilities: CapabilityCount
    var metrics: ServerMetrics
    
    init(id: UUID, name: String, status: ConnectionStatus = .disconnected, lastConnected: Date? = nil, lastError: String? = nil, capabilities: CapabilityCount = CapabilityCount(), metrics: ServerMetrics = ServerMetrics()) {
        self.id = id
        self.name = name
        self.status = status
        self.lastConnected = lastConnected
        self.lastError = lastError
        self.capabilities = capabilities
        self.metrics = metrics
    }
}

enum ConnectionStatus: String, CaseIterable {
    case connected = "connected"
    case connecting = "connecting"
    case disconnected = "disconnected"
    case error = "error"
    
    var color: Color {
        switch self {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        case .error: return .red
        }
    }
    
    var displayName: String {
        self.rawValue.capitalized
    }
}

struct CapabilityCount: Codable {
    var tools: Int = 0
    var resources: Int = 0
    var prompts: Int = 0
    
    var total: Int { tools + resources + prompts }
}

struct ServerMetrics: Codable {
    var requestCount: Int = 0
    var errorCount: Int = 0
    var averageResponseTime: TimeInterval = 0
    var uptime: TimeInterval = 0
}

// MARK: - Aggregated Capability Models

struct AggregatedCapability: Identifiable, Codable {
    let id: UUID
    var originalName: String
    var prefixedName: String
    var serverId: UUID
    var serverName: String
    var type: CapabilityType
    var description: String?
    
    init(originalName: String, prefixedName: String, serverId: UUID, serverName: String, type: CapabilityType, description: String? = nil) {
        self.id = UUID()
        self.originalName = originalName
        self.prefixedName = prefixedName
        self.serverId = serverId
        self.serverName = serverName
        self.type = type
        self.description = description
    }
}

enum CapabilityType: String, Codable, CaseIterable {
    case tool = "tool"
    case resource = "resource"
    case prompt = "prompt"
    
    var icon: String {
        switch self {
        case .tool: return "wrench.and.screwdriver"
        case .resource: return "doc.text"
        case .prompt: return "text.bubble"
        }
    }
    
    var displayName: String {
        self.rawValue.capitalized
    }
}

// MARK: - MCP Protocol Models

struct McpTool: Codable {
    var name: String
    var description: String?
    var inputSchema: [String: Any]
    
    private enum CodingKeys: String, CodingKey {
        case name, description, inputSchema
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        
        if let schemaData = try container.decodeIfPresent(Data.self, forKey: .inputSchema) {
            inputSchema = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any] ?? [:]
        } else {
            inputSchema = [:]
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        
        let schemaData = try JSONSerialization.data(withJSONObject: inputSchema)
        try container.encode(schemaData, forKey: .inputSchema)
    }
}

struct McpResource: Codable {
    var uri: String
    var name: String?
    var description: String?
    var mimeType: String?
}

struct McpPrompt: Codable {
    var name: String
    var description: String?
    var arguments: [McpPromptArgument]?
}

struct McpPromptArgument: Codable {
    var name: String
    var description: String?
    var required: Bool?
}