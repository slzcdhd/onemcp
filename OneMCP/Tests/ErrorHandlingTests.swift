import XCTest
@testable import OneMCP

final class ErrorHandlingTests: XCTestCase {
    var errorHandler: ErrorHandler!
    
    override func setUpWithError() throws {
        // Tests need to run on MainActor since ErrorHandler is @MainActor
    }
    
    @MainActor
    func testBasicErrorHandling() async {
        errorHandler = ErrorHandler()
        
        // Test different error types
        let urlError = URLError(.notConnectedToInternet)
        await errorHandler.handle(urlError, context: "Network test")
        
        XCTAssertEqual(errorHandler.recentErrors.count, 1)
        let errorRecord = errorHandler.recentErrors[0]
        
        if case .networkError(let message) = errorRecord.error {
            XCTAssertTrue(message.contains("Network request failed"))
        } else {
            XCTFail("Expected network error")
        }
        
        // Test configuration error
        let configError = OneMCPError.configurationError("Invalid configuration")
        await errorHandler.handle(configError, context: "Config test")
        
        XCTAssertEqual(errorHandler.recentErrors.count, 2)
        
        // Test critical error shows dialog
        let criticalError = OneMCPError.systemError("Critical system failure")
        await errorHandler.handle(criticalError, context: "System test")
        
        XCTAssertEqual(errorHandler.recentErrors.count, 3)
        
        // Check that critical error shows dialog
        XCTAssertTrue(errorHandler.isShowingErrorDialog)
        XCTAssertNotNil(errorHandler.currentError)
    }
    
    @MainActor
    func testErrorHistoryLimit() async {
        errorHandler = ErrorHandler()
        
        // Add more than 50 errors
        for i in 0..<60 {
            let error = OneMCPError.validationError("Test error \(i)")
            await errorHandler.handle(error)
        }
        
        // Should not exceed max limit
        XCTAssertLessThanOrEqual(errorHandler.recentErrors.count, 50)
    }
    
    func testErrorSeverity() {
        // Test severity levels
        let configError = OneMCPError.configurationError("Config issue")
        XCTAssertEqual(configError.severity, .warning)
        
        let networkError = OneMCPError.networkError("Network issue")
        XCTAssertEqual(networkError.severity, .moderate)
        
        let systemError = OneMCPError.systemError("System issue")
        XCTAssertEqual(systemError.severity, .critical)
    }
    
    func testCircuitBreaker() async {
        let circuitBreaker = CircuitBreaker()
        
        // Test successful operation
        let successResult = try? await circuitBreaker.execute {
            return "success"
        }
        XCTAssertEqual(successResult, "success")
        
        let state1 = await circuitBreaker.getState()
        XCTAssertEqual(state1, .closed)
        
        // Test failure accumulation
        for _ in 0..<5 {
            do {
                try await circuitBreaker.execute {
                    throw OneMCPError.networkError("Test failure")
                }
            } catch {
                // Expected
            }
        }
        
        // Should be open now
        let state2 = await circuitBreaker.getState()
        XCTAssertEqual(state2, .open)
        
        // Should reject calls when open
        do {
            _ = try await circuitBreaker.execute {
                return "should not execute"
            }
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }
        
        // Test half-open after timeout
        try? await Task.sleep(for: .seconds(31))
        
        // Should transition to half-open and allow one request
        let halfOpenResult = try? await circuitBreaker.execute {
            return "recovery test"
        }
        XCTAssertEqual(halfOpenResult, "recovery test")
        
        let state3 = await circuitBreaker.getState()
        XCTAssertEqual(state3, .closed)
    }
    
    func testErrorRecord() {
        let error = OneMCPError.networkError("Test error")
        let record = ErrorRecord(error: error, context: "Test context", timestamp: Date())
        
        XCTAssertEqual(record.context, "Test context")
        XCTAssertFalse(record.isRecovered)
        XCTAssertNotNil(record.formattedTimestamp)
    }
    
    @MainActor
    func testErrorConversion() async {
        errorHandler = ErrorHandler()
        
        // Test various error conversions
        let errors: [Swift.Error] = [
            URLError(.notConnectedToInternet),
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Test")),
            NSError(domain: "TestDomain", code: 123, userInfo: nil)
        ]
        
        for error in errors {
            await errorHandler.handle(error, context: "Conversion test")
        }
        
        XCTAssertEqual(errorHandler.recentErrors.count, 3)
        
        // Clear errors
        errorHandler.clearRecentErrors()
        XCTAssertEqual(errorHandler.recentErrors.count, 0)
    }
    
    @MainActor
    func testErrorDialogDismissal() async {
        errorHandler = ErrorHandler()
        
        // Create critical error to show dialog
        let criticalError = OneMCPError.systemError("Critical test")
        await errorHandler.handle(criticalError, context: "Critical test")
        
        XCTAssertTrue(errorHandler.isShowingErrorDialog)
        XCTAssertNotNil(errorHandler.currentError)
        
        // Dismiss dialog
        errorHandler.dismissCurrentError()
        
        XCTAssertFalse(errorHandler.isShowingErrorDialog)
        XCTAssertNil(errorHandler.currentError)
    }
}