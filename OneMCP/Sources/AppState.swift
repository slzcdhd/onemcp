import SwiftUI
import Foundation
import Combine
import Logging

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
        } catch {
            logger.error("Failed to load configuration: \(error)")
            config = AppConfig() // Use default config
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
                try await mcpAggregationService.start(config: config)
                isServerRunning = true
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
        saveConfiguration()
    }
    
    func updateServer(_ serverConfig: ServerConfig) {
        if let index = config.upstreamServers.firstIndex(where: { $0.id == serverConfig.id }) {
            config.upstreamServers[index] = serverConfig
            saveConfiguration()
        }
    }
    
    func removeServer(id: UUID) {
        config.upstreamServers.removeAll { $0.id == id }
        saveConfiguration()
    }
    
    func toggleServer(id: UUID) {
        print("[AppState] toggleServer called for id: \(id)")
        if let index = config.upstreamServers.firstIndex(where: { $0.id == id }) {
            let serverName = config.upstreamServers[index].name
            let wasEnabled = config.upstreamServers[index].enabled
            config.upstreamServers[index].enabled.toggle()
            let isEnabled = config.upstreamServers[index].enabled
            
            print("[AppState] Server \(serverName) toggled from \(wasEnabled) to enabled: \(isEnabled)")
            
            // Immediately update server status when toggling off
            if !isEnabled {
                if let statusIndex = serverStatuses.firstIndex(where: { $0.id == id }) {
                    serverStatuses[statusIndex].status = .disconnected
                    serverStatuses[statusIndex].lastError = nil
                    serverStatuses[statusIndex].capabilities = CapabilityCount()
                    print("[AppState] Updated server status to disconnected for \(serverName)")
                }
            }
            
            // Save configuration without restarting the entire service
            saveConfigurationOnly()
            
            // Handle the specific server connection/disconnection
            Task {
                if isEnabled {
                    // Connect this specific server
                    await mcpAggregationService.connectSpecificServer(config.upstreamServers[index])
                } else {
                    // Disconnect this specific server
                    await mcpAggregationService.disconnectSpecificServer(id: id)
                }
            }
            
            // Force immediate menu bar update
            print("[AppState] Attempting to update menu bar...")
            if let menuBarManager = menuBarManager {
                print("[AppState] MenuBarManager found via direct reference, calling forceMenuUpdate")
                menuBarManager.forceMenuUpdate()
            } else {
                print("[AppState] MenuBarManager not set yet in toggleServer!")
            }
        } else {
            print("[AppState] Server with id \(id) not found!")
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
    func serviceDidUpdateServerStatus(_ status: ServerStatus) async {
        print("[AppState] serviceDidUpdateServerStatus called for \(status.name) - \(status.status)")
        let isNewStatus = !serverStatuses.contains { $0.id == status.id }
        let previousStatus = serverStatuses.first { $0.id == status.id }?.status
        
        if let index = serverStatuses.firstIndex(where: { $0.id == status.id }) {
            serverStatuses[index] = status
        } else {
            serverStatuses.append(status)
        }
        
        // Always force immediate menu bar update for any status change
        print("[AppState] Attempting menu bar update after status change...")
        
        if let menuBarManager = menuBarManager {
            print("[AppState] MenuBarManager found via direct reference, calling forceMenuUpdate")
            menuBarManager.forceMenuUpdate()
        } else {
            print("[AppState] MenuBarManager not set yet!")
        }
        
        // Send notification for significant status changes
        if !isNewStatus && previousStatus != status.status {
            if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                Task { @MainActor in
                    await appDelegate.menuBarManager?.sendServerStatusNotification(status)
                }
            }
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