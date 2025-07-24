import SwiftUI

// MARK: - Advanced Settings

struct AdvancedSettingsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        TabView {
            MCPConfigurationView()
                .environmentObject(appState)
                .tabItem {
                    Label("MCP Config", systemImage: "doc.text.fill")
                }
            
            LoggingConfigurationView()
                .environmentObject(appState)
                .tabItem {
                    Label("Logging", systemImage: "text.alignleft")
                }
            
            DiagnosticsView()
                .environmentObject(appState)
                .tabItem {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            
            SystemConfigurationView()
                .environmentObject(appState)
                .tabItem {
                    Label("System", systemImage: "gear.circle")
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - MCP Configuration View

struct MCPConfigurationView: View {
    @EnvironmentObject var appState: AppState
    @State private var configContent = ""
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var hasChanges = false
    @State private var showingSuccess = false
    @State private var successMessage = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.fill")
                            .font(.title3)
                            .foregroundColor(.blue)
                        
                        Text("MCP Configuration")
                            .font(.headline)
                            .fontWeight(.semibold)
                    }
                    
                    Spacer()
                    
                    // Status
                    HStack(spacing: 6) {
                        Circle()
                            .fill(hasChanges ? Color.orange : Color.green)
                            .frame(width: 6, height: 6)
                        
                        Text(hasChanges ? "Modified" : "Saved")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Action buttons
                HStack(spacing: 8) {
                    Button("Format") { formatJSON() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    
                    Button("Validate") { validateJSON() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    
                    Button("Reset") { confirmReset() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    
                    Spacer()
                    
                    Button("Export") { exportConfiguration() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    
                    Button("Import") { importConfiguration() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    
                    Button("Save") { saveConfiguration() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!hasChanges)
                }
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // JSON Editor
            VStack(spacing: 0) {
                // Toolbar
                HStack {
                    Text("mcp_servers.json")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if hasChanges {
                        Text("Unsaved changes")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                
                // Editor
                ScrollView {
                    TextEditor(text: $configContent)
                        .font(.system(.callout, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .background(Color(NSColor.textBackgroundColor))
                        .onChange(of: configContent) { _ in
                            hasChanges = true
                        }
                        .padding(12)
                }
                .background(Color(NSColor.textBackgroundColor))
            }
        }
        .onAppear { loadConfiguration() }
        .alert("Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .alert("Success", isPresented: $showingSuccess) {
            Button("OK") { }
        } message: {
            Text(successMessage)
        }
    }
    
    private func loadConfiguration() {
        do {
            let data = try Data(contentsOf: appState.configManager.mcpServersFileURL)
            configContent = String(data: data, encoding: .utf8) ?? ""
            hasChanges = false
        } catch {
            configContent = """
{
  "mcpServers": {
    
  }
}
"""
            errorMessage = "Could not load existing configuration: \(error.localizedDescription)"
            showingError = true
        }
    }
    
    private func saveConfiguration() {
        do {
            guard let data = configContent.data(using: .utf8) else {
                throw ConfigurationError.invalidJSON
            }
            
            let _ = try JSONSerialization.jsonObject(with: data)
            try data.write(to: appState.configManager.mcpServersFileURL)
            
            appState.config.upstreamServers = try appState.configManager.loadServersFromMCPFile()
            appState.saveConfiguration()
            
            hasChanges = false
            successMessage = "Configuration saved successfully"
            showingSuccess = true
            
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            showingError = true
        }
    }
    
    private func formatJSON() {
        do {
            guard let data = configContent.data(using: .utf8) else { return }
            let jsonObject = try JSONSerialization.jsonObject(with: data)
            let formattedData = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            configContent = String(data: formattedData, encoding: .utf8) ?? configContent
            hasChanges = true
        } catch {
            errorMessage = "Invalid JSON format"
            showingError = true
        }
    }
    
    private func validateJSON() {
        do {
            guard let data = configContent.data(using: .utf8) else {
                throw ConfigurationError.invalidJSON
            }
            let _ = try JSONSerialization.jsonObject(with: data)
            
            successMessage = "JSON is valid"
            showingSuccess = true
            
        } catch {
            errorMessage = "Invalid JSON: \(error.localizedDescription)"
            showingError = true
        }
    }
    
    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset Configuration"
        alert.informativeText = "Reload from file, discarding changes?"
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        
        if alert.runModal() == .alertFirstButtonReturn {
            loadConfiguration()
        }
    }
    
    private func exportConfiguration() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "mcp_servers.json"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                try configContent.data(using: .utf8)?.write(to: url)
                successMessage = "Exported successfully"
                showingSuccess = true
            } catch {
                errorMessage = "Export failed: \(error.localizedDescription)"
                showingError = true
            }
        }
    }
    
    private func importConfiguration() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        
        if openPanel.runModal() == .OK, let url = openPanel.urls.first {
            do {
                let data = try Data(contentsOf: url)
                configContent = String(data: data, encoding: .utf8) ?? ""
                hasChanges = true
                successMessage = "Imported successfully"
                showingSuccess = true
            } catch {
                errorMessage = "Import failed: \(error.localizedDescription)"
                showingError = true
            }
        }
    }
}

// MARK: - Logging Configuration View

struct LoggingConfigurationView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "text.alignleft")
                    .font(.title3)
                    .foregroundColor(.green)
                
                Text("Logging")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Content
            ScrollView {
                VStack(spacing: 20) {
                    // Log Level
                    VStack(spacing: 12) {
                        HStack {
                            Text("Log Level")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                        }
                        
                        HStack {
                            Text("Level:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Picker("", selection: $appState.config.logging.level) {
                                ForEach(LogLevel.allCases, id: \.rawValue) { level in
                                    Text(level.displayName).tag(level)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 100)
                            
                            Spacer()
                        }
                    }
                    .padding(16)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
                    
                    // File Logging
                    VStack(spacing: 12) {
                        HStack {
                            Text("File Logging")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                        }
                        
                        VStack(spacing: 8) {
                            HStack {
                                Text("Enable")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                                
                                Toggle("", isOn: $appState.config.logging.enableFileLogging)
                                    .toggleStyle(.switch)
                                    .scaleEffect(0.8)
                            }
                            
                            if appState.config.logging.enableFileLogging {
                                HStack {
                                    Text("Max size")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    TextField("", value: $appState.config.logging.maxLogSize, formatter: NumberFormatter())
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                    
                                    Text("bytes")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    Spacer()
                                }
                            }
                        }
                    }
                    .padding(16)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
                }
                .padding(20)
            }
        }
        .onChange(of: appState.config.logging) { _ in
            appState.saveConfiguration()
        }
    }
}

// MARK: - Diagnostics View

struct DiagnosticsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "stethoscope")
                    .font(.title3)
                    .foregroundColor(.orange)
                
