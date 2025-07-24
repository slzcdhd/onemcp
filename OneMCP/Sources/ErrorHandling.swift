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

// MARK: - Error Recovery Strategies

protocol ErrorRecoveryStrategy {
    func canRecover(from error: OneMCPError) -> Bool
    func recover(from error: OneMCPError) async throws
}

// MARK: - Network Error Recovery

class NetworkErrorRecovery: ErrorRecoveryStrategy {
    private let logger = Logger(label: "com.onemcp.recovery.network")
    private let maxRetries: Int
    private let baseDelay: TimeInterval
    
    init(maxRetries: Int = 3, baseDelay: TimeInterval = 1.0) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
    }
    
    func canRecover(from error: OneMCPError) -> Bool {
        switch error {
        case .networkError, .mcpProtocolError:
            return true
        default:
            return false
        }
    }
    
    func recover(from error: OneMCPError) async throws {
        logger.info("Attempting network error recovery for: \(error.localizedDescription)")
        
        for attempt in 1...maxRetries {
            let delay = baseDelay * Double(attempt)
            logger.info("Recovery attempt \(attempt)/\(maxRetries), waiting \(delay)s")
            
            try await Task.sleep(for: .seconds(delay))
            
            // Recovery logic would be implemented by the specific service
            // This is a base implementation
            break
        }
    }
}

// MARK: - Service Error Recovery

class ServiceErrorRecovery: ErrorRecoveryStrategy {
    private let logger = Logger(label: "com.onemcp.recovery.service")
    
    func canRecover(from error: OneMCPError) -> Bool {
        switch error {
        case .serviceError:
            return true
        default:
            return false
        }
    }
    
    func recover(from error: OneMCPError) async throws {
        logger.info("Attempting service error recovery for: \(error.localizedDescription)")
        
        // Implement service restart logic
        // This would be coordinated with the service lifecycle manager
    }
}

// MARK: - Configuration Error Recovery

class ConfigurationErrorRecovery: ErrorRecoveryStrategy {
    private let logger = Logger(label: "com.onemcp.recovery.config")
    
    func canRecover(from error: OneMCPError) -> Bool {
        switch error {
        case .configurationError, .validationError:
            return true
        default:
            return false
        }
    }
    
    func recover(from error: OneMCPError) async throws {
        logger.info("Attempting configuration error recovery for: \(error.localizedDescription)")
        
        // Could implement fallback to default configuration
        // or attempt to fix common configuration issues
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
    private let recoveryStrategies: [ErrorRecoveryStrategy]
    
    init() {
        self.recoveryStrategies = [
            NetworkErrorRecovery(),
            ServiceErrorRecovery(),
            ConfigurationErrorRecovery()
        ]
    }
    
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
        
        // Attempt recovery
        await attemptRecovery(for: oneMCPError, record: errorRecord)
        
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
    
    private func attemptRecovery(for error: OneMCPError, record: ErrorRecord) async {
        for strategy in recoveryStrategies {
            if strategy.canRecover(from: error) {
                do {
                    logger.info("Attempting recovery using \(type(of: strategy))")
                    
                    // Create a task to isolate the recovery call
                    try await Task {
                        try await strategy.recover(from: error)
                    }.value
                    
                    // Mark as recovered
                    if let index = recentErrors.firstIndex(where: { $0.id == record.id }) {
                        recentErrors[index].isRecovered = true
                    }
                    
                    logger.info("Successfully recovered from error")
                    return
                } catch {
                    logger.error("Recovery attempt failed: \(error.localizedDescription)")
                }
            }
        }
        
        logger.warning("No recovery strategy available for error: \(error.localizedDescription)")
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
                logger.info("Circuit breaker transitioning to half-open")
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
            logger.info("Circuit breaker transitioning to closed after successful operation")
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
            logger.warning("Circuit breaker reopening after failed recovery attempt")
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
        logger.info("Circuit breaker reset")
        state = .closed
        failureCount = 0
        lastFailureTime = nil
    }
}