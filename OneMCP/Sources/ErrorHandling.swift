import Foundation
import MCP
import Logging
import AppKit

// MARK: - Error Types

enum OneMCPError: LocalizedError, Sendable {
    case configurationError(String)
    case networkError(String)
    case serviceError(String)
    case mcpProtocolError(String)
    case systemError(String)
    case validationError(String)
    
    var errorDescription: String? {
        switch self {
        case .configurationError(let message):
            return "Configuration Error: \(message)"
        case .networkError(let message):
            return "Network Error: \(message)"
        case .serviceError(let message):
            return "Service Error: \(message)"
        case .mcpProtocolError(let message):
            return "MCP Protocol Error: \(message)"
        case .systemError(let message):
            return "System Error: \(message)"
        case .validationError(let message):
            return "Validation Error: \(message)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .configurationError:
            return "Check your configuration settings and ensure all required fields are properly set."
        case .networkError:
            return "Check your network connection and ensure the target servers are reachable."
        case .serviceError:
            return "Try restarting the service or check the logs for more details."
        case .mcpProtocolError:
            return "Ensure the upstream servers support the MCP protocol specification."
        case .systemError:
            return "Check system resources and permissions."
        case .validationError:
            return "Review the input data and correct any invalid values."
        }
    }
    
    var severity: ErrorSeverity {
        switch self {
        case .configurationError, .validationError:
            return .warning
        case .networkError:
            return .moderate
        case .serviceError, .mcpProtocolError, .systemError:
            return .critical
        }
    }
}

enum ErrorSeverity: String, CaseIterable {
    case info = "info"
    case warning = "warning"
    case moderate = "moderate"
    case critical = "critical"
    
    var logLevel: Logger.Level {
        switch self {
        case .info: return .info
        case .warning: return .warning
        case .moderate: return .notice
        case .critical: return .error
        }
    }
}

// MARK: - Error Handler

@MainActor
class ErrorHandler: ObservableObject {
    @Published var recentErrors: [ErrorRecord] = []
    @Published var isShowingErrorDialog = false
    @Published var currentError: ErrorRecord?
    
    private let logger = Logger(label: "com.onemcp.errorhandler")
    private let maxRecentErrors = 50
    
    func handle(_ error: Swift.Error, context: String = "") async {
        let oneMCPError = convertToOneMCPError(error)
        let errorRecord = ErrorRecord(
            error: oneMCPError,
            context: context,
            timestamp: Date()
        )
        
        // Add to recent errors
        recentErrors.append(errorRecord)
        if recentErrors.count > maxRecentErrors {
            recentErrors.removeFirst(recentErrors.count - maxRecentErrors)
        }
        
        // Log the error
        logger.log(level: oneMCPError.severity.logLevel, "\(oneMCPError.localizedDescription)")
        
        // Show error dialog for critical errors
        if oneMCPError.severity == .critical {
            currentError = errorRecord
            isShowingErrorDialog = true
        }
        
        // Send notification for important errors
        await sendErrorNotification(errorRecord)
    }
    
    private func convertToOneMCPError(_ error: Swift.Error) -> OneMCPError {
        if let oneMCPError = error as? OneMCPError {
            return oneMCPError
        }
        
        if let mcpError = error as? MCPError {
            return .mcpProtocolError(mcpError.localizedDescription)
        }
        
        // Convert common error types
        if let urlError = error as? URLError {
            return .networkError("Network request failed: \(urlError.localizedDescription)")
        }
        
        if let decodingError = error as? DecodingError {
            return .configurationError("Configuration parsing failed: \(decodingError.localizedDescription)")
        }
        
        // Default case
        return .systemError(error.localizedDescription)
    }
    
    private func sendErrorNotification(_ record: ErrorRecord) async {
        // Only send notifications for moderate and critical errors
        guard record.error.severity == .moderate || record.error.severity == .critical else {
            return
        }
        
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            Task { @MainActor in
                await appDelegate.menuBarManager?.sendNotification(
                    title: "OneMCP Error",
                    body: record.error.localizedDescription
                )
            }
        }
    }
    
    func clearRecentErrors() {
        recentErrors.removeAll()
    }
    
    func dismissCurrentError() {
        isShowingErrorDialog = false
        currentError = nil
    }
}

// MARK: - Error Record

struct ErrorRecord: Identifiable, Sendable {
    let id = UUID()
    let error: OneMCPError
    let context: String
    let timestamp: Date
    var isRecovered = false
    
    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: timestamp)
    }
}

// MARK: - Circuit Breaker

actor CircuitBreaker {
    enum State {
        case closed
        case open
        case halfOpen
    }
    
    private let failureThreshold: Int
    private let recoveryTimeout: TimeInterval
    private let logger = Logger(label: "com.onemcp.circuitbreaker")
    
    private var state: State = .closed
    private var failureCount = 0
    private var lastFailureTime: Date?
    
    init(failureThreshold: Int = 5, recoveryTimeout: TimeInterval = 30.0) {
        self.failureThreshold = failureThreshold
        self.recoveryTimeout = recoveryTimeout
    }
    
    func execute<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        switch state {
        case .open:
            // Check if we should transition to half-open
            if let lastFailure = lastFailureTime,
               Date().timeIntervalSince(lastFailure) > recoveryTimeout {
                state = .halfOpen
            } else {
                throw OneMCPError.serviceError("Circuit breaker is open")
            }
            
        case .halfOpen:
            // Allow one request through
            break
            
        case .closed:
            // Normal operation
            break
        }
        
        do {
            let result = try await operation()
            recordSuccess()
            return result
        } catch {
            recordFailure()
            throw error
        }
    }
    
    private func recordSuccess() {
        failureCount = 0
        lastFailureTime = nil
        
        if state == .halfOpen {
            state = .closed
        }
    }
    
    private func recordFailure() {
        failureCount += 1
        lastFailureTime = Date()
        
        if failureCount >= failureThreshold && state == .closed {
            logger.warning("Circuit breaker opening after \(failureCount) failures")
            state = .open
        } else if state == .halfOpen {
            state = .open
        }
    }
    
    func getState() -> State {
        return state
    }
    
    func getMetrics() -> (failureCount: Int, state: State, lastFailureTime: Date?) {
        return (failureCount, state, lastFailureTime)
    }
    
    func reset() {
        state = .closed
        failureCount = 0
        lastFailureTime = nil
    }
}