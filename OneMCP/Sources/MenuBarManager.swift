import SwiftUI
import AppKit
import UserNotifications



@MainActor
class MenuBarManager: ObservableObject {
    private var statusItem: NSStatusItem?
    private var appState: AppState
    private var baseIcon: NSImage?
    
    init(appState: AppState) {
        self.appState = appState
        loadBaseIcon()
        setupMenuBar()
        requestNotificationPermission()
        
        // Schedule delayed menu updates to catch server status changes after startup
        Task {
            try? await Task.sleep(for: .seconds(5))
            await updateMenu()
            try? await Task.sleep(for: .seconds(5)) 
            await updateMenu()
            try? await Task.sleep(for: .seconds(5))
            await updateMenu()
        }
    }
    
    private func loadBaseIcon() {
        // Try to load the dedicated menubar icon first
        if let menubarIconPath = Bundle.main.path(forResource: "menubar_icon_16", ofType: "png"),
           let icon = NSImage(contentsOfFile: menubarIconPath) {
            baseIcon = icon
        } else if let menubarIconPath = Bundle.main.path(forResource: "MenuBarIcon", ofType: "icns"),
                  let icon = NSImage(contentsOfFile: menubarIconPath) {
            baseIcon = icon
        } else if let iconPath = Bundle.main.path(forResource: "OneMCP", ofType: "icns"),
                  let icon = NSImage(contentsOfFile: iconPath) {
            baseIcon = icon
        } else if let bundleIcon = NSImage(named: "AppIcon") {
            baseIcon = bundleIcon
        } else {
            // Fallback to a simple custom icon created from the app name
            baseIcon = createFallbackIcon()
        }
    }
    
    private func createFallbackIcon() -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let icon = NSImage(size: size)
        
        icon.lockFocus()
        
        // Create a simple circular icon with "O" for OneMCP
        let rect = NSRect(origin: .zero, size: size)
        
        // Background circle
        NSColor.controlAccentColor.setFill()
        let backgroundPath = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
        backgroundPath.fill()
        
