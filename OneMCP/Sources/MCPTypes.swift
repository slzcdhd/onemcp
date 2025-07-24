import Foundation
import MCP

// MARK: - Type Conversion Utilities

extension Dictionary where Key == String, Value == Any {
    func toMCPValue() -> [String: MCP.Value] {
        var result: [String: MCP.Value] = [:]
        
        for (key, value) in self {
            result[key] = convertAnyToMCPValue(value)
        }
        
        return result
    }
}

func convertAnyToMCPValue(_ value: Any) -> MCP.Value {
    switch value {
    case let string as String:
        return .string(string)
    case let number as Int:
        return .int(number)
    case let number as Double:
        return .double(number)
    case let bool as Bool:
        return .bool(bool)
    case let array as [Any]:
        return .array(array.map { convertAnyToMCPValue($0) })
    case let dict as [String: Any]:
        return .object(dict.toMCPValue())
    default:
        // For unsupported types, convert to string
        return .string(String(describing: value))
    }
}

// MARK: - Sendable Wrapper for Arguments

struct MCPArguments: Sendable {
    private let serializedData: Data?
    
    init(_ arguments: [String: Any]?) {
        if let args = arguments {
            self.serializedData = try? JSONSerialization.data(withJSONObject: args)
        } else {
            self.serializedData = nil
        }
    }
    
    func toMCPValue() -> [String: MCP.Value]? {
        guard let data = serializedData,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict.toMCPValue()
    }
    
    func toAnyDict() -> [String: Any]? {
        guard let data = serializedData,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict
    }
}