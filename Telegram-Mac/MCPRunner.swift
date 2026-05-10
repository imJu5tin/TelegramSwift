import Foundation
import TelegramCore
import MCPServer

@available(macOS 10.14, *)
final class MCPRunner {
    private let server: MCPServer
    private(set) var listenedPort: UInt16?
    var openChatHandler: ((Int64, Int32?) -> Void)?
    var currentViewProvider: (() -> [String: Any])?
    var goBackHandler: (() -> Bool)?
    var openUrlHandler: ((String) -> [String: Any])?

    init(account: Account, engine: TelegramEngine) {
        let info = MCPServerInfo(name: "telegram-archive-mcp", version: "0.1.0")
        self.server = MCPServer(info: info)
        let openProvider: () -> ((Int64, Int32?) -> Void)? = { [weak self] in
            return self?.openChatHandler
        }
        let currentViewClosure: () -> (() -> [String: Any])? = { [weak self] in
            return self?.currentViewProvider
        }
        let goBackClosure: () -> (() -> Bool)? = { [weak self] in
            return self?.goBackHandler
        }
        let openUrlClosure: () -> ((String) -> [String: Any])? = { [weak self] in
            return self?.openUrlHandler
        }
        registerTelegramTools(server: self.server, account: account, engine: engine, openChatProvider: openProvider, currentViewProvider: currentViewClosure, goBackProvider: goBackClosure, openUrlProvider: openUrlClosure)
    }

    func start(preferredPort: UInt16 = 7777) {
        do {
            let port = try self.server.start(port: preferredPort)
            self.listenedPort = port
            let endpoint = "http://127.0.0.1:\(port)/mcp"
            let token = self.server.bearerToken
            NSLog("[telegram-archive-mcp] listening at \(endpoint) (token at ~/.config/telegram-archive-mcp/token)")
            self.writeEndpointFile(endpoint: endpoint, token: token)
        } catch {
            NSLog("[telegram-archive-mcp] failed to start on \(preferredPort): \(error). Falling back to dynamic port.")
            do {
                let port = try self.server.start(port: 0)
                self.listenedPort = port
                let endpoint = "http://127.0.0.1:\(port)/mcp"
                NSLog("[telegram-archive-mcp] listening at \(endpoint)")
                self.writeEndpointFile(endpoint: endpoint, token: self.server.bearerToken)
            } catch {
                NSLog("[telegram-archive-mcp] failed to start: \(error)")
            }
        }
    }

    func stop() {
        self.server.stop()
        self.listenedPort = nil
    }

    private func writeEndpointFile(endpoint: String, token: String) {
        let home = (NSHomeDirectory() as NSString)
        let dir = home.appendingPathComponent(".config/telegram-archive-mcp")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        let endpointPath = (dir as NSString).appendingPathComponent("endpoint")
        try? endpoint.write(toFile: endpointPath, atomically: true, encoding: .utf8)
    }
}