        // Text "O"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 10),
            .foregroundColor: NSColor.white
        ]
        let text = "O"
        let textSize = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attributes)
        
        icon.unlockFocus()
        icon.isTemplate = true
        
        return icon
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.isVisible = true
        
        if let button = statusItem?.button {
            // Use custom app icon
            updateStatusBarIcon()
            button.toolTip = "OneMCP - MCP Server Aggregator"
        }
        
        updateMenuBarStatus()
        createMenu()
    }
    
    private func updateStatusBarIcon() {
        guard let button = statusItem?.button,
              let baseIcon = baseIcon else { return }
        
        // Create a copy of the base icon for modification
        let icon = baseIcon.copy() as! NSImage
        icon.size = NSSize(width: 16, height: 16)
        
        // Get status information
        let connectedCount = appState.serverStatuses.filter { $0.status == .connected }.count
        let isRunning = appState.isServerRunning
        
        // Create status indicator overlay if needed
        if !isRunning {
            // Add red dot for stopped status
            icon.lockFocus()
            NSColor.systemRed.setFill()
            let dotRect = NSRect(x: 12, y: 12, width: 4, height: 4)
            let dotPath = NSBezierPath(ovalIn: dotRect)
            dotPath.fill()
            icon.unlockFocus()
        } else if connectedCount == 0 {
            // Add yellow dot for no connections
            icon.lockFocus()
            NSColor.systemYellow.setFill()
            let dotRect = NSRect(x: 12, y: 12, width: 4, height: 4)
            let dotPath = NSBezierPath(ovalIn: dotRect)
            dotPath.fill()
            icon.unlockFocus()
        } else {
            // Add green dot for active connections
            icon.lockFocus()
            NSColor.systemGreen.setFill()
            let dotRect = NSRect(x: 12, y: 12, width: 4, height: 4)
            let dotPath = NSBezierPath(ovalIn: dotRect)
            dotPath.fill()
            icon.unlockFocus()
        }
        
        icon.isTemplate = true
        button.image = icon
    }
    
    func updateMenuBarStatus() {
        guard let button = statusItem?.button else { 
            // If no status item, we're probably running in command line mode
            return 
        }
        
        // Update custom icon with status indicator
        updateStatusBarIcon()
        
        // Update tooltip
        let connectedCount = appState.serverStatuses.filter { $0.status == .connected }.count
        let totalCount = appState.serverStatuses.count
        let tooltip = appState.isServerRunning 
            ? "OneMCP - Running (\(connectedCount)/\(totalCount) servers connected)"
            : "OneMCP - Stopped"
        button.toolTip = tooltip
    }
    
    private func createMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 280
        
        // Server status section
        createServerStatusSection(menu)
        
        menu.addItem(NSMenuItem.separator())
        
        // Connected servers section
        updateConnectedServersMenu(menu)
        
        // Add separator if there are connected servers
        let connectedServers = appState.serverStatuses.filter { $0.status == .connected }
        if !connectedServers.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }
        
        // Actions section
        createBottomActions(menu)
        
        statusItem?.menu = menu
        
        // Debug: Print server count
        let connectedCount = appState.serverStatuses.filter { $0.status == .connected }.count
        print("[MenuBarManager] Menu created with \(connectedCount) connected servers")
    }
    
    
     
 
    
    private func createServerStatusSection(_ menu: NSMenu) {
        // Overall status
        let isRunning = appState.isServerRunning
        let connectedCount = appState.serverStatuses.filter { $0.status == .connected }.count
        let totalCount = appState.serverStatuses.count
        
        let statusText = isRunning 
            ? "🟢 Server Running" 
            : "🔴 Server Stopped"
        
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        
        let statusFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let statusColor = isRunning ? NSColor.systemGreen : NSColor.systemRed
        let statusAttributes: [NSAttributedString.Key: Any] = [
            .font: statusFont,
            .foregroundColor: statusColor
        ]
        statusItem.attributedTitle = NSAttributedString(string: statusText, attributes: statusAttributes)
        menu.addItem(statusItem)
        
        // Connection stats
        let statsText = totalCount > 0 
            ? "📊 Servers: \(connectedCount)/\(totalCount) connected"
            : "📊 No servers configured"
        
        let statsItem = NSMenuItem(title: statsText, action: nil, keyEquivalent: "")
        statsItem.isEnabled = false
        
        let statsFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let statsAttributes: [NSAttributedString.Key: Any] = [
            .font: statsFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        statsItem.attributedTitle = NSAttributedString(string: statsText, attributes: statsAttributes)
        menu.addItem(statsItem)
        
        // Endpoint info (if running)
        if isRunning {
            let endpoint = appState.serverEndpoint
            let endpointItem = NSMenuItem(title: "🌐 \(endpoint)", action: #selector(copyEndpoint), keyEquivalent: "")
            endpointItem.target = self
            
            let endpointFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let endpointAttributes: [NSAttributedString.Key: Any] = [
                .font: endpointFont,
                .foregroundColor: NSColor.linkColor
            ]
            endpointItem.attributedTitle = NSAttributedString(string: "🌐 \(endpoint)", attributes: endpointAttributes)
            menu.addItem(endpointItem)
        }
    }
    
    @objc private func copyEndpoint() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(appState.serverEndpoint, forType: .string)
        
        Task { @MainActor in
            await sendNotification(
                title: "Endpoint Copied",
                body: "Server endpoint copied to clipboard: \(appState.serverEndpoint)"
            )
        }
    }
    
        private func createEnhancedCapabilitiesSubmenu(for server: ServerStatus) -> NSMenu {
        let submenu = NSMenu()
        submenu.minimumWidth = 250
        
        // Server info header
        let serverHeader = NSMenuItem(title: server.name, action: nil, keyEquivalent: "")
        serverHeader.isEnabled = false
        let headerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: headerFont,
            .foregroundColor: NSColor.labelColor
        ]
        serverHeader.attributedTitle = NSAttributedString(string: server.name, attributes: headerAttributes)
        submenu.addItem(serverHeader)
        
        submenu.addItem(NSMenuItem.separator())
        
        var hasCapabilities = false
        
        // Tools section
        if server.capabilities.tools > 0 {
            let toolsHeader = NSMenuItem(title: "🛠️ TOOLS (\(server.capabilities.tools))", action: nil, keyEquivalent: "")
            toolsHeader.isEnabled = false
            let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let headerAttributes: [NSAttributedString.Key: Any] = [
                .font: headerFont,
                .foregroundColor: NSColor.systemBlue
            ]
            toolsHeader.attributedTitle = NSAttributedString(string: "🛠️ TOOLS (\(server.capabilities.tools))", attributes: headerAttributes)
            submenu.addItem(toolsHeader)
            
            // Add individual tools if available from aggregated capabilities
            let serverTools = appState.aggregatedCapabilities.filter { 
                $0.serverId == server.id && $0.type == .tool 
            }.prefix(5) // Limit to first 5 tools
            
            for tool in serverTools {
                let toolItem = NSMenuItem(title: "   • \(tool.originalName)", action: nil, keyEquivalent: "")
                toolItem.isEnabled = false
                let toolFont = NSFont.systemFont(ofSize: 11, weight: .regular)
                let toolAttributes: [NSAttributedString.Key: Any] = [
                    .font: toolFont,
                    .foregroundColor: NSColor.tertiaryLabelColor
                ]
                toolItem.attributedTitle = NSAttributedString(string: "   • \(tool.originalName)", attributes: toolAttributes)
                submenu.addItem(toolItem)
            }
            
            if serverTools.count < server.capabilities.tools {
                let moreItem = NSMenuItem(title: "   ... and \(server.capabilities.tools - serverTools.count) more", action: nil, keyEquivalent: "")
                moreItem.isEnabled = false
                let moreFont = NSFont.systemFont(ofSize: 10, weight: .regular)
                let moreAttributes: [NSAttributedString.Key: Any] = [
                    .font: moreFont,
                    .foregroundColor: NSColor.quaternaryLabelColor
                ]
                moreItem.attributedTitle = NSAttributedString(string: "   ... and \(server.capabilities.tools - serverTools.count) more", attributes: moreAttributes)
                submenu.addItem(moreItem)
            }
            hasCapabilities = true
        }
        
        // Resources section  
        if server.capabilities.resources > 0 {
            if hasCapabilities { submenu.addItem(NSMenuItem.separator()) }
            
            let resourcesHeader = NSMenuItem(title: "📁 RESOURCES (\(server.capabilities.resources))", action: nil, keyEquivalent: "")
            resourcesHeader.isEnabled = false
            let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let headerAttributes: [NSAttributedString.Key: Any] = [
                .font: headerFont,
                .foregroundColor: NSColor.systemGreen
            ]
            resourcesHeader.attributedTitle = NSAttributedString(string: "📁 RESOURCES (\(server.capabilities.resources))", attributes: headerAttributes)
            submenu.addItem(resourcesHeader)
            
            // Add individual resources if available
            let serverResources = appState.aggregatedCapabilities.filter { 
                $0.serverId == server.id && $0.type == .resource 
            }.prefix(5)
            
            for resource in serverResources {
                let resourceItem = NSMenuItem(title: "   • \(resource.originalName)", action: nil, keyEquivalent: "")
                resourceItem.isEnabled = false
                let resourceFont = NSFont.systemFont(ofSize: 11, weight: .regular)
                let resourceAttributes: [NSAttributedString.Key: Any] = [
                    .font: resourceFont,
                    .foregroundColor: NSColor.tertiaryLabelColor
                ]
                resourceItem.attributedTitle = NSAttributedString(string: "   • \(resource.originalName)", attributes: resourceAttributes)
                submenu.addItem(resourceItem)
            }
            
            if serverResources.count < server.capabilities.resources {
                let moreItem = NSMenuItem(title: "   ... and \(server.capabilities.resources - serverResources.count) more", action: nil, keyEquivalent: "")
                moreItem.isEnabled = false
                let moreFont = NSFont.systemFont(ofSize: 10, weight: .regular)
                let moreAttributes: [NSAttributedString.Key: Any] = [
                    .font: moreFont,
                    .foregroundColor: NSColor.quaternaryLabelColor
                ]
                moreItem.attributedTitle = NSAttributedString(string: "   ... and \(server.capabilities.resources - serverResources.count) more", attributes: moreAttributes)
                submenu.addItem(moreItem)
            }
            hasCapabilities = true
        }
        
        // Prompts section
        if server.capabilities.prompts > 0 {
            if hasCapabilities { submenu.addItem(NSMenuItem.separator()) }
            
            let promptsHeader = NSMenuItem(title: "💬 PROMPTS (\(server.capabilities.prompts))", action: nil, keyEquivalent: "")
            promptsHeader.isEnabled = false
            let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let headerAttributes: [NSAttributedString.Key: Any] = [
                .font: headerFont,
                .foregroundColor: NSColor.systemPurple
            ]
            promptsHeader.attributedTitle = NSAttributedString(string: "💬 PROMPTS (\(server.capabilities.prompts))", attributes: headerAttributes)
            submenu.addItem(promptsHeader)
            
            // Add individual prompts if available
            let serverPrompts = appState.aggregatedCapabilities.filter { 
                $0.serverId == server.id && $0.type == .prompt 
            }.prefix(5)
            
            for prompt in serverPrompts {
                let promptItem = NSMenuItem(title: "   • \(prompt.originalName)", action: nil, keyEquivalent: "")
                promptItem.isEnabled = false
                let promptFont = NSFont.systemFont(ofSize: 11, weight: .regular)
                let promptAttributes: [NSAttributedString.Key: Any] = [
                    .font: promptFont,
                    .foregroundColor: NSColor.tertiaryLabelColor
                ]
                promptItem.attributedTitle = NSAttributedString(string: "   • \(prompt.originalName)", attributes: promptAttributes)
                submenu.addItem(promptItem)
            }
            
            if serverPrompts.count < server.capabilities.prompts {
                let moreItem = NSMenuItem(title: "   ... and \(server.capabilities.prompts - serverPrompts.count) more", action: nil, keyEquivalent: "")
                moreItem.isEnabled = false
                let moreFont = NSFont.systemFont(ofSize: 10, weight: .regular)
                let moreAttributes: [NSAttributedString.Key: Any] = [
                    .font: moreFont,
                    .foregroundColor: NSColor.quaternaryLabelColor
                ]
                moreItem.attributedTitle = NSAttributedString(string: "   ... and \(server.capabilities.prompts - serverPrompts.count) more", attributes: moreAttributes)
                submenu.addItem(moreItem)
            }
        }
        
        return submenu
    }
    
    private func createCapabilitiesSubmenu(for server: ServerStatus) -> NSMenu {
        // Legacy method - delegate to enhanced version
        return createEnhancedCapabilitiesSubmenu(for: server)
    }
     
     private func createBottomActions(_ menu: NSMenu) {
        // Show App action with enhanced styling
        let showAppItem = NSMenuItem(title: "Show App", action: #selector(showPreferences), keyEquivalent: ",")
        showAppItem.target = self
        
        let showAppFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let showAppAttributes: [NSAttributedString.Key: Any] = [
            .font: showAppFont,
            .foregroundColor: NSColor.labelColor
        ]
        showAppItem.attributedTitle = NSAttributedString(string: "Show App", attributes: showAppAttributes)
        
        if let showAppImage = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "Show App") {
            showAppImage.size = NSSize(width: 16, height: 16)
            showAppItem.image = showAppImage
        }
        menu.addItem(showAppItem)
        
        // Add a subtle separator
        menu.addItem(NSMenuItem.separator())
        
        // Quit action with enhanced styling
        let quitItem = NSMenuItem(title: "Quit OneMCP", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        
        let quitFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let quitAttributes: [NSAttributedString.Key: Any] = [
            .font: quitFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        quitItem.attributedTitle = NSAttributedString(string: "Quit OneMCP", attributes: quitAttributes)
        
        if let quitImage = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit") {
            quitImage.size = NSSize(width: 16, height: 16)
            quitItem.image = quitImage
        }
        menu.addItem(quitItem)
    }
    
    private func updateConnectedServersMenu(_ menu: NSMenu) {
        // Remove existing server items
        let itemsToRemove = menu.items.filter { item in
            item.representedObject as? String == "server_item" || item.representedObject as? String == "servers_header"
        }
        itemsToRemove.forEach { menu.removeItem($0) }
        
        let connectedServers = appState.serverStatuses.filter { $0.status == .connected }
        
        // Add servers section header
        if !connectedServers.isEmpty {
            let headerItem = NSMenuItem(title: "Connected Servers", action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            headerItem.representedObject = "servers_header"
            
            let headerFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let headerAttributes: [NSAttributedString.Key: Any] = [
                .font: headerFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            headerItem.attributedTitle = NSAttributedString(string: "CONNECTED SERVERS", attributes: headerAttributes)
            menu.addItem(headerItem)
        }
        
        if connectedServers.isEmpty {
            // Show elegant message when no servers connected
            let noServersItem = NSMenuItem(title: "💤 No servers connected", action: #selector(showPreferences), keyEquivalent: "")
            noServersItem.target = self
            noServersItem.representedObject = "server_item"
            
            // Style as interactive item
            let font = NSFont.systemFont(ofSize: 13, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            noServersItem.attributedTitle = NSAttributedString(string: "💤 No servers connected", attributes: attributes)
            menu.addItem(noServersItem)
            
            // Add suggestion to configure servers
            let configureItem = NSMenuItem(title: "⚙️ Configure servers", action: #selector(showPreferences), keyEquivalent: "")
            configureItem.target = self
            configureItem.representedObject = "server_item"
            
            let configureFont = NSFont.systemFont(ofSize: 12, weight: .medium)
            let configureAttributes: [NSAttributedString.Key: Any] = [
                .font: configureFont,
                .foregroundColor: NSColor.controlAccentColor
            ]
            configureItem.attributedTitle = NSAttributedString(string: "⚙️ Configure servers", attributes: configureAttributes)
            menu.addItem(configureItem)
        } else {
            // Add each connected server with enhanced styling
            for (index, server) in connectedServers.enumerated() {
                let serverItem = NSMenuItem(title: server.name, action: #selector(showServerDetails), keyEquivalent: "")
                serverItem.representedObject = "server_item"
                serverItem.tag = index
                serverItem.target = self
                
                // Status icon based on capabilities
                let statusIcon: String = server.capabilities.total > 0 ? "checkmark.circle.fill" : "circle"
                let iconColor: NSColor = server.capabilities.total > 0 ? .systemGreen : .systemYellow
                
                if let statusImage = NSImage(systemSymbolName: statusIcon, accessibilityDescription: "Connected") {
                    statusImage.size = NSSize(width: 14, height: 14)
                    // Tint the image
                    let tintedImage = statusImage.copy() as! NSImage
                    tintedImage.lockFocus()
                    iconColor.set()
                    statusImage.draw(at: .zero, from: NSRect(origin: .zero, size: statusImage.size), operation: .sourceAtop, fraction: 1.0)
                    tintedImage.unlockFocus()
                    serverItem.image = tintedImage
                }
                
                // Enhanced server display
                let capabilityCount = server.capabilities.total
                let serverName = server.name.count > 20 ? String(server.name.prefix(20)) + "..." : server.name
                
                let font = NSFont.systemFont(ofSize: 13, weight: .medium)
                let detailFont = NSFont.systemFont(ofSize: 10, weight: .regular)
                
                let attributedTitle = NSMutableAttributedString()
                
                // Server name
                attributedTitle.append(NSAttributedString(string: serverName, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor
                ]))
                
                // Capability details
                if capabilityCount > 0 {
                    attributedTitle.append(NSAttributedString(string: "\n\(capabilityCount) capabilities", attributes: [
                        .font: detailFont,
                        .foregroundColor: NSColor.systemGreen
                    ]))
                    
                    if server.capabilities.tools > 0 || server.capabilities.resources > 0 || server.capabilities.prompts > 0 {
                        var details: [String] = []
                        if server.capabilities.tools > 0 { details.append("🛠 \(server.capabilities.tools)") }
                        if server.capabilities.resources > 0 { details.append("📁 \(server.capabilities.resources)") }
                        if server.capabilities.prompts > 0 { details.append("💬 \(server.capabilities.prompts)") }
                        
                        attributedTitle.append(NSAttributedString(string: "\n\(details.joined(separator: "  "))", attributes: [
                            .font: detailFont,
                            .foregroundColor: NSColor.tertiaryLabelColor
                        ]))
                    }
                } else {
                    attributedTitle.append(NSAttributedString(string: "\nNo capabilities", attributes: [
                        .font: detailFont,
                        .foregroundColor: NSColor.tertiaryLabelColor
                    ]))
                }
                
                serverItem.attributedTitle = attributedTitle
                
                // Create enhanced submenu with capabilities
                if server.capabilities.total > 0 {
                    let submenu = createEnhancedCapabilitiesSubmenu(for: server)
                    serverItem.submenu = submenu
                }
                
                menu.addItem(serverItem)
            }
        }
    }
    

    
    func updateMenu() async {
        guard statusItem?.menu != nil else { return }
        
        // Force recreate the menu to update server list
        await MainActor.run {
            createMenu()
            updateMenuBarStatus()
        }
    }
    
    func forceMenuUpdate() {
        createMenu()
        updateMenuBarStatus()
    }
    
    // MARK: - Actions
    

    
    @objc private func showMainWindow() {
        print("[MenuBarManager] showMainWindow called")
        // Use AppDelegate's showMainWindow method which has more robust window creation logic
        if let appDelegate = NSApp.delegate as? AppDelegate {
            print("[MenuBarManager] Calling AppDelegate.showMainWindow")
            appDelegate.showMainWindow()
        } else {
            print("[MenuBarManager] AppDelegate not found, using fallback")
            // Fallback to previous implementation if AppDelegate is not available
            showMainWindowFallback()
        }
    }
    
    private func showMainWindowFallback() {
        // Get current activation policy and window info
        let currentPolicy = NSApp.activationPolicy()
        
        // Temporarily change activation policy to regular to ensure window shows properly
        if currentPolicy == .accessory {
            NSApp.setActivationPolicy(.regular)
        }
        
        // Activate the application first
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        // Find the main application window (not status bar or popup windows)
        let mainWindow = NSApplication.shared.windows.first { window in
            let className = window.className
            return !className.contains("StatusBar") && 
                   !className.contains("PopupMenu") &&
                   !className.contains("NSMenu") &&
                   className.contains("NSWindow")
        }
        
        if let window = mainWindow {
            // Force window to be visible
            window.setIsVisible(true)
            window.deminiaturize(window)
            window.makeKeyAndOrderFront(window)
            window.orderFrontRegardless()
            
            // Ensure window is visible and focused
            window.level = NSWindow.Level.normal
            window.collectionBehavior = [NSWindow.CollectionBehavior.canJoinAllSpaces, NSWindow.CollectionBehavior.fullScreenAuxiliary]
            
        } else {
            // No window exists, need to create one
            // Use AppDelegate's createNewWindow method
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.createNewWindow()
            } else {
                // Fallback: Try to find and trigger new window action from main menu
                if let mainMenu = NSApp.mainMenu {
                    findAndTriggerNewWindowAction(in: mainMenu)
                }
            }
        }
        
        // If we temporarily changed to regular, schedule a restore after the window is shown
        if currentPolicy == .accessory && !appState.config.ui.showInDock {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { // Increased delay
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
    
    @objc private func showServerDetails(_ sender: NSMenuItem) {
        let connectedServers = appState.serverStatuses.filter { $0.status == .connected }
        guard sender.tag < connectedServers.count else { 
            // If tag is out of range, just show main window
            showMainWindow()
            return 
        }
        
        let server = connectedServers[sender.tag]
        
        // Show elegant server details notification
        let capabilityText = server.capabilities.total > 0 
            ? "🛠️ \(server.capabilities.tools) tools • 📁 \(server.capabilities.resources) resources • 💬 \(server.capabilities.prompts) prompts"
            : "No capabilities available"
        
        Task { @MainActor in
            await sendNotification(
                title: "🟢 \(server.name)",
                body: "Status: Connected\n\(capabilityText)"
            )
        }
        
        // Also open main window to show more details
        showMainWindow()
    }
    

    
    @objc private func showPreferences() {
        // Use the improved showMainWindow method
        showMainWindow()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    private func findAndTriggerNewWindowAction(in menu: NSMenu) {
        for item in menu.items {
            // Check if this menu item can create a new window
            if let title = item.title.lowercased() as String?, 
               title.contains("new") && title.contains("window") &&
               item.action != nil {
                // Trigger the action using NSApp.sendAction
                NSApp.sendAction(item.action!, to: item.target, from: item)
                return
            }
            
            // Recursively check submenus
            if let submenu = item.submenu {
                findAndTriggerNewWindowAction(in: submenu)
            }
        }
    }
    
    // MARK: - Notifications
    
    private func requestNotificationPermission() {
        // Temporarily disabled to prevent crashes - notifications will work without explicit permission request
        return
        
        /* 
        // Check if we're running in a proper app bundle context
        guard Bundle.main.bundleIdentifier != nil else {
            print("Skipping notification permission request - not running in app bundle context")
            return
        }
        
        // Only request notifications if we have a proper UI context
        Task { @MainActor in
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                print("Notification permission granted: \(granted)")
            } catch {
                print("Notification permission error: \(error)")
            }
        }
        */
    }
    
    @MainActor
    func sendNotification(title: String, body: String, identifier: String = UUID().uuidString) async {
        guard appState.config.ui.enableNotifications else { return }
        
        // Check if we're running in a proper app bundle context
        guard Bundle.main.bundleIdentifier != nil else {
            print("Notification: \(title) - \(body)")
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("Failed to send notification: \(error)")
        }
    }
    
    @MainActor
    func sendServerStatusNotification(_ status: ServerStatus) async {
        let statusMessage: String
        switch status.status {
        case .connected:
            statusMessage = "Server '\(status.name)' connected successfully"
        case .disconnected:
            statusMessage = "Server '\(status.name)' disconnected"
        case .error:
            statusMessage = "Server '\(status.name)' connection failed: \(status.lastError ?? "Unknown error")"
        case .connecting:
            return // Don't send notifications for connecting state
        }
        
        await sendNotification(title: "OneMCP Server Update", body: statusMessage)
    }
    
    deinit {
        // Note: statusItem will be automatically cleaned up when the object is deallocated
        // Explicit cleanup in deinit can cause concurrency issues with @MainActor
    }
}