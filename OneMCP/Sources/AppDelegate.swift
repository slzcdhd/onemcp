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
        // Method 1: Try to use the Window menu's New Window command
        if let windowMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Window" })?.submenu {
            for item in windowMenu.items {
                if item.title.lowercased().contains("new") && item.action != nil {
                    NSApp.sendAction(item.action!, to: item.target, from: item)
                    return
                }
            }
        }
        
        // Method 2: Try File menu's New Window command
        if let fileMenu = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu {
            for item in fileMenu.items {
                if item.title.lowercased().contains("new") && 
                   item.title.lowercased().contains("window") &&
                   item.action != nil {
                    NSApp.sendAction(item.action!, to: item.target, from: item)
                    return
                }
            }
        }
        
        // Method 3: Try standard new window selectors
        let selectors = [
            #selector(NSApplication.newWindowForTab(_:))
        ]
        
        for selector in selectors {
            if NSApp.sendAction(selector, to: nil, from: nil) {
                return
            }
        }
        
        // Method 4: Force window creation by changing activation policy
        let currentPolicy = NSApp.activationPolicy()
        if currentPolicy == .accessory {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
                // Try again after policy change
                NSApp.sendAction(#selector(NSApplication.newWindowForTab(_:)), to: nil, from: nil)
                
                // Restore policy if needed
                if !(self.appState?.config.ui.showInDock ?? true) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup resources
        menuBarManager = nil
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Show main window when dock icon is clicked
        if !flag {
            // No visible windows, need to create a new one
            showMainWindow()
        } else {
            // There are visible windows, just bring them to front
            for window in NSApplication.shared.windows {
                let className = window.className
                if !className.contains("StatusBar") && 
                   !className.contains("PopupMenu") &&
                   !className.contains("NSMenu") &&
                   window.isVisible {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        return true
    }
    
    func showMainWindow() {
        // First try to find an existing window
        if let existingWindow = NSApplication.shared.windows.first(where: { window in
            let className = window.className
            return !className.contains("StatusBar") && 
                   !className.contains("PopupMenu") &&
                   !className.contains("NSMenu") &&
                   className.contains("NSWindow")
        }) {
            // Make sure window is visible
            existingWindow.setIsVisible(true)
            existingWindow.deminiaturize(nil)
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Create new window using various methods
            
            // First, try sending a notification to SwiftUI
            NotificationCenter.default.post(name: .showMainWindow, object: nil)
            
            // Also try traditional window creation methods
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // If notification didn't work, try other methods
                if NSApplication.shared.windows.first(where: { window in
                    let className = window.className
                    return !className.contains("StatusBar") && 
                           !className.contains("PopupMenu") &&
                           !className.contains("NSMenu") &&
                           window.isVisible
                }) == nil {
                    self.createNewWindow()
                }
            }
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Never quit when window is closed - we're a menu bar app
        return false
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