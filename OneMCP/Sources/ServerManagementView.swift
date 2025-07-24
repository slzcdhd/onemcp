import SwiftUI
import Foundation

struct ServerManagementView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAddServer = false
    @State private var editingServer: ServerConfig?
    
    var body: some View {
        VStack(spacing: 0) {
            // Compact Header
            HStack {
                HStack(spacing: 12) {
                    Text("MCP Servers")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    // Server count badge
                    HStack(spacing: 4) {
                        Circle()
                            .fill(appState.config.upstreamServers.isEmpty ? Color.gray : Color.green)
                            .frame(width: 6, height: 6)
                        Text("\(appState.config.upstreamServers.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                }
                
                Spacer()
                
                // Enhanced Action Buttons
                HStack(spacing: 12) {
                    Button(action: {
                        showingAddServer = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 16, weight: .medium))
                            Text("Add Server")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(
                                colors: [Color.blue, Color.blue.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .shadow(color: .blue.opacity(0.3), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(1.0)
                    .animation(.easeInOut(duration: 0.2), value: showingAddServer)
                    
                    if !appState.config.upstreamServers.isEmpty {
                        Button(action: {
                            // Refresh connections
                            Task {
                                do {
                                    // Restart the MCP service to refresh all connections
                                    try await appState.mcpAggregationService.restart(config: appState.config)
                                    appState.logger.info("Refreshed all server connections")
                                    
                                    // Force menu bar update
                                    if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                                        appDelegate.menuBarManager?.forceMenuUpdate()
                                    }
                                } catch {
                                    appState.logger.error("Failed to refresh connections: \(error)")
                                }
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 14, weight: .medium))
                                Text("Refresh")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                            .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))
            
            // Content Area
            if appState.config.upstreamServers.isEmpty {
                EmptyStateView(onAddServer: { showingAddServer = true })
            } else {
                ModernServerListView(
                    servers: appState.config.upstreamServers,
                    serverStatuses: appState.serverStatuses,
                    onEdit: { editingServer = $0 },
                    onToggle: { appState.toggleServer(id: $0) },
                    onDelete: { appState.removeServer(id: $0) }
                )
            }
        }
        .frame(minHeight: 600)
        .onAppear {
            // Ensure server statuses are initialized
            if appState.serverStatuses.isEmpty && !appState.config.upstreamServers.isEmpty {
                // Initialize statuses for servers that don't have one
                for server in appState.config.upstreamServers {
                    if !appState.serverStatuses.contains(where: { $0.id == server.id }) {
                        let status = ServerStatus(
                            id: server.id,
                            name: server.name,
                            status: .disconnected,
                            lastError: nil,
                            capabilities: CapabilityCount(tools: 0, resources: 0, prompts: 0)
                        )
                        appState.serverStatuses.append(status)
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddServer) {
            AddServerView()
                .environmentObject(appState)
        }
        .sheet(item: $editingServer) { server in
            EditServerView(server: server)
                .environmentObject(appState)
        }
    }
}

// MARK: - Empty State View

struct EmptyStateView: View {
    let onAddServer: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            // Animated Server Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                
                Image(systemName: "server.rack")
                    .font(.system(size: 48, weight: .light))
                    .foregroundColor(.blue)
            }
            
            VStack(spacing: 12) {
                Text("No MCP Servers Configured")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Text("Add your first MCP server to start aggregating capabilities from multiple sources")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .padding(.horizontal, 40)
            }
            
            // Feature highlights
            VStack(spacing: 12) {
                FeatureRow(icon: "command", title: "Standard I/O", description: "Connect to CLI-based MCP servers")
                FeatureRow(icon: "globe", title: "HTTP/SSE", description: "Connect to web-based MCP services")
                FeatureRow(icon: "gearshape.2", title: "Easy Management", description: "Configure and monitor all connections")
            }
            .padding(.horizontal, 60)
            
            Button(action: onAddServer) {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                    Text("Add Your First Server")
                        .font(.headline)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        colors: [Color.blue, Color.blue.opacity(0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(25)
                .shadow(color: .blue.opacity(0.4), radius: 12, x: 0, y: 6)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.blue)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
}

// MARK: - Modern Server List View

struct ModernServerListView: View {
    let servers: [ServerConfig]
    let serverStatuses: [ServerStatus]
    let onEdit: (ServerConfig) -> Void
    let onToggle: (UUID) -> Void
    let onDelete: (UUID) -> Void
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(servers) { server in
                    ModernServerCard(
                        server: server,
                        status: serverStatuses.first { $0.id == server.id },
                        onEdit: { onEdit(server) },
                        onToggle: { onToggle(server.id) },
                        onDelete: { onDelete(server.id) }
                    )
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.8).combined(with: .opacity),
                        removal: .scale(scale: 0.8).combined(with: .opacity)
                    ))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(NSColor.windowBackgroundColor),
                    Color(NSColor.windowBackgroundColor).opacity(0.95)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: servers.count)
    }
}

struct ModernServerCard: View {
    let server: ServerConfig
    let status: ServerStatus?
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void
    
    @State private var isToggling = false
    @State private var isHovered = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Card Content
            VStack(spacing: 12) {
                // Header with server info and actions
                HStack(spacing: 12) {
                    // Server Information
                    VStack(alignment: .leading, spacing: 8) {
                        // Server name and type badge
                        HStack(spacing: 12) {
                            Text(server.name)
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            
                            Spacer()
                            
                            // Action buttons group
                            HStack(spacing: 6) {
                                // Edit button
                                EnhancedActionButton(
                                    icon: "pencil",
                                    color: .blue,
                                    backgroundColor: .blue.opacity(0.1),
                                    action: onEdit
                                )
                                
                                // Delete button
                                EnhancedActionButton(
                                    icon: "trash",
                                    color: .red,
                                    backgroundColor: .red.opacity(0.1),
                                    action: onDelete
                                )
                            }
                        }
                        
                        // Configuration summary with icon
                        HStack(spacing: 8) {
                            Image(systemName: configIcon)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            
                            Text(configurationSummary)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        // Status, capabilities and toggle row
                        HStack(spacing: 16) {
                            // Combined status and toggle
                            HStack(spacing: 8) {
                                // Status indicator
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 8, height: 8)
                                
                                Text(status?.status.displayName ?? "Disconnected")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(statusColor)
                                
                                // Toggle button integrated with status
                                Button(action: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                        isToggling = true
                                        onToggle()
                                    }
                                    
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            isToggling = false
                                        }
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        if isToggling {
                                            ProgressView()
                                                .scaleEffect(0.4)
                                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        } else {
                                            Image(systemName: server.enabled ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 8, weight: .semibold))
                                        }
                                        
                                        Text(server.enabled ? "On" : "Off")
                                            .font(.system(size: 9, weight: .medium))
                                    }
                                    .foregroundColor(server.enabled ? .white : .secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .frame(minWidth: 40)
                                    .background(
                                        Capsule()
                                            .fill(server.enabled ? 
                                                  LinearGradient(colors: [.green, .green.opacity(0.8)], startPoint: .leading, endPoint: .trailing) :
                                                  LinearGradient(colors: [Color.secondary.opacity(0.2), Color.secondary.opacity(0.1)], startPoint: .leading, endPoint: .trailing)
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            
                            Spacer()
                            
                            // Error indicator if present (left of capabilities)
                            if let lastError = status?.lastError {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.orange)
                                    
                                    Text("Error")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.orange)
                                }
                                .help(lastError)
                            }
                            
                            // Capabilities with enhanced styling - right aligned
                            if let status = status, status.capabilities.total > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "gearshape.2.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.blue)
                                    
                                    Text("\(status.capabilities.total)")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.blue)
                                    
                                    Text("capabilities")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(Color.blue.opacity(0.1))
                                )
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(NSColor.controlBackgroundColor),
                            Color(NSColor.controlBackgroundColor).opacity(0.8)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(isHovered ? 0.12 : 0.06), radius: isHovered ? 12 : 8, x: 0, y: isHovered ? 6 : 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    LinearGradient(
                        colors: server.enabled ? 
                            [statusColor.opacity(0.3), statusColor.opacity(0.1)] : 
                            [Color.secondary.opacity(0.1), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: server.enabled ? 1.5 : 1
                )
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
    }
    
    private var statusColor: Color {
        guard let status = status else { return .gray }
        return status.status.color
    }
    
    private var statusIcon: String {
        guard let status = status else { return "circle.fill" }
        switch status.status {
        case .connected:
            return "checkmark.circle.fill"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .disconnected:
            return "circle"
        case .error:
            return "exclamationmark.circle.fill"
        }
    }
    
    private var typeColor: Color {
        switch server.type {
        case .stdio: return .orange
        case .sse: return .purple
        case .streamableHttp: return .green
        }
    }
    
    private var configIcon: String {
        switch server.type {
        case .stdio: return "terminal"
        case .sse: return "globe"
        case .streamableHttp: return "network"
        }
    }
    
    private var configurationSummary: String {
        switch server.config {
        case .stdio(let config):
            return "\(config.command) \(config.arguments.joined(separator: " "))"
        case .sse(let config):
            return config.url.absoluteString
        case .streamableHttp(let config):
            return config.url.absoluteString
        }
    }
}

struct EnhancedActionButton: View {
    let icon: String
    let color: Color
    let backgroundColor: Color
    let action: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(backgroundColor)
                )
                .overlay(
                    Circle()
                        .stroke(color.opacity(0.2), lineWidth: 1)
                )
                .scaleEffect(isPressed ? 0.95 : 1.0)
        }
        .buttonStyle(.plain)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = true
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeInOut(duration: 0.1)) {
                    isPressed = false
                }
                action()
            }
        }
    }
}

