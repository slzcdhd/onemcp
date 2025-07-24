import SwiftUI
import AppKit
import ServiceManagement

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    var menuBarManager: MenuBarManager?
    var appState: AppState?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Handle command line arguments first
        handleCommandLineArguments()
        
        // Configure app behavior and MenuBarManager creation will happen
        // after AppState is set from OneMCPApp.onAppear
    }
    
    // Called when AppState is set from OneMCPApp
    func setupMenuBarAndStartService() {
        guard let appState = appState else { return }
        
        // Configure app behavior FIRST
        Task { @MainActor in
            configureAppBehavior()
            
            // Then initialize menu bar manager after activation policy is set
            if menuBarManager == nil {
                menuBarManager = MenuBarManager(appState: appState)
                
                // Set direct reference in AppState
                appState.menuBarManager = menuBarManager
                
                // Start MCP service after MenuBarManager is ready
                appState.startMCPService()
            }
        }
    }
    
    func createNewWindow() {
        // For SwiftUI apps, we need to trigger window creation through the Window menu
        // Find the File menu and trigger New Window
        if let fileMenu = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu {
            // Look for "New Window" item
            if let newWindowItem = fileMenu.items.first(where: { 
                $0.title.lowercased().contains("new") && 
                $0.keyEquivalent == "n" &&
                $0.keyEquivalentModifierMask.contains(.command)
            }) {
                NSApp.sendAction(newWindowItem.action!, to: newWindowItem.target, from: newWindowItem)
                return
            }
        }
        
        // Fallback: Use the Window menu
        if let windowMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Window" })?.submenu {
            if let newWindowItem = windowMenu.items.first(where: { 
                $0.title.lowercased().contains("new") 
            }) {
                NSApp.sendAction(newWindowItem.action!, to: newWindowItem.target, from: newWindowItem)
                return
            }
        }
        
        // Last resort: Send new window action to responder chain
        NSApp.sendAction(#selector(NSApplication.newWindowForTab(_:)), to: nil, from: nil)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup resources
        menuBarManager = nil
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Show main window when dock icon is clicked
        if !flag {
            // No visible windows, need to create a new one
            // For SwiftUI apps, we trigger window creation by opening a new window
            NSApp.sendAction(#selector(NSApplication.newWindowForTab(_:)), to: nil, from: nil)
        } else {
            // There are visible windows, just bring them to front
            if let window = NSApplication.shared.windows.first(where: { window in
                let className = window.className
                return !className.contains("StatusBar") && 
                       !className.contains("PopupMenu") &&
                       !className.contains("NSMenu") &&
                       className.contains("NSWindow")
            }) {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        return true
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when main window is closed if running in background
        return !(appState?.config.ui.showInDock ?? true)
    }
    
    @MainActor
    private func configureAppBehavior() {
        guard let appState = appState else { return }
        
        // Configure dock visibility
        if !appState.config.ui.showInDock {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
        
        // Handle start minimized preference
        if appState.config.ui.startMinimized {
            NSApplication.shared.windows.first?.miniaturize(nil)
        }
    }
    
    @MainActor
    private func handleCommandLineArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        
        for (index, arg) in arguments.enumerated() {
            switch arg {
            case "--hidden", "--minimized":
                // Start in background
                NSApplication.shared.windows.first?.orderOut(nil)
            case "--port":
                // Override port setting
                if index + 1 < arguments.count, let port = Int(arguments[index + 1]) {
                    appState?.config.server.port = port
                }
            case "--host":
                // Override host setting
                if index + 1 < arguments.count {
                    appState?.config.server.host = arguments[index + 1]
                }
            case "--help":
                printUsage()
                NSApplication.shared.terminate(nil)
            default:
                break
            }
        }
    }
    
    private func printUsage() {
        print("""
        OneMCP - MCP Server Aggregation Tool
        
        Usage: OneMCP [options]
        
        Options:
            --port <port>    Set the MCP server port (default: 3000)
            --hidden         Start with window hidden
            --help           Show this help message
        
        Examples:
            OneMCP --port 3000 --hidden
        """)
    }
}

// MARK: - Launch at Login Support

extension AppDelegate {
    func enableLaunchAtLogin(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            enableLaunchAtLoginModern(enable)
        } else {
            enableLaunchAtLoginLegacy(enable)
        }
    }
    
    @available(macOS 13.0, *)
    private func enableLaunchAtLoginModern(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Silently fail - launch at login is not critical
        }
    }
    
    private func enableLaunchAtLoginLegacy(_ enable: Bool) {
        // For legacy systems, we'll use a simplified approach
        // Note: These APIs are deprecated but still functional for older macOS versions
        if enable {
            // Add to login items
            let appURL = Bundle.main.bundleURL
            
            // Try to add using shell command as fallback
            let script = """
                osascript -e 'tell application "System Events" to make login item at end with properties {path:"\(appURL.path)", hidden:false}'
                """
            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", script]
            task.launch()
            task.waitUntilExit()
        } else {
            // Remove from login items using shell command
            let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "OneMCP"
            let script = """
                osascript -e 'tell application "System Events" to delete login item "\(appName)"'
                """
            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", script]
            task.launch()
            task.waitUntilExit()
        }
    }
    
    func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            return isLaunchAtLoginEnabledLegacy()
        }
    }
    
    private func isLaunchAtLoginEnabledLegacy() -> Bool {
        // Use shell command to check login items
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "OneMCP"
        let script = """
            osascript -e 'tell application "System Events" to get the name of every login item' | grep -q "\(appName)"
            """
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", script]
        task.launch()
        task.waitUntilExit()
        
        return task.terminationStatus == 0
    }
}