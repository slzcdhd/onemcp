import Foundation
import Logging

class ConfigManager {
    private let logger = Logger(label: "com.onemcp.configmanager")
    private let configDirectoryURL: URL
    let configFileURL: URL
    let mcpServersFileURL: URL
    
    init() {
        // Create config directory in Application Support
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        configDirectoryURL = appSupportURL.appendingPathComponent("OneMCP")
        configFileURL = configDirectoryURL.appendingPathComponent("config.json")
        mcpServersFileURL = configDirectoryURL.appendingPathComponent("mcp_servers.json")
        
        createConfigDirectoryIfNeeded()
        initializeMCPServersFile()
    }
    
    private func createConfigDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create config directory: \(error)")
        }
    }
    
    private func initializeMCPServersFile() {
        // If mcp_servers.json doesn't exist in the config directory, copy from project root
        guard !FileManager.default.fileExists(atPath: mcpServersFileURL.path) else {
            return
        }
        
        // Try to copy from project root
        let projectRootMCPServersURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mcp_servers.json")
        
        if FileManager.default.fileExists(atPath: projectRootMCPServersURL.path) {
            do {
                try FileManager.default.copyItem(at: projectRootMCPServersURL, to: mcpServersFileURL)
                logger.info("Copied mcp_servers.json from project root to config directory")
            } catch {
                logger.warning("Failed to copy mcp_servers.json from project root: \(error)")
                createDefaultMCPServersFile()
            }
        } else {
            createDefaultMCPServersFile()
        }
    }
    
    private func createDefaultMCPServersFile() {
        let defaultConfig = [
            "mcpServers": [String: Any]()
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: defaultConfig, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: mcpServersFileURL)
            logger.info("Created default mcp_servers.json")
        } catch {
            logger.error("Failed to create default mcp_servers.json: \(error)")
        }
    }
    
    func loadConfig() throws -> AppConfig {
        var config: AppConfig
        
        if FileManager.default.fileExists(atPath: configFileURL.path) {
            let data = try Data(contentsOf: configFileURL)
            config = try JSONDecoder().decode(AppConfig.self, from: data)
            logger.info("Configuration loaded from \(configFileURL.path)")
        } else {
            logger.info("Config file not found, creating default config")
            config = AppConfig(
                server: ServerSettings(port: 3000, host: "localhost", enableCors: true),
                ui: UISettings(),
                logging: LoggingSettings(),
                upstreamServers: []
            )
        }
        
        // Always load servers from mcp_servers.json
        config.upstreamServers = try loadServersFromMCPFile()
        
        // Save the complete config back if it was newly created
        if !FileManager.default.fileExists(atPath: configFileURL.path) {
            try saveConfig(config)
        }
        
        return config
    }
    
    func saveConfig(_ config: AppConfig) throws {
        // Save main config (without upstream servers)
        var configToSave = config
        configToSave.upstreamServers = [] // Don't save servers in main config
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configToSave)
        try data.write(to: configFileURL)
        logger.info("Configuration saved to \(configFileURL.path)")
        
        // Save upstream servers to mcp_servers.json
        try saveMCPServers(config.upstreamServers)
    }
    
    private func saveMCPServers(_ servers: [ServerConfig]) throws {
        var mcpServers: [String: Any] = [:]
        
        for server in servers {
            var serverDict: [String: Any] = [:]
            
            switch server.config {
            case .stdio(let stdioConfig):
                serverDict["command"] = stdioConfig.command
                serverDict["args"] = stdioConfig.arguments
                
                if let environment = stdioConfig.environment, !environment.isEmpty {
                    serverDict["env"] = environment
                }
                
                if let workingDirectory = stdioConfig.workingDirectory, !workingDirectory.isEmpty {
                    serverDict["workingDirectory"] = workingDirectory
                }
                
            case .sse(let sseConfig):
                serverDict["type"] = "sse"
                serverDict["url"] = sseConfig.url.absoluteString
                
                if let headers = sseConfig.headers, !headers.isEmpty {
                    serverDict["headers"] = headers
                }
                
            case .streamableHttp(let httpConfig):
                serverDict["type"] = "streamable-http"
                serverDict["url"] = httpConfig.url.absoluteString
                
                if let headers = httpConfig.headers, !headers.isEmpty {
                    serverDict["headers"] = headers
                }
            }
            
            mcpServers[server.name] = serverDict
        }
        
        let finalDict = ["mcpServers": mcpServers]
        let data = try JSONSerialization.data(withJSONObject: finalDict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: mcpServersFileURL)
        
        logger.info("MCP servers saved to \(mcpServersFileURL.path)")
    }
    

    
    func loadServersFromMCPFile() throws -> [ServerConfig] {
        guard FileManager.default.fileExists(atPath: mcpServersFileURL.path) else {
            logger.info("mcp_servers.json not found in config directory, using empty server list")
            return []
        }
        
        do {
            let data = try Data(contentsOf: mcpServersFileURL)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let mcpServers = json?["mcpServers"] as? [String: Any] ?? [:]
            
            var servers: [ServerConfig] = []
            
            for (name, config) in mcpServers {
                if let serverDict = config as? [String: Any] {
                    do {
                        let server = try createServerConfig(name: name, config: serverDict)
                        servers.append(server)
                    } catch {
                        logger.warning("Failed to parse server config for \(name): \(error)")
                    }
                }
            }
            
            logger.info("Loaded \(servers.count) servers from mcp_servers.json")
            return servers
        } catch {
            logger.error("Failed to load mcp_servers.json: \(error)")
            return []
        }
    }
    
    private func createServerConfig(name: String, config: [String: Any]) throws -> ServerConfig {
        if let command = config["command"] as? String,
           let args = config["args"] as? [String] {
            // Stdio server
            let environment = config["env"] as? [String: String] // Support both "env" and "environment"
            let workingDirectory = config["workingDirectory"] as? String
            
            let stdioConfig = StdioConfig(
                command: command,
                arguments: args,
                environment: environment,
                workingDirectory: workingDirectory
            )
            return ServerConfig(
                name: name,
                type: .stdio,
                config: .stdio(stdioConfig)
            )
        } else if let type = config["type"] as? String,
                  let urlString = config["url"] as? String,
                  let url = URL(string: urlString) {
            // HTTP-based server
            let headers = config["headers"] as? [String: String]
            
            switch type {
            case "sse":
                let sseConfig = SseConfig(url: url, headers: headers)
                return ServerConfig(
                    name: name,
                    type: .sse,
                    config: .sse(sseConfig)
                )
            case "streamable-http":
                let httpConfig = HttpConfig(url: url, headers: headers)
                return ServerConfig(
                    name: name,
                    type: .streamableHttp,
                    config: .streamableHttp(httpConfig)
                )
            default:
                throw ConfigError.unsupportedServerType(type)
            }
        } else {
            throw ConfigError.invalidServerConfiguration(name)
        }
    }
    
    func exportConfig(to url: URL) throws {
        let config = try loadConfig()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url)
        logger.info("Configuration exported to \(url.path)")
    }
    
    func importConfig(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        try saveConfig(config)
        logger.info("Configuration imported from \(url.path)")
    }
    
    // MARK: - MCP Servers File Management
    
    func getMCPServersFileURL() -> URL {
        return mcpServersFileURL
    }
    
    func reloadMCPServers() throws -> [ServerConfig] {
        return try loadServersFromMCPFile()
    }
    
    func exportMCPServers(to url: URL) throws {
        guard FileManager.default.fileExists(atPath: mcpServersFileURL.path) else {
            throw ConfigError.configFileCorrupted
        }
        
        try FileManager.default.copyItem(at: mcpServersFileURL, to: url)
        logger.info("MCP servers exported to \(url.path)")
    }
    
    func importMCPServers(from url: URL) throws {
        // Validate the file format first
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard json?["mcpServers"] != nil else {
            throw ConfigError.invalidServerConfiguration("Invalid mcp_servers.json format")
        }
        
        // Copy the file to our config directory
        if FileManager.default.fileExists(atPath: mcpServersFileURL.path) {
            try FileManager.default.removeItem(at: mcpServersFileURL)
        }
        try FileManager.default.copyItem(at: url, to: mcpServersFileURL)
        
        logger.info("MCP servers imported from \(url.path)")
    }
}

// MARK: - ConfigError

enum ConfigError: LocalizedError {
    case unsupportedServerType(String)
    case invalidServerConfiguration(String)
    case configFileCorrupted
    
    var errorDescription: String? {
        switch self {
        case .unsupportedServerType(let type):
            return "Unsupported server type: \(type)"
        case .invalidServerConfiguration(let name):
            return "Invalid configuration for server: \(name)"
        case .configFileCorrupted:
            return "Configuration file is corrupted"
        }
    }
}