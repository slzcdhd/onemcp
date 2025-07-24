import SwiftUI
import Logging

@main
struct OneMCPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow
    
    init() {
        // Configure logging
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .info
            return handler
        }
    }
    
    var body: some Scene {
        WindowGroup("OneMCP", id: "main") {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    // Pass app state to delegate
                    appDelegate.appState = appState
                    
                    // Setup MenuBar and start service
                    appDelegate.setupMenuBarAndStartService()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willBecomeActiveNotification)) { _ in
                    // Ensure window is visible when app becomes active
                    if let window = NSApplication.shared.windows.first(where: { $0.isVisible }) {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .showMainWindow)) { _ in
                    // Handle request to show main window
                    if #available(macOS 13.0, *) {
                        openWindow(id: "main")
                    } else {
                        // For older macOS, ensure window is visible
                        DispatchQueue.main.async {
                            if let window = NSApplication.shared.windows.first(where: { window in
                                let className = window.className
                                return !className.contains("StatusBar") && 
                                       !className.contains("PopupMenu") &&
                                       !className.contains("NSMenu")
                            }) {
                                window.setIsVisible(true)
                                window.makeKeyAndOrderFront(nil)
                                NSApp.activate(ignoringOtherApps: true)
                            }
                        }
                    }
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
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    // This will create a new window in SwiftUI
                    if #available(macOS 13.0, *) {
                        openWindow(id: "main")
                    } else {
                        // For older macOS, use AppDelegate method
                        appDelegate.createNewWindow()
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
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