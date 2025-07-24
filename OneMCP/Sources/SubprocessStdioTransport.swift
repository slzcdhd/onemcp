import Foundation
import MCP
import Logging

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

#if canImport(Darwin)
import Darwin.POSIX
#elseif canImport(Glibc)
import Glibc
#endif

/// A custom stdio transport that spawns and manages a subprocess for MCP communication
public actor SubprocessStdioTransport: Transport {
    private let command: String
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectory: String?
    
    public nonisolated let logger: Logger
    
    private var process: Process?
    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    
    // File descriptors for subprocess communication
    private var stdinDescriptor: FileDescriptor?
    private var stdoutDescriptor: FileDescriptor?
    
    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        logger: Logger? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.logger = logger ?? Logger(label: "mcp.transport.subprocess")
        
        // Create message stream
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }
    
    public func connect() async throws {
        guard !isConnected else { return }
        
        let process = Process()
        
        // Resolve command path if it's not an absolute path
        var executablePath: String
        if command.hasPrefix("/") {
            executablePath = command
        } else {
            // Use which to find the command in PATH
            let whichProcess = Process()
            whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            whichProcess.arguments = [command]
            let whichPipe = Pipe()
            whichProcess.standardOutput = whichPipe
            
            try whichProcess.run()
            whichProcess.waitUntilExit()
            
            if whichProcess.terminationStatus == 0 {
                let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                executablePath = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? command
            } else {
                // Fallback to full path resolution
                let commonPaths = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"]
                var found = false
                executablePath = command
                
                for path in commonPaths {
                    let fullPath = "\(path)/\(command)"
                    if FileManager.default.fileExists(atPath: fullPath) {
                        executablePath = fullPath
                        found = true
                        break
                    }
                }
                
                if !found {
                    throw MCPError.internalError("Command not found: \(command)")
                }
            }
        }
        
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        
        // Set up environment with system PATH
        var processEnvironment = ProcessInfo.processInfo.environment
        
        // Ensure PATH includes common locations for node/npx
        var paths = processEnvironment["PATH"]?.components(separatedBy: ":") ?? []
        let additionalPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin", 
            "/usr/bin",
            "/bin",
            "/usr/local/node/bin",
            "/opt/homebrew/lib/node_modules/.bin"
        ]
        
        for path in additionalPaths {
            if !paths.contains(path) {
                paths.append(path)
            }
        }
        
        processEnvironment["PATH"] = paths.joined(separator: ":")
        
        // Add custom environment variables
        for (key, value) in environment {
            processEnvironment[key] = value
        }
        
        process.environment = processEnvironment
        
        // Set working directory if specified
        if let workingDirectory = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        
        // Set up pipes for communication
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        // Store process reference
        self.process = process
        
        do {
            try process.run()
            
            // Get file descriptors from pipes
            let stdinFD = stdinPipe.fileHandleForWriting.fileDescriptor
            let stdoutFD = stdoutPipe.fileHandleForReading.fileDescriptor
            
            // Create FileDescriptor objects (following official SDK pattern)
            self.stdinDescriptor = FileDescriptor(rawValue: stdinFD)
            self.stdoutDescriptor = FileDescriptor(rawValue: stdoutFD)
            
            // Set stdout to non-blocking mode (following official SDK pattern)
            try setNonBlocking(fileDescriptor: self.stdoutDescriptor!)
            
            isConnected = true
            
            // Start reading loop (following official SDK pattern)
            Task {
                await readLoop()
            }
            
            // Monitor stderr for debugging
            Task {
                await monitorStderr(from: stderrPipe.fileHandleForReading)
            }
            
        } catch {
            logger.error("Failed to start subprocess: \(error)")
            throw error
        }
    }
    
    public func disconnect() async {
        guard isConnected else { return }
        
        // Clean up file descriptors
        stdinDescriptor = nil
        stdoutDescriptor = nil
        
        if let process = process {
            if process.isRunning {
                process.terminate()
                
                // Wait a bit for graceful termination
                try? await Task.sleep(for: .milliseconds(500))
                
                if process.isRunning {
                    // Use SIGKILL instead of process.kill()
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        
        isConnected = false
        messageContinuation.finish()
        process = nil
    }
    
    public func send(_ data: Data) async throws {
        guard isConnected, let stdinFD = stdinDescriptor, let process = process, process.isRunning else {
            throw MCPError.transportError(Errno(rawValue: ENOTCONN))
        }
        
        // Add newline delimiter (following official SDK pattern)
        var messageWithNewline = data
        messageWithNewline.append(UInt8(ascii: "\n"))
        
        // Write message in chunks (following official SDK pattern)
        var remaining = messageWithNewline
        while !remaining.isEmpty {
            do {
                let written = try remaining.withUnsafeBytes { buffer in
                    try stdinFD.write(UnsafeRawBufferPointer(buffer))
                }
                if written > 0 {
                    remaining = remaining.dropFirst(written)
                }
            } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                try await Task.sleep(for: .milliseconds(10))
                continue
            } catch {
                logger.error("Failed to send data to subprocess: \(error)")
                throw MCPError.transportError(error)
            }
        }
    }
    
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }
    
    /// Configures a file descriptor for non-blocking I/O (following official SDK pattern)
    private func setNonBlocking(fileDescriptor: FileDescriptor) throws {
        #if canImport(Darwin) || canImport(Glibc)
            // Get current flags
            let flags = fcntl(fileDescriptor.rawValue, F_GETFL)
            guard flags >= 0 else {
                throw MCPError.transportError(Errno(rawValue: CInt(errno)))
            }

            // Set non-blocking flag
            let result = fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK)
            guard result >= 0 else {
                throw MCPError.transportError(Errno(rawValue: CInt(errno)))
            }
        #else
            // For platforms where non-blocking operations aren't supported
            throw MCPError.internalError(
                "Setting non-blocking mode not supported on this platform")
        #endif
    }
    
    /// Continuous loop that reads and processes incoming messages (following official SDK pattern)
    private func readLoop() async {
        guard let stdoutFD = stdoutDescriptor else { return }
        
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var pendingData = Data()

        while isConnected && !Task.isCancelled {
            do {
                let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
                    try stdoutFD.read(into: UnsafeMutableRawBufferPointer(pointer))
                }

                if bytesRead == 0 {
                    break
                }

                pendingData.append(Data(buffer[..<bytesRead]))

                // Process complete messages (following official SDK pattern)
                while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                    let messageData = pendingData[..<newlineIndex]
                    pendingData = pendingData[(newlineIndex + 1)...]

                    if !messageData.isEmpty {
                        messageContinuation.yield(Data(messageData))
                    }
                }
            } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                try? await Task.sleep(for: .milliseconds(10))
                continue
            } catch {
                if !Task.isCancelled {
                    logger.error("Read error occurred", metadata: ["error": "\(error)"])
                }
                break
            }
        }

        messageContinuation.finish()
    }
    
    private func monitorStderr(from fileHandle: FileHandle) async {
        do {
            for try await line in fileHandle.bytes.lines {
                logger.warning("Subprocess stderr: \(line)")
            }
        } catch {
            logger.error("Error reading from subprocess stderr: \(error)")
        }
    }
}

// MARK: - SubprocessStdioTransport Implementation Complete
// Following MCP official Swift SDK patterns for transport implementation 