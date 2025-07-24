import SwiftUI
import ServiceLifecycle
import Logging

@main
struct OneMCPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    
    init() {
        // Configure logging
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .info
            return handler
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    // Pass app state to delegate
                    appDelegate.appState = appState
                    
                    // Setup MenuBar and start service
                    appDelegate.setupMenuBarAndStartService()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About OneMCP") {
                    showAboutPanel()
                }
            }
            
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    // TODO: Implement update checking
                }
                .disabled(true)
            }
        }
        

    }
    
    private func showAboutPanel() {
        let alert = NSAlert()
        alert.messageText = "OneMCP"
        alert.informativeText = "MCP Server Aggregation Tool\n\nVersion 1.0.0\n\nAggregates multiple MCP servers into a unified interface."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}