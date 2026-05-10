import Foundation
import Network

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        for (k, v) in self.headers where k.lowercased() == lower {
            return v
        }
        return nil
    }
}

public struct HTTPResponse {
    public let status: Int
    public let reason: String
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, reason: String, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.reason = reason
        self.headers = headers
        self.body = body
    }

    public static func json(status: Int = 200, body: Data) -> HTTPResponse {
        return HTTPResponse(
            status: status,
            reason: HTTPResponse.reasonPhrase(for: status),
            headers: [
                "Content-Type": "application/json",
                "Content-Length": String(body.count),
                "Connection": "close",
            ],
            body: body
        )
    }

    public static func plain(status: Int, message: String) -> HTTPResponse {
        let body = Data(message.utf8)
        return HTTPResponse(
            status: status,
            reason: HTTPResponse.reasonPhrase(for: status),
            headers: [
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Length": String(body.count),
                "Connection": "close",
            ],
            body: body
        )
    }

    static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }

    func serialize() -> Data {
        var lines = "HTTP/1.1 \(self.status) \(self.reason)\r\n"
        for (k, v) in self.headers {
            lines += "\(k): \(v)\r\n"
        }
        lines += "\r\n"
        var data = Data(lines.utf8)
        data.append(self.body)
        return data
    }
}

@available(macOS 10.14, *)
public final class HTTPServer {
    public typealias RequestHandler = (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void

    private let queue = DispatchQueue(label: "com.n71903.telegram.MCPServer.HTTPServer")
    private var listener: NWListener?
    private let handler: RequestHandler

    public init(handler: @escaping RequestHandler) {
        self.handler = handler
    }

    public func start(port: UInt16) throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection: connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                NSLog("MCPServer.HTTPServer failed: \(error)")
            default:
                break
            }
        }
        listener.start(queue: self.queue)
        self.listener = listener
        return listener.port?.rawValue ?? port
    }

    public func stop() {
        self.listener?.cancel()
        self.listener = nil
    }

    private func accept(connection: NWConnection) {
        connection.start(queue: self.queue)
        self.readRequest(connection: connection, accumulated: Data())
    }

    private func readRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error = error {
                NSLog("MCPServer.HTTPServer read error: \(error)")
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data = data {
                buffer.append(data)
            }
            if let request = HTTPServer.tryParseRequest(buffer: buffer) {
                self.handler(request) { response in
                    self.send(response: response, on: connection)
                }
                return
            }
            if isComplete {
                self.send(response: HTTPResponse.plain(status: 400, message: "incomplete request"), on: connection)
                return
            }
            if buffer.count > 16 * 1024 * 1024 {
                self.send(response: HTTPResponse.plain(status: 400, message: "payload too large"), on: connection)
                return
            }
            self.readRequest(connection: connection, accumulated: buffer)
        }
    }

    private func send(response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialize(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func tryParseRequest(buffer: Data) -> HTTPRequest? {
        guard let headerEndRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headerData = buffer.subdata(in: 0..<headerEndRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }
        let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let path = parts[1]
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            if let colonIndex = line.firstIndex(of: ":") {
                let name = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }
        let bodyStart = headerEndRange.upperBound
        let availableBody = buffer.subdata(in: bodyStart..<buffer.count)
        if let lengthHeader = headers.first(where: { $0.key.lowercased() == "content-length" })?.value,
           let expected = Int(lengthHeader) {
            if availableBody.count < expected {
                return nil
            }
            let body = availableBody.subdata(in: 0..<expected)
            return HTTPRequest(method: method, path: path, headers: headers, body: body)
        }
        return HTTPRequest(method: method, path: path, headers: headers, body: availableBody)
    }
}