// MARK: - UI Components

struct ServerTypeBadge: View {
    let type: ServerType
    
    var body: some View {
        Text(type.displayName)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(typeColor.opacity(0.2))
            .foregroundColor(typeColor)
            .cornerRadius(6)
    }
    
    private var typeColor: Color {
        switch type {
        case .stdio: return .orange
        case .sse: return .purple
        case .streamableHttp: return .green
        }
    }
}

struct StatusBadge: View {
    let status: ConnectionStatus
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
            
            Text(status.displayName)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(status.color)
        }
    }
}

struct CapabilityBadge: View {
    let count: Int
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gearshape.2")
                .font(.caption)
            Text("\(count)")
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundColor(.blue)
    }
}

struct ErrorBadge: View {
    let error: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
            Text(String(error.prefix(20)) + (error.count > 20 ? "..." : ""))
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundColor(.red)
    }
}

struct ActionButton: View {
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.1))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct ServerRowView: View {
    let server: ServerConfig
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void
    
    @EnvironmentObject var appState: AppState
    
    private var serverStatus: ServerStatus? {
        appState.serverStatuses.first { $0.id == server.id }
    }
    
    var body: some View {
        HStack {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
            
            VStack(alignment: .leading, spacing: 4) {
                // Server name and type
                HStack {
                    Text(server.name)
                        .font(.headline)
                    
                    Text(server.type.displayName)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
                
                // Configuration details
                Text(configurationSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // Status and capabilities
                if let status = serverStatus {
                    HStack {
                        Text(status.status.displayName)
                            .font(.caption)
                            .foregroundColor(status.status.color)
                        
                        if status.capabilities.total > 0 {
                            Text("• \(status.capabilities.total) capabilities")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if let lastError = status.lastError {
                            Text("• \(lastError)")
                                .font(.caption)
                                .foregroundColor(.red)
                                .lineLimit(1)
                        }
                    }
                }
            }
            
            Spacer()
            
            // Controls
            HStack(spacing: 8) {
                // Enable/Disable toggle
                Button(action: onToggle) {
                    Image(systemName: server.enabled ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(server.enabled ? .green : .secondary)
                }
                
                // Edit button
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                
                // Delete button
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
    
    private var statusColor: Color {
        guard let status = serverStatus else { return .gray }
        return status.status.color
    }
    
    private var configurationSummary: String {
        switch server.config {
        case .stdio(let config):
            return "\(config.command) \(config.arguments.joined(separator: " "))"
        case .sse(let config):
            return config.url.absoluteString
        case .streamableHttp(let config):
            return config.url.absoluteString
        }
    }
}

struct AddServerView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    @State private var serverName = ""
    @State private var configurationJSON = ""
    @State private var showingError = false
    @State private var errorMessage = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Clean Header with integrated action
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add MCP Server")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Configure a new Model Context Protocol server")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                    
                    Button("Add Server") {
                        addServer()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(serverName.isEmpty || configurationJSON.isEmpty)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Form Content
            ScrollView {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Server Name")
                            .font(.headline)
                            .fontWeight(.medium)
                        
                        TextField("e.g., playwright, context7", text: $serverName)
                            .textFieldStyle(.roundedBorder)
                            .font(.body)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Configuration")
                            .font(.headline)
                            .fontWeight(.medium)
                        
                        ZStack(alignment: .topLeading) {
                            // Always show the TextEditor
                            TextEditor(text: $configurationJSON)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 200)
                                .padding(8)
                                .background(Color(NSColor.textBackgroundColor))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )
                            
                            // Show example text as overlay when empty
                            if configurationJSON.isEmpty {
                                VStack {
                                    HStack {
                                        Text("Example:")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                                    
                                    HStack {
                                        Text(stdioExampleText)
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .opacity(0.7)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 8)
                                    
                                    Spacer()
                                }
                                .allowsHitTesting(false) // Allow clicks to pass through to TextEditor
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .alert("Configuration Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
                }
    }
    
    private var stdioExampleText: String {
        return """
// For stdio servers (required: command):
{
  "command": "npx",
  "args": ["@modelcontextprotocol/server-playwright"],  // optional
  "env": {                                               // optional
    "HEADLESS": "true"
  }
}

// Minimal stdio example:
{
  "command": "/usr/local/bin/my-mcp-server"
}

// For HTTP servers (required: url):
{
  "url": "http://localhost:3000",
  "type": "sse"  // optional, defaults to "streamable-http"
}
"""
    }
    
    private func addServer() {
        guard !serverName.isEmpty, !configurationJSON.isEmpty else {
            return
        }
        
        do {
            // Parse the JSON configuration
            guard let configData = configurationJSON.data(using: .utf8) else {
                throw ConfigurationError.invalidJSON
            }
            
            let jsonObject = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
            guard let config = jsonObject else {
                throw ConfigurationError.invalidJSON
            }
            
            // Create server config based on configuration (auto-detect type)
            let serverConfig = try createServerConfig(name: serverName, config: config)
            
            // Add to app state
            appState.addServer(serverConfig)
            
            // Dismiss view
            dismiss()
            
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
    
    private func createServerConfig(name: String, config: [String: Any]) throws -> ServerConfig {
        // Auto-detect server type based on configuration
        if let command = config["command"] as? String {
            // This is a stdio server
            let args = config["args"] as? [String] ?? []  // args is optional, default to empty array
            let environment = config["env"] as? [String: String]
            let workingDirectory = config["workingDirectory"] as? String
            
            let stdioConfig = StdioConfig(
                command: command,
                arguments: args,
                environment: environment,
                workingDirectory: workingDirectory
            )
            
            return ServerConfig(name: name, type: .stdio, config: .stdio(stdioConfig))
            
        } else if let urlString = config["url"] as? String,
                  let url = URL(string: urlString) {
            // This is a URL-based server, check the type field
            let headers = config["headers"] as? [String: String]
            let typeString = config["type"] as? String
            
            switch typeString {
            case "sse":
                let sseConfig = SseConfig(url: url, headers: headers)
                return ServerConfig(name: name, type: .sse, config: .sse(sseConfig))
            case "streamable-http":
                let httpConfig = HttpConfig(url: url, headers: headers)
                return ServerConfig(name: name, type: .streamableHttp, config: .streamableHttp(httpConfig))
            default:
                // If no type specified, default to streamable-http for URL-based configs
                let httpConfig = HttpConfig(url: url, headers: headers)
                return ServerConfig(name: name, type: .streamableHttp, config: .streamableHttp(httpConfig))
            }
            
        } else {
            throw ConfigurationError.invalidConfiguration
        }
    }
}



struct EditServerView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    let server: ServerConfig
    @State private var serverName = ""
    @State private var configurationJSON = ""
    @State private var showingError = false
    @State private var errorMessage = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Clean Header with integrated action
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edit MCP Server")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Modify Model Context Protocol server configuration")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                    
                    Button("Save Changes") {
                        saveServer()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(serverName.isEmpty || configurationJSON.isEmpty)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Form Content
            ScrollView {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Server Name")
                            .font(.headline)
                            .fontWeight(.medium)
                        
                        TextField("Server name", text: $serverName)
                            .textFieldStyle(.roundedBorder)
                            .font(.body)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Configuration")
                            .font(.headline)
                            .fontWeight(.medium)
                        
                        TextEditor(text: $configurationJSON)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 200)
                            .padding(8)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .alert("Configuration Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            loadServerData()
        }
    }
    
    private func loadServerData() {
        serverName = server.name
        configurationJSON = generateConfigurationJSON()
    }
    
    private func generateConfigurationJSON() -> String {
        do {
            switch server.config {
            case .stdio(let config):
                var dict: [String: Any] = [
                    "command": config.command,
                    "args": config.arguments
                ]
                
                // Only add environment if it's not empty
                if let environment = config.environment, !environment.isEmpty {
                    dict["env"] = environment
                }
                
                // Only add workingDirectory if it's not empty
                if let workingDirectory = config.workingDirectory, !workingDirectory.isEmpty {
                    dict["workingDirectory"] = workingDirectory
                }
                
                let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                return String(data: data, encoding: .utf8) ?? "{}"
                
            case .sse(let config):
                var dict: [String: Any] = [
                    "type": "sse",
                    "url": config.url.absoluteString
                ]
                
                // Only add headers if they exist and not empty
                if let headers = config.headers, !headers.isEmpty {
                    dict["headers"] = headers
                }
                
                let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                return String(data: data, encoding: .utf8) ?? "{}"
                
            case .streamableHttp(let config):
                var dict: [String: Any] = [
                    "type": "streamable-http",
                    "url": config.url.absoluteString
                ]
                
                // Only add headers if they exist and not empty
                if let headers = config.headers, !headers.isEmpty {
                    dict["headers"] = headers
                }
                
                let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                return String(data: data, encoding: .utf8) ?? "{}"
            }
        } catch {
            return "{}"
        }
    }
    
    private func saveServer() {
        guard !serverName.isEmpty, !configurationJSON.isEmpty else {
            return
        }
        
        do {
            // Parse the JSON configuration
            guard let configData = configurationJSON.data(using: .utf8) else {
                throw ConfigurationError.invalidJSON
            }
            
            let jsonObject = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
            guard let config = jsonObject else {
                throw ConfigurationError.invalidJSON
            }
            
            // Create updated server config
            let updatedServerConfig = try createServerConfig(name: serverName, config: config)
            
            // Create new config with same ID but updated properties
            let finalServerConfig = ServerConfig(
                id: server.id,
                name: updatedServerConfig.name,
                type: updatedServerConfig.type,
                enabled: server.enabled,
                config: updatedServerConfig.config,
                retryConfig: updatedServerConfig.retryConfig
            )
            
            // Update in app state
            appState.updateServer(finalServerConfig)
            
            // Dismiss view
            dismiss()
            
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
    
    private func createServerConfig(name: String, config: [String: Any]) throws -> ServerConfig {
        // Auto-detect server type based on configuration (same as AddServerView)
        if let command = config["command"] as? String {
            // This is a stdio server
            let args = config["args"] as? [String] ?? []  // args is optional, default to empty array
            let environment = config["env"] as? [String: String]
            let workingDirectory = config["workingDirectory"] as? String
            
            let stdioConfig = StdioConfig(
                command: command,
                arguments: args,
                environment: environment,
                workingDirectory: workingDirectory
            )
            
            return ServerConfig(name: name, type: .stdio, config: .stdio(stdioConfig))
            
        } else if let urlString = config["url"] as? String,
                  let url = URL(string: urlString) {
            // This is a URL-based server, check the type field
            let headers = config["headers"] as? [String: String]
            let typeString = config["type"] as? String
            
            switch typeString {
            case "sse":
                let sseConfig = SseConfig(url: url, headers: headers)
                return ServerConfig(name: name, type: .sse, config: .sse(sseConfig))
            case "streamable-http":
                let httpConfig = HttpConfig(url: url, headers: headers)
                return ServerConfig(name: name, type: .streamableHttp, config: .streamableHttp(httpConfig))
            default:
                // If no type specified, default to streamable-http for URL-based configs
                let httpConfig = HttpConfig(url: url, headers: headers)
                return ServerConfig(name: name, type: .streamableHttp, config: .streamableHttp(httpConfig))
            }
            
        } else {
            throw ConfigurationError.invalidConfiguration
        }
    }
}

// MARK: - Modern UI Components

struct ModernCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content
    
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.blue)
                
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
            }
            
            content
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
    }
}

struct ModernTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
            
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(text.isEmpty ? Color.secondary.opacity(0.3) : Color.blue, lineWidth: 1)
                )
                .cornerRadius(12)
        }
    }
}

struct ModernButtonStyle: ButtonStyle {
    let isEnabled: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: isEnabled ? [Color.blue, Color.blue.opacity(0.8)] : [Color.gray, Color.gray.opacity(0.8)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(25)
            .shadow(
                color: isEnabled ? .blue.opacity(0.4) : .clear,
                radius: isEnabled ? 12 : 0,
                x: 0,
                y: isEnabled ? 6 : 0
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

enum ConfigurationError: LocalizedError {
    case invalidJSON
    case missingRequiredFields
    case invalidURL
    case invalidConfiguration
    
    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Invalid JSON format"
        case .missingRequiredFields:
            return "Missing required configuration fields"
        case .invalidURL:
            return "Invalid URL format"
        case .invalidConfiguration:
            return "Invalid configuration format. For stdio servers: 'command' is required. For HTTP servers: 'url' is required."
        }
    }
}

#Preview {
    ServerManagementView()
        .environmentObject(AppState())
} 