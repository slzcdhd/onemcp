import SwiftUI
import Foundation
import Combine
import Logging

// Notification for requesting window to be shown
extension Notification.Name {
    static let showMainWindow = Notification.Name("com.onemcp.showMainWindow")
}

@MainActor
class AppState: ObservableObject {
    @Published var config: AppConfig = AppConfig()
    @Published var serverStatuses: [ServerStatus] = []
    @Published var aggregatedCapabilities: [AggregatedCapability] = []
    @Published var isServerRunning: Bool = false
    @Published var serverEndpoint: String = ""
    @Published var logs: [LogEntry] = []
    
    let logger = Logger(label: "com.onemcp.appstate")
    let configManager: ConfigManager
    let mcpAggregationService: MCPAggregationService
    let errorHandler = ErrorHandler()
    
    // Throttling for configuration saves
    private var saveTask: Task<Void, Never>?
    
    // Direct reference to MenuBarManager to avoid delegate lookup issues
    weak var menuBarManager: MenuBarManager?
    
    init() {
        self.configManager = ConfigManager()
        self.mcpAggregationService = MCPAggregationService()
        
        loadConfiguration()
        setupMCPService()
        // MCP service will be started explicitly after MenuBarManager is ready
    }
    
    func loadConfiguration() {
        do {
            config = try configManager.loadConfig()
            logger.info("Configuration loaded successfully")
            
            // Initialize server statuses for all configured servers
            serverStatuses = config.upstreamServers.map { server in
                ServerStatus(
                    id: server.id,
                    name: server.name,
                    status: .disconnected,
                    lastError: nil,
                    capabilities: CapabilityCount(tools: 0, resources: 0, prompts: 0)
                )
            }
            logger.info("Initialized \(serverStatuses.count) server statuses")
        } catch {
            logger.error("Failed to load configuration: \(error)")
            config = AppConfig() // Use default config
            serverStatuses = [] // Clear any existing statuses
        }
        updateServerEndpoint()
    }
    
    private func setupMCPService() {
        mcpAggregationService.delegate = self
        // Don't start automatically - wait for explicit start call
    }
    
    func startMCPService() {
        // Start the aggregation service
        Task {
            do {
                // Start MCP service
                try await mcpAggregationService.start(with: config)
                await MainActor.run {
                    isServerRunning = true
                }
                logger.info("MCP aggregation service started")
            } catch {
                logger.error("Failed to start MCP service: \(error)")
                await errorHandler.handle(error, context: "Starting MCP aggregation service")
            }
        }
    }
    
    func saveConfiguration() {
        saveTask?.cancel() // Cancel any pending save task
        saveTask = Task {
            // Add a small delay to throttle rapid saves
            try? await Task.sleep(for: .milliseconds(100))
            
            do {
                try configManager.saveConfig(config)
                updateServerEndpoint()
                logger.info("Configuration saved successfully")
                
                print("[AppState] Configuration saved, restarting MCP service...")
                
                // Restart service with new config
                Task {
                    do {
                        try await mcpAggregationService.restart(config: config)
                    } catch {
                        await errorHandler.handle(error, context: "Restarting MCP service with new configuration")
                    }
                }
            } catch {
                logger.error("Failed to save configuration: \(error)")
                Task {
                    await errorHandler.handle(error, context: "Saving configuration")
                }
            }
        }
    }
    
    func addServer(_ serverConfig: ServerConfig) {
        config.upstreamServers.append(serverConfig)
        
        // Create initial status for the new server
        let initialStatus = ServerStatus(
            id: serverConfig.id,
            name: serverConfig.name,
            status: serverConfig.enabled ? .disconnected : .disconnected,
            lastError: nil,
            capabilities: CapabilityCount(tools: 0, resources: 0, prompts: 0)
        )
        serverStatuses.append(initialStatus)
        
        // Save configuration without restarting the entire service
        saveConfigurationOnly()
        
        // Connect only the new server if it's enabled
        if serverConfig.enabled {
            Task { @MainActor in
                await mcpAggregationService.connectNewServer(serverConfig)
            }
        }
    }
    
    func updateServer(_ serverConfig: ServerConfig) {
        if let index = config.upstreamServers.firstIndex(where: { $0.id == serverConfig.id }) {
            config.upstreamServers[index] = serverConfig
            
            // Save configuration without restarting the entire service
            saveConfigurationOnly()
            
            // Reconnect only the updated server
            Task { @MainActor in
                // First disconnect the old connection
                await mcpAggregationService.disconnectSpecificServer(id: serverConfig.id)
                // Then connect with new config
                await mcpAggregationService.connectNewServer(serverConfig)
            }
        }
    }
    
