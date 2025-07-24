import XCTest
@testable import OneMCP
import MCP

final class MCPTypesTests: XCTestCase {
    
    func testStringToMCPValue() {
        let testString = "Hello, World!"
        let mcpValue = convertAnyToMCPValue(testString)
        
        if case .string(let value) = mcpValue {
            XCTAssertEqual(value, testString)
        } else {
            XCTFail("Expected string MCP value")
        }
    }
    
    func testIntToMCPValue() {
        let testInt = 42
        let mcpValue = convertAnyToMCPValue(testInt)
        
        if case .int(let value) = mcpValue {
            XCTAssertEqual(value, testInt)
        } else {
            XCTFail("Expected int MCP value")
        }
    }
    
    func testDoubleToMCPValue() {
        let testDouble = 3.14159
        let mcpValue = convertAnyToMCPValue(testDouble)
        
        if case .double(let value) = mcpValue {
            XCTAssertEqual(value, testDouble, accuracy: 0.00001)
        } else {
            XCTFail("Expected double MCP value")
        }
    }
    
    func testBoolToMCPValue() {
        let testBool = true
        let mcpValue = convertAnyToMCPValue(testBool)
        
        if case .bool(let value) = mcpValue {
            XCTAssertEqual(value, testBool)
        } else {
            XCTFail("Expected bool MCP value")
        }
    }
    
    func testArrayToMCPValue() {
        let testArray: [Any] = ["hello", 42, true, 3.14]
        let mcpValue = convertAnyToMCPValue(testArray)
        
        if case .array(let values) = mcpValue {
            XCTAssertEqual(values.count, 4)
            
            // Check each element
            if case .string(let str) = values[0] {
                XCTAssertEqual(str, "hello")
            } else {
                XCTFail("Expected string at index 0")
            }
            
            if case .int(let int) = values[1] {
                XCTAssertEqual(int, 42)
            } else {
                XCTFail("Expected int at index 1")
            }
            
            if case .bool(let bool) = values[2] {
                XCTAssertEqual(bool, true)
            } else {
                XCTFail("Expected bool at index 2")
            }
            
            if case .double(let double) = values[3] {
                XCTAssertEqual(double, 3.14, accuracy: 0.01)
            } else {
                XCTFail("Expected double at index 3")
            }
        } else {
            XCTFail("Expected array MCP value")
        }
    }
    
    func testDictionaryToMCPValue() {
        let testDict: [String: Any] = [
            "name": "test",
            "count": 10,
            "enabled": false,
            "ratio": 0.5
        ]
        
        let mcpValues = testDict.toMCPValue()
        
        XCTAssertEqual(mcpValues.count, 4)
        
        if case .string(let name) = mcpValues["name"] {
            XCTAssertEqual(name, "test")
        } else {
            XCTFail("Expected string value for 'name'")
        }
        
        if case .int(let count) = mcpValues["count"] {
            XCTAssertEqual(count, 10)
        } else {
            XCTFail("Expected int value for 'count'")
        }
        
        if case .bool(let enabled) = mcpValues["enabled"] {
            XCTAssertEqual(enabled, false)
        } else {
            XCTFail("Expected bool value for 'enabled'")
        }
        
        if case .double(let ratio) = mcpValues["ratio"] {
            XCTAssertEqual(ratio, 0.5, accuracy: 0.01)
        } else {
            XCTFail("Expected double value for 'ratio'")
        }
    }
    
    func testNestedStructureToMCPValue() {
        let testDict: [String: Any] = [
            "user": [
                "id": 123,
                "name": "John Doe",
                "settings": [
                    "theme": "dark",
                    "notifications": true
                ]
            ],
            "tags": ["swift", "mcp", "testing"]
        ]
        
        let mcpValues = testDict.toMCPValue()
        
        // Check nested user object
        if case .object(let user) = mcpValues["user"] {
            if case .int(let id) = user["id"] {
                XCTAssertEqual(id, 123)
            } else {
                XCTFail("Expected int value for user.id")
            }
            
            if case .string(let name) = user["name"] {
                XCTAssertEqual(name, "John Doe")
            } else {
                XCTFail("Expected string value for user.name")
            }
            
            if case .object(let settings) = user["settings"] {
                if case .string(let theme) = settings["theme"] {
                    XCTAssertEqual(theme, "dark")
                } else {
                    XCTFail("Expected string value for settings.theme")
                }
                
                if case .bool(let notifications) = settings["notifications"] {
                    XCTAssertEqual(notifications, true)
                } else {
                    XCTFail("Expected bool value for settings.notifications")
                }
            } else {
                XCTFail("Expected object value for user.settings")
            }
        } else {
            XCTFail("Expected object value for 'user'")
        }
        
        // Check tags array
        if case .array(let tags) = mcpValues["tags"] {
            XCTAssertEqual(tags.count, 3)
            
            if case .string(let tag1) = tags[0] {
                XCTAssertEqual(tag1, "swift")
            } else {
                XCTFail("Expected string value for first tag")
            }
        } else {
            XCTFail("Expected array value for 'tags'")
        }
    }
    
    func testMCPArgumentsSerialization() {
        let testArgs: [String: Any] = [
            "input": "test input",
            "count": 5,
            "options": [
                "verbose": true,
                "format": "json"
            ]
        ]
        
        let mcpArguments = MCPArguments(testArgs)
        let convertedArgs = mcpArguments.toMCPValue()
        
        XCTAssertNotNil(convertedArgs)
        XCTAssertEqual(convertedArgs?.count, 3)
        
        // Verify the conversion through serialization/deserialization
        let backToAnyDict = mcpArguments.toAnyDict()
        XCTAssertNotNil(backToAnyDict)
        
        if let dict = backToAnyDict {
            XCTAssertEqual(dict["input"] as? String, "test input")
            XCTAssertEqual(dict["count"] as? Int, 5)
            
            if let options = dict["options"] as? [String: Any] {
                XCTAssertEqual(options["verbose"] as? Bool, true)
                XCTAssertEqual(options["format"] as? String, "json")
            } else {
                XCTFail("Expected options dictionary")
            }
        }
    }
    
    func testMCPArgumentsWithNil() {
        let mcpArguments = MCPArguments(nil)
        
        XCTAssertNil(mcpArguments.toMCPValue())
        XCTAssertNil(mcpArguments.toAnyDict())
    }
    
    func testUnsupportedTypeConversion() {
        // Test conversion of unsupported types (should convert to string)
        let testDate = Date()
        let mcpValue = convertAnyToMCPValue(testDate)
        
        if case .string(let value) = mcpValue {
            XCTAssertTrue(value.contains("Date"))
        } else {
            XCTFail("Expected string MCP value for unsupported type")
        }
    }
    
    func testEmptyContainerConversion() {
        // Test empty array
        let emptyArray: [Any] = []
        let arrayValue = convertAnyToMCPValue(emptyArray)
        
        if case .array(let values) = arrayValue {
            XCTAssertEqual(values.count, 0)
        } else {
            XCTFail("Expected empty array MCP value")
        }
        
        // Test empty dictionary
        let emptyDict: [String: Any] = [:]
        let dictValues = emptyDict.toMCPValue()
        
        XCTAssertEqual(dictValues.count, 0)
    }
}