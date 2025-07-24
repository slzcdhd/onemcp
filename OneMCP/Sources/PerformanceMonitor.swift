import Foundation
import Logging

// MARK: - Performance Metrics

actor PerformanceMonitor {
    private let logger = Logger(label: "com.onemcp.performance")
    
    // Connection metrics
    private var activeConnections: Int = 0
    private var totalConnections: Int = 0
    private var connectionErrors: Int = 0
    
    // Request metrics
    private var totalRequests: Int = 0
    private var successfulRequests: Int = 0
    private var failedRequests: Int = 0
    private var averageResponseTime: TimeInterval = 0
    private var requestTimes: [TimeInterval] = []
    
    // Resource usage
    private var memoryUsage: UInt64 = 0
    private var lastMemoryCheck: Date = Date()
    
    // MARK: - Connection Tracking
    
    func connectionOpened() {
        activeConnections += 1
        totalConnections += 1
        logger.info("Connection opened. Active: \(activeConnections), Total: \(totalConnections)")
    }
    
    func connectionClosed() {
        activeConnections = max(0, activeConnections - 1)
        logger.info("Connection closed. Active: \(activeConnections)")
    }
    
    func connectionError() {
        connectionErrors += 1
        logger.warning("Connection error recorded. Total errors: \(connectionErrors)")
    }
    
    // MARK: - Request Tracking
    
    func requestStarted() -> Date {
        totalRequests += 1
        return Date()
    }
    
    func requestCompleted(startTime: Date, success: Bool) {
        let responseTime = Date().timeIntervalSince(startTime)
        requestTimes.append(responseTime)
        
        // Keep only last 1000 request times for average calculation
        if requestTimes.count > 1000 {
            requestTimes.removeFirst()
        }
        
        // Update average response time
        averageResponseTime = requestTimes.reduce(0, +) / Double(requestTimes.count)
        
        if success {
            successfulRequests += 1
        } else {
            failedRequests += 1
        }
        
        logger.debug("Request completed in \(responseTime)s. Success: \(success)")
    }
    
    // MARK: - Memory Monitoring
    
    func updateMemoryUsage() {
        let now = Date()
        
        // Only update memory usage every 10 seconds to avoid performance impact
        if now.timeIntervalSince(lastMemoryCheck) > 10.0 {
            memoryUsage = getCurrentMemoryUsage()
            lastMemoryCheck = now
        }
    }
    
    private func getCurrentMemoryUsage() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
    
    // MARK: - Metrics Reporting
    
    func getMetrics() -> PerformanceMetrics {
        updateMemoryUsage()
        
        return PerformanceMetrics(
            activeConnections: activeConnections,
            totalConnections: totalConnections,
            connectionErrors: connectionErrors,
            totalRequests: totalRequests,
            successfulRequests: successfulRequests,
            failedRequests: failedRequests,
            averageResponseTime: averageResponseTime,
            memoryUsageBytes: memoryUsage,
            errorRate: totalRequests > 0 ? Double(failedRequests) / Double(totalRequests) : 0,
            timestamp: Date()
        )
    }
    
    func logMetrics() {
        let metrics = getMetrics()
        logger.info("""
            Performance Metrics:
            - Active Connections: \(metrics.activeConnections)
            - Total Requests: \(metrics.totalRequests)
            - Success Rate: \(String(format: "%.2f", (1.0 - metrics.errorRate) * 100))%
            - Avg Response Time: \(String(format: "%.3f", metrics.averageResponseTime))s
            - Memory Usage: \(formatBytes(metrics.memoryUsageBytes))
            """)
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    // MARK: - Alert Thresholds
    
    func checkAlerts() -> [PerformanceAlert] {
        var alerts: [PerformanceAlert] = []
        let metrics = getMetrics()
        
        // High error rate alert
        if metrics.errorRate > 0.1 { // 10% error rate
            alerts.append(.highErrorRate(metrics.errorRate))
        }
        
        // High response time alert
        if metrics.averageResponseTime > 5.0 { // 5 seconds
            alerts.append(.highResponseTime(metrics.averageResponseTime))
        }
        
        // High memory usage alert (over 500MB)
        if metrics.memoryUsageBytes > 500 * 1024 * 1024 {
            alerts.append(.highMemoryUsage(metrics.memoryUsageBytes))
        }
        
        // Too many active connections
        if metrics.activeConnections > 80 { // 80% of max connections (100)
            alerts.append(.tooManyConnections(metrics.activeConnections))
        }
        
        return alerts
    }
}

// MARK: - Supporting Types

struct PerformanceMetrics: Sendable {
    let activeConnections: Int
    let totalConnections: Int
    let connectionErrors: Int
    let totalRequests: Int
    let successfulRequests: Int
    let failedRequests: Int
    let averageResponseTime: TimeInterval
    let memoryUsageBytes: UInt64
    let errorRate: Double
    let timestamp: Date
}

enum PerformanceAlert: Sendable {
    case highErrorRate(Double)
    case highResponseTime(TimeInterval)
    case highMemoryUsage(UInt64)
    case tooManyConnections(Int)
    
    var message: String {
        switch self {
        case .highErrorRate(let rate):
            return "High error rate: \(String(format: "%.1f", rate * 100))%"
        case .highResponseTime(let time):
            return "High response time: \(String(format: "%.2f", time))s"
        case .highMemoryUsage(let bytes):
            let formatter = ByteCountFormatter()
            return "High memory usage: \(formatter.string(fromByteCount: Int64(bytes)))"
        case .tooManyConnections(let count):
            return "Too many active connections: \(count)"
        }
    }
    
    var severity: AlertSeverity {
        switch self {
        case .highErrorRate(let rate):
            return rate > 0.2 ? .critical : .warning
        case .highResponseTime(let time):
            return time > 10.0 ? .critical : .warning
        case .highMemoryUsage(let bytes):
            return bytes > 1024 * 1024 * 1024 ? .critical : .warning // 1GB
        case .tooManyConnections(let count):
            return count > 95 ? .critical : .warning
        }
    }
}

enum AlertSeverity: Sendable {
    case warning
    case critical
    
    var displayName: String {
        switch self {
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
} 