    func removeServer(id: UUID) {
        config.upstreamServers.removeAll { $0.id == id }
        
        // Save configuration without restarting the entire service
        saveConfigurationOnly()
        
        // Disconnect only the removed server
        Task { @MainActor in
            await mcpAggregationService.disconnectSpecificServer(id: id)
        }
    }
    
    func toggleServer(id: UUID) {
        if let index = config.upstreamServers.firstIndex(where: { $0.id == id }) {
            config.upstreamServers[index].enabled.toggle()
            let isEnabled = config.upstreamServers[index].enabled
            let serverName = config.upstreamServers[index].name
            
            // Ensure we have a status entry for this server
            if !serverStatuses.contains(where: { $0.id == id }) {
                let newStatus = ServerStatus(
                    id: id,
                    name: serverName,
                    status: .disconnected,
                    lastError: nil,
                    capabilities: CapabilityCount(tools: 0, resources: 0, prompts: 0)
                )
                serverStatuses.append(newStatus)
            }
            
            // Update server status immediately when toggling
            if let statusIndex = serverStatuses.firstIndex(where: { $0.id == id }) {
                serverStatuses[statusIndex].status = isEnabled ? .connecting : .disconnected
                serverStatuses[statusIndex].lastError = nil
                if !isEnabled {
                    serverStatuses[statusIndex].capabilities = CapabilityCount(tools: 0, resources: 0, prompts: 0)
                }
            }
            
            // Save configuration without restarting the entire service
            saveConfigurationOnly()
            
            // Handle the specific server connection/disconnection
            Task { @MainActor in
                if isEnabled {
                    // Connect this specific server
                    await mcpAggregationService.connectSpecificServer(config.upstreamServers[index])
                } else {
                    // Disconnect this specific server
                    await mcpAggregationService.disconnectSpecificServer(id: id)
                }
            }
            
            // Force immediate menu bar update
            menuBarManager?.forceMenuUpdate()
        }
    }
    
    // Save configuration without restarting the service
    private func saveConfigurationOnly() {
        saveTask?.cancel() // Cancel any pending save task
        saveTask = Task {
            // Add a small delay to throttle rapid saves
            try? await Task.sleep(for: .milliseconds(100))
            
            do {
                try configManager.saveConfig(config)
                updateServerEndpoint()
                logger.info("Configuration saved successfully (toggle operation)")
            } catch {
                logger.error("Failed to save configuration: \(error)")
                Task {
                    await errorHandler.handle(error, context: "Saving configuration")
                }
            }
        }
    }
    
    private func updateServerEndpoint() {
        serverEndpoint = "http://\(config.server.host):\(config.server.port)"
    }
    
    func addLogEntry(_ entry: LogEntry) {
        logs.append(entry)
        
        // Keep only last 1000 log entries
        if logs.count > 1000 {
            logs.removeFirst(logs.count - 1000)
        }
    }
    
    func clearLogs() {
        logs.removeAll()
    }
}

// MARK: - MCPAggregationServiceDelegate

extension AppState: MCPAggregationServiceDelegate {
    func serviceDidUpdateServerStatuses(_ statuses: [ServerStatus]) async {
        await MainActor.run {
            self.serverStatuses = statuses
            
            // Force update UI
            objectWillChange.send()
            
            // Update MenuBar
            menuBarManager?.forceMenuUpdate()
        }
    }
    
    func serviceDidUpdateCapabilities(_ capabilities: [AggregatedCapability]) async {
        aggregatedCapabilities = capabilities
        
        // Always force immediate menu bar update for capability changes
        if let menuBarManager = menuBarManager {
            menuBarManager.forceMenuUpdate()
        }
    }
    
    func serviceDidLogMessage(_ message: String, level: LogLevel) async {
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            source: "MCPService",
            message: message
        )
        addLogEntry(entry)
        
        // Send critical error notifications
        if level == .error {
            if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                Task { @MainActor in
                    await appDelegate.menuBarManager?.sendNotification(
                        title: "OneMCP Error",
                        body: message
                    )
                }
            }
        }
    }
}

// MARK: - LogEntry

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let source: String
    let message: String
    
    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
    
    var levelColor: Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }
}