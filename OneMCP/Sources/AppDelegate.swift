import SwiftUI
import AppKit
import ServiceManagement

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    var menuBarManager: MenuBarManager?
    var appState: AppState?
    var windowController: NSWindowController?
    private var windowMonitorTimer: Timer?
    
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
                
                // Start window monitoring
                startWindowMonitoring()
            }
        }
    }
    
    private func startWindowMonitoring() {
        // Monitor window state every 30 seconds
        windowMonitorTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkWindowHealth()
            }
        }
        print("[AppDelegate] Window monitoring started")
    }
    
    private func checkWindowHealth() {
        // Check if we have any main windows available
        let mainWindows = NSApplication.shared.windows.filter { window in
            let className = window.className
            return !className.contains("StatusBar") && 
                   !className.contains("PopupMenu") &&
                   !className.contains("NSMenu")
        }
        
        // If we have no main windows and no window controller, ensure we can create one when needed
        if mainWindows.isEmpty && windowController?.window == nil {
            print("[AppDelegate] No main windows detected, preparing backup window capability")
            // Pre-create a window controller so it's ready when needed
            prepareBackupWindow()
        }
    }
    
    private func prepareBackupWindow() {
        guard windowController == nil else { return }
        
        print("[AppDelegate] Preparing backup window")
        
        // Create a window but don't show it yet
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "OneMCP"
        window.center()
        window.setFrameAutosaveName("MainWindow")
        
        // Set the SwiftUI content
        if let appState = appState {
            let contentView = ContentView()
                .environmentObject(appState)
            window.contentView = NSHostingView(rootView: contentView)
        }
        
        // Create window controller but don't show the window
        windowController = NSWindowController(window: window)
        
        print("[AppDelegate] Backup window prepared")
    }
    
    func createNewWindow() {
        print("[AppDelegate] createNewWindow called")
        
        // Method 1: Try to use the Window menu's New Window command
        if let windowMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Window" })?.submenu {
            for item in windowMenu.items {
                if item.title.lowercased().contains("new") && item.action != nil {
                    print("[AppDelegate] Found Window menu new action: \(item.title)")
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
                    print("[AppDelegate] Found File menu new window action: \(item.title)")
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
            print("[AppDelegate] Trying selector: \(selector)")
            if NSApp.sendAction(selector, to: nil, from: nil) {
                print("[AppDelegate] Selector succeeded: \(selector)")
                return
            }
        }
        
        // Method 4: Force window creation by changing activation policy
        let currentPolicy = NSApp.activationPolicy()
        print("[AppDelegate] Current activation policy: \(currentPolicy)")
        if currentPolicy == .accessory {
            print("[AppDelegate] Switching to regular activation policy")
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
                // Try again after policy change
                print("[AppDelegate] Retrying newWindowForTab after policy change")
                NSApp.sendAction(#selector(NSApplication.newWindowForTab(_:)), to: nil, from: nil)
                
                // Restore policy if needed
                if !(self.appState?.config.ui.showInDock ?? true) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        print("[AppDelegate] Restoring accessory activation policy")
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
        }
        
        // Method 5: Fallback - create a programmatic SwiftUI window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.createProgrammaticWindow()
        }
    }
    
    private func createProgrammaticWindow() {
        print("[AppDelegate] Creating programmatic window")
        
        // If we already have a window controller, just show its window
        if let existingController = windowController,
           let window = existingController.window {
            print("[AppDelegate] Reusing existing window controller")
            window.setIsVisible(true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Create a new NSWindow manually with SwiftUI content
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "OneMCP"
        window.center()
        window.setFrameAutosaveName("MainWindow")
        
        // Set the SwiftUI content
        if let appState = appState {
            let contentView = ContentView()
                .environmentObject(appState)
            window.contentView = NSHostingView(rootView: contentView)
        }
        
        // Create and store window controller
        windowController = NSWindowController(window: window)
        
        // Show the window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        print("[AppDelegate] Programmatic window created and shown")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup resources
        windowMonitorTimer?.invalidate()
        windowMonitorTimer = nil
        windowController = nil
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
        print("[AppDelegate] showMainWindow called")
        
        // First check if we have a window controller with a valid window
        if let controller = windowController,
           let window = controller.window {
            print("[AppDelegate] Using window controller's window")
            window.setIsVisible(true)
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Then try to find existing SwiftUI windows
        let existingWindows = NSApplication.shared.windows.filter { window in
            let className = window.className
            let isMainWindow = !className.contains("StatusBar") && 
                              !className.contains("PopupMenu") &&
                              !className.contains("NSMenu") &&
                              className.contains("NSWindow")
            if isMainWindow {
                print("[AppDelegate] Found existing window: \(className), visible: \(window.isVisible)")
            }
            return isMainWindow
        }
        
        if let existingWindow = existingWindows.first {
            print("[AppDelegate] Using existing SwiftUI window")
            // Make sure window is visible
            existingWindow.setIsVisible(true)
            existingWindow.deminiaturize(nil)
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        } else {
            print("[AppDelegate] No existing window found, creating new one")
            // Create new window using various methods
            
            // First, try sending a notification to SwiftUI
            print("[AppDelegate] Sending showMainWindow notification")
            NotificationCenter.default.post(name: .showMainWindow, object: nil)
            
            // Also try traditional window creation methods with longer delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // If notification didn't work, try other methods
                let visibleMainWindows = NSApplication.shared.windows.filter { window in
                    let className = window.className
                    return !className.contains("StatusBar") && 
                           !className.contains("PopupMenu") &&
                           !className.contains("NSMenu") &&
                           window.isVisible
                }
                
                if visibleMainWindows.isEmpty {
                    print("[AppDelegate] Notification didn't create window, trying traditional methods")
                    self.createNewWindow()
                } else {
                    print("[AppDelegate] Window created successfully via notification")
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