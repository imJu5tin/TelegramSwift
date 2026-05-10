import Foundation

public struct ToolRegistration {
    public let name: String
    public let description: String
    public let inputSchemaJSON: String
    public let handler: ToolHandler

    public init(name: String, description: String, inputSchemaJSON: String, handler: @escaping ToolHandler) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
        self.handler = handler
    }
}

public typealias ToolHandler = (_ argsJSON: Data, _ completion: @escaping (Result<Data, ToolError>) -> Void) -> Void

public struct ToolError: Error {
    public let code: Int
    public let message: String

    public init(code: Int = -32000, message: String) {
        self.code = code
        self.message = message
    }
}

public final class ToolRegistry {
    private var tools: [String: ToolRegistration] = [:]
    private let queue = DispatchQueue(label: "com.n71903.telegram.MCPServer.ToolRegistry")

    public init() {}

    public func register(_ tool: ToolRegistration) {
        self.queue.sync {
            self.tools[tool.name] = tool
        }
    }

    public func unregister(name: String) {
        self.queue.sync { () -> Void in
            self.tools.removeValue(forKey: name)
        }
    }

    public func tool(named name: String) -> ToolRegistration? {
        return self.queue.sync { self.tools[name] }
    }

    public func allTools() -> [ToolRegistration] {
        return self.queue.sync { Array(self.tools.values).sorted { $0.name < $1.name } }
    }

    public func toolListJSON() -> Data {
        let tools = self.allTools()
        var entries: [[String: Any]] = []
        for tool in tools {
            var entry: [String: Any] = [
                "name": tool.name,
                "description": tool.description,
            ]
            if let schemaData = tool.inputSchemaJSON.data(using: .utf8),
               let schema = try? JSONSerialization.jsonObject(with: schemaData) {
                entry["inputSchema"] = schema
            } else {
                entry["inputSchema"] = ["type": "object"]
            }
            entries.append(entry)
        }
        let payload: [String: Any] = ["tools": entries]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"tools\":[]}".utf8)
    }
}
