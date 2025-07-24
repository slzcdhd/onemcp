# OneMCP - MCP Server Aggregator

OneMCP is a native macOS application that aggregates multiple Model Context Protocol (MCP) servers into a unified interface. It provides a seamless way to manage and interact with multiple MCP servers through a single endpoint, complete with a modern SwiftUI interface and system tray integration.

## 🚀 Features

### Core Functionality
- **MCP Server Aggregation**: Connect and manage multiple upstream MCP servers through a unified interface
- **Multi-Protocol Support**: Supports Standard I/O, Server-Sent Events (SSE), and HTTP transport protocols
- **Unified HTTP Endpoint**: Exposes all connected servers through a single HTTP interface for downstream clients
- **Real-time Status Monitoring**: Live monitoring of server connections, capabilities, and performance metrics

### User Interface
- **Native macOS App**: Built with SwiftUI for a modern, native macOS experience
- **System Tray Integration**: Convenient menu bar access with status indicators
- **Multi-Tab Interface**: Organized views for Overview, Servers, Capabilities, and Logs
- **Settings Management**: Comprehensive configuration through a dedicated settings panel

### Advanced Features
- **Capability Prefixing**: Automatically prefixes capabilities from different servers to avoid naming conflicts
- **Performance Monitoring**: Built-in performance tracking with alerts and metrics
- **Retry Logic**: Configurable retry mechanisms for unreliable server connections
- **CORS Support**: Configurable CORS settings for web client integration
- **Notifications**: System notifications for server status changes and errors

## 📋 Requirements

- macOS 13.0 or later
- Swift 6.0+
- Xcode 15.0+ (for development)

## 🛠 Installation

### Pre-built Binary
Download the latest release from the [Releases](https://github.com/your-repo/onemcp/releases) page.

### Building from Source

1. **Clone the repository**:
   ```bash
   git clone https://github.com/your-repo/onemcp.git
   cd onemcp
   ```

2. **Build the application**:
   ```bash
   make app
   ```

3. **Install to Applications folder**:
   ```bash
   cp -r OneMCP.app /Applications/
   ```

### Development Build

For development, you can run the app directly:
```bash
make run
```

## ⚙️ Configuration

OneMCP stores its configuration in `~/Library/Application Support/OneMCP/config.json`. The application provides a graphical interface for configuration, but you can also edit the JSON directly.

### Server Configuration

OneMCP supports three types of upstream servers:

#### 1. Standard I/O Servers
```json
{
  "id": "uuid-here",
  "name": "My StdIO Server",
  "type": "stdio",
  "enabled": true,
  "config": {
    "stdio": {
      "command": "/path/to/server",
      "arguments": ["--arg1", "value1"],
      "environment": {
        "KEY": "value"
      },
      "workingDirectory": "/path/to/working/dir"
    }
  }
}
```

#### 2. Server-Sent Events (SSE) Servers
```json
{
  "id": "uuid-here",
  "name": "My SSE Server",
  "type": "sse",
  "enabled": true,
  "config": {
    "sse": {
      "url": "http://localhost:3001/sse",
      "headers": {
        "Authorization": "Bearer token"
      }
    }
  }
}
```

#### 3. HTTP Servers
```json
{
  "id": "uuid-here",
  "name": "My HTTP Server",
  "type": "streamable-http",
  "enabled": true,
  "config": {
    "streamableHttp": {
      "url": "http://localhost:3002",
      "headers": {
        "Authorization": "Bearer token"
      }
    }
  }
}
```

### Application Settings

```json
{
  "server": {
    "port": 3000,
    "host": "localhost",
    "enableCors": true
  },
  "ui": {
    "startMinimized": false,
    "showInDock": true,
    "enableNotifications": true,
    "theme": "system"
  },
  "logging": {
    "level": "info",
    "enableFileLogging": true,
    "maxLogSize": 10000000
  }
}
```

## 🔧 Usage

### Starting the Application

1. Launch OneMCP from the Applications folder or system tray
2. The application will start the aggregation server on the configured port (default: 3000)
3. Configure your upstream MCP servers through the Settings panel
4. Monitor server status through the Overview tab

### Connecting Downstream Clients

Once OneMCP is running, downstream clients can connect to the aggregated endpoint:

```
http://localhost:3000
```

All capabilities from connected upstream servers will be available through this single endpoint, with automatic prefixing to avoid naming conflicts.

### Menu Bar Features

- **Server Status**: Green/red indicator showing overall server status
- **Quick Actions**: Access to main window and settings
- **Notifications**: Real-time alerts for server status changes

## 🏗 Architecture

### Core Components

- **MCPAggregationService**: Main service orchestrating server connections and capability aggregation
- **UpstreamManager**: Manages connections to upstream MCP servers
- **HTTPServerTransport**: HTTP server implementation for downstream clients
- **AppState**: Central state management using SwiftUI's ObservableObject
- **ConfigManager**: Configuration persistence and management

### Transport Layer

OneMCP supports multiple transport protocols:

- **SubprocessStdioTransport**: For command-line MCP servers
- **LegacySSETransport**: For Server-Sent Events connections
- **HTTPServerTransport**: For HTTP-based MCP servers

### Capability Aggregation

- Capabilities from different servers are prefixed with server names to avoid conflicts
- Example: `server1_tool_name`, `server2_tool_name`
- Original capability names are preserved in metadata for reference

## 🧪 Testing

Run the test suite:
```bash
make test
```

## 📊 Performance Monitoring

OneMCP includes built-in performance monitoring:

- **Connection Metrics**: Active connections, total connections, error rates
- **Request Metrics**: Response times, success/failure rates
- **Resource Usage**: Memory usage tracking
- **Alerts**: Configurable performance alerts

## 🛡 Security

- **Localhost Binding**: Default configuration binds to localhost for security
- **CORS Configuration**: Configurable CORS settings for web client integration
- **Process Isolation**: Upstream servers run in separate processes
- **Error Isolation**: Failures in one upstream server don't affect others

## 🐛 Troubleshooting

### Common Issues

1. **Port Already in Use**: OneMCP will automatically find an alternative port and notify you
2. **Server Connection Failures**: Check server configuration and logs in the Logs tab
3. **Performance Issues**: Monitor the Performance tab for bottlenecks

### Logs

View detailed logs through:
- The Logs tab in the main interface
- Console.app (search for "OneMCP")
- Log files in `~/Library/Application Support/OneMCP/`

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing-feature`
3. Commit your changes: `git commit -m 'Add amazing feature'`
4. Push to the branch: `git push origin feature/amazing-feature`
5. Open a Pull Request

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Built using the [Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk)
- Uses [Swift Service Lifecycle](https://github.com/swift-server/swift-service-lifecycle) for service management
- Logging provided by [Swift Log](https://github.com/apple/swift-log)

## 📞 Support

For support, please:
- Check the [Issues](https://github.com/your-repo/onemcp/issues) page
- Create a new issue with detailed information
- Include relevant logs and configuration details

---

**OneMCP** - Simplifying MCP server management on macOS
