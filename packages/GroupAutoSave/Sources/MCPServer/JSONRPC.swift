import Foundation

public enum JSONRPCError: Int {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
}

public struct JSONRPCErrorPayload: Codable, Equatable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public init(_ kind: JSONRPCError, message: String) {
        self.code = kind.rawValue
        self.message = message
    }
}

public enum JSONRPCID: Codable, Equatable, Hashable {
    case string(String)
    case int(Int64)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let i = try? container.decode(Int64.self) {
            self = .int(i)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSON-RPC id must be string, integer, or null"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s):
            try container.encode(s)
        case .int(let i):
            try container.encode(i)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct JSONRPCRequest: Decodable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let method: String
    public let params: Data?

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc) ?? "2.0"
        self.id = try container.decodeIfPresent(JSONRPCID.self, forKey: .id)
        self.method = try container.decode(String.self, forKey: .method)
        if container.contains(.params) {
            let raw = try container.decode(JSONValue.self, forKey: .params)
            self.params = try? JSONEncoder().encode(raw)
        } else {
            self.params = nil
        }
    }
}

public enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

public struct JSONRPCResponseEnvelope {
    public let id: JSONRPCID?
    public let result: Data?
    public let error: JSONRPCErrorPayload?

    public init(id: JSONRPCID?, result: Data) {
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: JSONRPCID?, error: JSONRPCErrorPayload) {
        self.id = id
        self.result = nil
        self.error = error
    }

    public func encode() throws -> Data {
        var dict: [String: Any] = ["jsonrpc": "2.0"]
        switch self.id {
        case .none:
            dict["id"] = NSNull()
        case .some(.null):
            dict["id"] = NSNull()
        case .some(.string(let s)):
            dict["id"] = s
        case .some(.int(let i)):
            dict["id"] = i
        }
        if let result = self.result {
            dict["result"] = try JSONSerialization.jsonObject(with: result, options: [.fragmentsAllowed])
        } else if let error = self.error {
            dict["error"] = ["code": error.code, "message": error.message]
        }
        return try JSONSerialization.data(withJSONObject: dict, options: [.fragmentsAllowed])
    }
}