                Text("Diagnostics")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Content
            ScrollView {
                VStack(spacing: 20) {
                    // Actions
                    VStack(spacing: 12) {
                        HStack {
                            Text("Actions")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                        }
                        
                        HStack(spacing: 12) {
                            Button("Open Logs") {
                                openLogDirectory()
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            
                            Button("Clear Logs") {
                                clearLogs()
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(16)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
                    
                    // System Info
                    VStack(spacing: 12) {
                        HStack {
                            Text("System")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                        }
                        
                        VStack(spacing: 6) {
                            CompactInfoRow(label: "App", value: "1.0.0")
                            CompactInfoRow(label: "MCP SDK", value: "0.9.0+")
                            CompactInfoRow(label: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                        }
                    }
                    .padding(16)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
                    
                    // Performance
                    VStack(spacing: 12) {
                        HStack {
                            Text("Performance")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                        }
                        
                        VStack(spacing: 6) {
                            CompactInfoRow(label: "Servers", value: "\(appState.serverStatuses.filter { $0.status == .connected }.count)")
                            CompactInfoRow(label: "Capabilities", value: "\(appState.serverStatuses.reduce(into: 0) { $0 += $1.capabilities.total })")
                            CompactInfoRow(label: "Memory", value: formatMemoryUsage())
                        }
                    }
                    .padding(16)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
                }
                .padding(20)
            }
        }
    }
    
    private func openLogDirectory() {
        let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs")
            .appendingPathComponent("OneMCP")
        
        if let url = logURL {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func clearLogs() {
        let alert = NSAlert()
        alert.messageText = "Clear All Logs"
        alert.informativeText = "Delete all log files?"
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        
        if alert.runModal() == .alertFirstButtonReturn {
            appState.clearLogs()
        }
    }
    
    private func formatMemoryUsage() -> String {
        let task = mach_task_self_
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(task, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let memoryMB = Double(info.resident_size) / 1024.0 / 1024.0
            return String(format: "%.1f MB", memoryMB)
        }
        return "Unknown"
    }
}

// MARK: - System Configuration View

struct SystemConfigurationView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "gear.circle")
                    .font(.title3)
                    .foregroundColor(.purple)
                
                Text("System")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Content
            ScrollView {
                VStack(spacing: 20) {
                    // Config Management
                    VStack(spacing: 12) {
                        HStack {
                            Text("Configuration")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                        }
                        
                        VStack(spacing: 8) {
                            Button("Export All") {
                                exportConfiguration()
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            
                            Button("Import") {
                                importConfiguration()
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            
                            Button("Reset to Defaults") {
                                resetToDefaults()
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(16)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
                    
                    // File Locations
                    VStack(spacing: 12) {
                        HStack {
                            Text("Files")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                        }
                        
                        VStack(spacing: 8) {
                            FileLocationRow(
                                label: "App Config",
                                path: appState.configManager.configFileURL.lastPathComponent,
                                action: {
                                    NSWorkspace.shared.open(appState.configManager.configFileURL.deletingLastPathComponent())
                                }
                            )
                            
                            FileLocationRow(
                                label: "MCP Servers",
                                path: appState.configManager.mcpServersFileURL.lastPathComponent,
                                action: {
                                    NSWorkspace.shared.open(appState.configManager.mcpServersFileURL.deletingLastPathComponent())
                                }
                            )
                        }
                    }
                    .padding(16)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
                }
                .padding(20)
            }
        }
    }
    
    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "onemcp-config.json"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try appState.configManager.exportConfig(to: url)
                showSuccess("Exported successfully")
            } catch {
                showError("Export failed", error.localizedDescription)
            }
        }
    }
    
    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.urls.first {
            do {
                try appState.configManager.importConfig(from: url)
                showSuccess("Imported successfully")
            } catch {
                showError("Import failed", error.localizedDescription)
            }
        }
    }
    
    private func resetToDefaults() {
        let alert = NSAlert()
        alert.messageText = "Reset Configuration"
        alert.informativeText = "Reset all settings to defaults?"
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        
        if alert.runModal() == .alertFirstButtonReturn {
            appState.config = AppConfig()
            appState.saveConfiguration()
            showSuccess("Reset to defaults")
        }
    }
    
    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .warning
        alert.runModal()
    }
    
    private func showSuccess(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Success"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .informational
        alert.runModal()
    }
}

// MARK: - Helper Views

struct CompactInfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
            
            Spacer()
        }
    }
}

struct FileLocationRow: View {
    let label: String
    let path: String
    let action: () -> Void
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            
            Text(path)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer()
            
            Button("Open") {
                action()
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .font(.caption2)
        }
    }
}


