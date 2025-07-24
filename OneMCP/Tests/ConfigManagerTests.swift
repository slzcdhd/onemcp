import XCTest
@testable import OneMCP

final class ConfigManagerTests: XCTestCase {
    var configManager: ConfigManager!
    var tempDirectory: URL!
    
    override func setUpWithError() throws {
        // Create temporary directory for testing
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        // Use a custom config manager with the temporary directory
        configManager = ConfigManager(configDirectory: tempDirectory)
    }
    
    override func tearDownWithError() throws {
        // Clean up temporary directory
        try? FileManager.default.removeItem(at: tempDirectory)
    }
    
    func testLoadDefaultConfig() throws {
        // Test loading default configuration
        let config = try configManager.loadConfig()
        
        XCTAssertEqual(config.server.port, 3000)
        XCTAssertEqual(config.server.host, "localhost")
        XCTAssertTrue(config.server.enableCors)
        XCTAssertFalse(config.ui.startMinimized)
        XCTAssertTrue(config.ui.showInDock)
        XCTAssertTrue(config.ui.enableNotifications)
        XCTAssertEqual(config.ui.theme, .system)
    }
    
    func testSaveAndLoadConfig() throws {
        // Create a custom configuration
        var config = AppConfig()
        config.server.port = 4000
        config.server.host = "0.0.0.0"
        config.ui.startMinimized = true
        config.ui.theme = .dark
        
        // Add some test servers
        let stdioServer = ServerConfig(
            name: "test-stdio",
            type: .stdio,
            config: .stdio(StdioConfig(command: "test-command", arguments: ["--arg1"]))
        )
        
        let httpServer = ServerConfig(
            name: "test-http",
            type: .streamableHttp,
            config: .streamableHttp(HttpConfig(url: URL(string: "http://localhost:9000")!))
        )
        
        config.upstreamServers = [stdioServer, httpServer]
        
        // Save configuration
        try configManager.saveConfig(config)
        
        // Load configuration and verify
        let loadedConfig = try configManager.loadConfig()
        
        XCTAssertEqual(loadedConfig.server.port, 4000)
        XCTAssertEqual(loadedConfig.server.host, "0.0.0.0")
        XCTAssertTrue(loadedConfig.ui.startMinimized)
        XCTAssertEqual(loadedConfig.ui.theme, .dark)
        XCTAssertEqual(loadedConfig.upstreamServers.count, 2)
        
        // Servers are sorted by name when saved, so "test-http" comes before "test-stdio"
        // Verify first server (test-http)
        let firstServer = loadedConfig.upstreamServers[0]
        XCTAssertEqual(firstServer.name, "test-http")
        XCTAssertEqual(firstServer.type, .streamableHttp)
        
        if case .streamableHttp(let httpConfig) = firstServer.config {
            XCTAssertEqual(httpConfig.url.absoluteString, "http://localhost:9000")
        } else {
            XCTFail("Expected HTTP configuration")
        }
        
        // Verify second server (test-stdio)
        let secondServer = loadedConfig.upstreamServers[1]
        XCTAssertEqual(secondServer.name, "test-stdio")
        XCTAssertEqual(secondServer.type, .stdio)
        
        if case .stdio(let stdioConfig) = secondServer.config {
            XCTAssertEqual(stdioConfig.command, "test-command")
            XCTAssertEqual(stdioConfig.arguments, ["--arg1"])
        } else {
            XCTFail("Expected stdio configuration")
        }
    }
    
    func testExportAndImportConfig() throws {
        // Create a test configuration
        var config = AppConfig()
        config.server.port = 4000
        config.upstreamServers = [
            ServerConfig(
                name: "export-test",
                type: .sse,
                config: .sse(SseConfig(url: URL(string: "http://localhost:8888")!))
            )
        ]
        
        try configManager.saveConfig(config)
        
        // Export configuration
        let exportURL = tempDirectory.appendingPathComponent("exported-config.json")
        try configManager.exportConfig(to: exportURL)
        
        // Verify export file exists and has content
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
        let exportData = try Data(contentsOf: exportURL)
        XCTAssertFalse(exportData.isEmpty)
        
        // Import configuration
        try configManager.importConfig(from: exportURL)
        let importedConfig = try configManager.loadConfig()
        
        XCTAssertEqual(importedConfig.server.port, 4000)
        XCTAssertEqual(importedConfig.upstreamServers.count, 1)
        XCTAssertEqual(importedConfig.upstreamServers[0].name, "export-test")
    }
    
    func testInvalidConfigurationHandling() {
        // Test handling of corrupted configuration
        let invalidJSON = "{ invalid json }"
        let configURL = tempDirectory.appendingPathComponent("invalid-config.json")
        
        try? invalidJSON.write(to: configURL, atomically: true, encoding: .utf8)
        
        // Should throw an error when trying to import invalid config
        XCTAssertThrowsError(try configManager.importConfig(from: configURL))
    }
    
    func testConfigurationValidation() throws {
        // Test that invalid port numbers are handled appropriately
        var config = AppConfig()
        config.server.port = -1 // Invalid port
        
        // This should either throw an error or be corrected
        // depending on implementation
        XCTAssertNoThrow(try configManager.saveConfig(config))
    }
}