import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: TabSelection = .overview
    
    enum TabSelection: String, CaseIterable {
        case overview = "Overview"
        case servers = "Servers"
        case capabilities = "Capabilities"
        case logs = "Logs"
        case advanced = "Advanced"
        
        var icon: String {
            switch self {
            case .overview: return "house"
            case .servers: return "server.rack"
            case .capabilities: return "list.bullet.rectangle"
            case .logs: return "text.alignleft"
            case .advanced: return "gearshape.2"
            }
        }
    }
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(TabSelection.allCases, id: \.self, selection: $selectedTab) { tab in
                NavigationLink(value: tab) {
                    Label(tab.rawValue, systemImage: tab.icon)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
            .navigationTitle("OneMCP")
        } detail: {
            // Main content
            Group {
                switch selectedTab {
                case .overview:
                    OverviewView()
                case .servers:
                    ServersView()
                case .capabilities:
                    CapabilitiesView()
                case .logs:
                    LogsView()
                case .advanced:
                    AdvancedSettingsView()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                serverStatusIndicator
            }
        }
    }
    
    private var serverStatusIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appState.isServerRunning ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            
            Text(appState.isServerRunning ? "Running" : "Stopped")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Overview View

struct OverviewView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                // Server Status Card
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("MCP Aggregation Server")
                            .font(.headline)
                        Spacer()
                        Text(appState.isServerRunning ? "Running" : "Stopped")
                            .foregroundColor(appState.isServerRunning ? .green : .red)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.secondary.opacity(0.1))
                            )
                    }
                    
                    if appState.isServerRunning {
                        Text("Endpoint: \(appState.serverEndpoint)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Stats
                    HStack(spacing: 30) {
                        StatView(title: "Upstream Servers", value: "\(appState.serverStatuses.count)")
                        StatView(title: "Connected", value: "\(connectedServersCount)")
                        StatView(title: "Total Capabilities", value: "\(totalCapabilities)")
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                // Upstream Servers Status
                VStack(alignment: .leading, spacing: 16) {
                    Text("Upstream Servers")
                        .font(.headline)
                    
                    if appState.serverStatuses.isEmpty {
                        Text("No servers configured")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else {
                        ForEach(appState.serverStatuses) { status in
                            ServerStatusRow(status: status)
                        }
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding()
        }
        .navigationTitle("Overview")
    }
    
    private var connectedServersCount: Int {
        appState.serverStatuses.filter { $0.status == .connected }.count
    }
    
    private var totalCapabilities: Int {
        appState.aggregatedCapabilities.count
    }
}

struct StatView: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack {
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct ServerStatusRow: View {
    let status: ServerStatus
    
    var body: some View {
        HStack {
            Circle()
                .fill(status.status.color)
                .frame(width: 8, height: 8)
            
            Text(status.name)
                .fontWeight(.medium)
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                Text(status.status.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if status.capabilities.total > 0 {
                    Text("\(status.capabilities.total) capabilities")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Placeholder Views

struct ServersView: View {
    var body: some View {
        ServerManagementView()
            .navigationTitle("Servers")
    }
}

struct CapabilitiesView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                // Summary Card
                VStack(alignment: .leading, spacing: 16) {
                    Text("Aggregated Capabilities")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    if appState.aggregatedCapabilities.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "gearshape.2")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            
                            Text("No capabilities available")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            
                            Text("Connect to MCP servers to see their capabilities here")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        // Capability counts
                        HStack(spacing: 30) {
                            CapabilityStatView(
                                title: "Tools", 
                                count: appState.aggregatedCapabilities.filter { $0.type == .tool }.count,
                                icon: "wrench.and.screwdriver",
                                color: .blue
                            )
                            CapabilityStatView(
                                title: "Resources", 
                                count: appState.aggregatedCapabilities.filter { $0.type == .resource }.count,
                                icon: "doc.text",
                                color: .green
                            )
                            CapabilityStatView(
                                title: "Prompts", 
                                count: appState.aggregatedCapabilities.filter { $0.type == .prompt }.count,
                                icon: "text.bubble",
                                color: .purple
                            )
                        }
                        
                        Divider()
                        
                        // Capabilities List
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(groupedCapabilities.keys.sorted(), id: \.self) { serverName in
                                CapabilityServerSection(
                                    serverName: serverName,
                                    capabilities: groupedCapabilities[serverName] ?? []
                                )
                            }
                        }
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        }
        .navigationTitle("Capabilities")
    }
    
    private var groupedCapabilities: [String: [AggregatedCapability]] {
        Dictionary(grouping: appState.aggregatedCapabilities) { $0.serverName }
    }
}

struct CapabilityStatView: View {
    let title: String
    let count: Int
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
                
                Text("\(count)")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct CapabilityServerSection: View {
    let serverName: String
    let capabilities: [AggregatedCapability]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Server Header
            HStack {
                Text(serverName)
                    .font(.headline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Text("\(capabilities.count) capabilities")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
            }
            
            // Capabilities
            VStack(spacing: 4) {
                ForEach(capabilities.sorted(by: { $0.originalName < $1.originalName })) { capability in
                    CapabilityRowView(capability: capability)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

struct CapabilityRowView: View {
    let capability: AggregatedCapability
    
    var body: some View {
        HStack(spacing: 12) {
            // Type Icon
            Image(systemName: capability.type.icon)
                .font(.system(size: 14))
                .foregroundColor(capability.type.color)
                .frame(width: 20)
            
            // Name and Description
            VStack(alignment: .leading, spacing: 2) {
                Text(capability.originalName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                if let description = capability.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            
            Spacer()
            
            // Prefixed Name (for copying)
            Text(capability.prefixedName)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}

extension CapabilityType {
    var color: Color {
        switch self {
        case .tool: return .blue
        case .resource: return .green
        case .prompt: return .purple
        }
    }
}

struct LogsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack {
            if appState.logs.isEmpty {
                Text("No logs available")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appState.logs) { log in
                    HStack {
                        Text(log.formattedTimestamp)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .leading)
                        
                        Text(log.level.displayName)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(log.levelColor)
                            .frame(width: 50, alignment: .leading)
                        
                        Text(log.source)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)
                        
                        Text(log.message)
                            .font(.caption)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .navigationTitle("Logs")
        .toolbar {
            ToolbarItem {
                Button("Clear") {
                    appState.clearLogs()
                }
                .disabled(appState.logs.isEmpty)
            }
        }
    }
}


#Preview {
    ContentView()
        .environmentObject(AppState())
}