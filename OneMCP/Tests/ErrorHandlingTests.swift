import XCTest
@testable import OneMCP

final class ErrorHandlingTests: XCTestCase {
    var errorHandler: ErrorHandler!
    
    override func setUpWithError() throws {
        errorHandler = ErrorHandler()
    }
    
    override func tearDownWithError() throws {
        errorHandler = nil
    }
    
    func testErrorConversion() async {
        // Test URL error conversion
        let urlError = URLError(.notConnectedToInternet)
        await errorHandler.handle(urlError, context: "Network test")
        
        XCTAssertEqual(errorHandler.recentErrors.count, 1)
        let errorRecord = errorHandler.recentErrors[0]
        
        if case .networkError(let message) = errorRecord.error {
            XCTAssertTrue(message.contains("Network request failed"))
        } else {
            XCTFail("Expected network error")
        }
    }
    
    func testErrorSeverityHandling() async {
        // Test different error severities
        let configError = OneMCPError.configurationError("Invalid port")
        let networkError = OneMCPError.networkError("Connection timeout")
        let criticalError = OneMCPError.systemError("Out of memory")
        
        await errorHandler.handle(configError, context: "Config test")
        await errorHandler.handle(networkError, context: "Network test")
        await errorHandler.handle(criticalError, context: "System test")
        
        XCTAssertEqual(errorHandler.recentErrors.count, 3)
        
        // Check that critical error shows dialog
        XCTAssertTrue(errorHandler.isShowingErrorDialog)
        XCTAssertNotNil(errorHandler.currentError)
    }
    
    func testErrorRecordManagement() async {
        // Test that error records are properly managed
        for i in 0..<60 { // Exceed the max recent errors limit
            let error = OneMCPError.validationError("Test error \(i)")
            await errorHandler.handle(error, context: "Test \(i)")
        }
        
        // Should not exceed max limit
        XCTAssertLessThanOrEqual(errorHandler.recentErrors.count, 50)
    }
    
    func testErrorRecoveryStrategies() {
        let networkRecovery = NetworkErrorRecovery()
        let serviceRecovery = ServiceErrorRecovery()
        let configRecovery = ConfigurationErrorRecovery()
        
        // Test network error recovery
        let networkError = OneMCPError.networkError("Connection failed")
        XCTAssertTrue(networkRecovery.canRecover(from: networkError))
        XCTAssertFalse(serviceRecovery.canRecover(from: networkError))
        XCTAssertFalse(configRecovery.canRecover(from: networkError))
        
        // Test service error recovery
        let serviceError = OneMCPError.serviceError("Service crashed")
        XCTAssertFalse(networkRecovery.canRecover(from: serviceError))
        XCTAssertTrue(serviceRecovery.canRecover(from: serviceError))
        XCTAssertFalse(configRecovery.canRecover(from: serviceError))
        
        // Test configuration error recovery
        let configError = OneMCPError.configurationError("Invalid config")
        XCTAssertFalse(networkRecovery.canRecover(from: configError))
        XCTAssertFalse(serviceRecovery.canRecover(from: configError))
        XCTAssertTrue(configRecovery.canRecover(from: configError))
    }
    
    func testCircuitBreakerFunctionality() async {
        let circuitBreaker = CircuitBreaker(failureThreshold: 3, recoveryTimeout: 1.0)
        
        // Test normal operation
        let successResult = try? await circuitBreaker.execute {
            return "success"
        }
        XCTAssertEqual(successResult, "success")
        XCTAssertEqual(await circuitBreaker.getState(), .closed)
        
        // Test failure accumulation
        for _ in 0..<3 {
            do {
                try await circuitBreaker.execute {
                    throw OneMCPError.networkError("Simulated failure")
                }
            } catch {
                // Expected failures
            }
        }
        
        // Should be open now
        XCTAssertEqual(await circuitBreaker.getState(), .open)
        
        // Should reject calls when open
        do {
            try await circuitBreaker.execute {
                return "should not execute"
            }
            XCTFail("Should have thrown circuit breaker error")
        } catch {
            // Expected
        }
        
        // Wait for recovery timeout
        try? await Task.sleep(for: .seconds(1.1))
        
        // Should transition to half-open
        let halfOpenResult = try? await circuitBreaker.execute {
            return "recovery test"
        }
        XCTAssertEqual(halfOpenResult, "recovery test")
        XCTAssertEqual(await circuitBreaker.getState(), .closed)
    }
    
    func testMCPErrorConversion() async {
        // Test MCP-specific error handling
        let mcpError = MCPError.invalidRequest("Invalid method")
        await errorHandler.handle(mcpError, context: "MCP Protocol test")
        
        XCTAssertEqual(errorHandler.recentErrors.count, 1)
        let errorRecord = errorHandler.recentErrors[0]
        
        if case .mcpProtocolError = errorRecord.error {
            // Correct conversion
        } else {
            XCTFail("Expected MCP protocol error")
        }
    }
    
    func testErrorRecoverySuggestions() {
        let errors: [OneMCPError] = [
            .configurationError("Invalid port"),
            .networkError("Connection timeout"),
            .serviceError("Service unavailable"),
            .validationError("Invalid input"),
            .systemError("Permission denied")
        ]
        
        for error in errors {
            XCTAssertNotNil(error.recoverySuggestion)
            XCTAssertFalse(error.recoverySuggestion!.isEmpty)
        }
    }
    
    func testErrorClearing() async {
        // Add some errors
        for i in 0..<5 {
            let error = OneMCPError.validationError("Test error \(i)")
            await errorHandler.handle(error, context: "Test \(i)")
        }
        
        XCTAssertEqual(errorHandler.recentErrors.count, 5)
        
        // Clear errors
        errorHandler.clearRecentErrors()
        XCTAssertEqual(errorHandler.recentErrors.count, 0)
    }
    
    func testErrorDialogDismissal() async {
        // Trigger critical error to show dialog
        let criticalError = OneMCPError.systemError("Critical system failure")
        await errorHandler.handle(criticalError, context: "Critical test")
        
        XCTAssertTrue(errorHandler.isShowingErrorDialog)
        XCTAssertNotNil(errorHandler.currentError)
        
        // Dismiss dialog
        errorHandler.dismissCurrentError()
        
        XCTAssertFalse(errorHandler.isShowingErrorDialog)
        XCTAssertNil(errorHandler.currentError)
    }
}