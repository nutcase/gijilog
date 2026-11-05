import AppKit
import CryptoKit
import Foundation
import Network
import Security

@MainActor final class CalendarLogin {
    struct Code {
        let value: String
        let verifier: String
        let redirect: String
    }
    private var continuation: CheckedContinuation<Code, Error>?
    private var listener: NWListener?
    private var timeout: Task<Void, Never>?
    private var connections: [NWConnection] = []
    private var verifier = ""
    private var state = ""
    private var redirect = ""
    private let openBrowser: (URL) -> Bool
    init(openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.openBrowser = openBrowser
    }
    static let scopes = [
        "https://www.googleapis.com/auth/calendar.events.readonly",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
    ]
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AppError.message("Google認証の準備に失敗しました。")
        }
        return base64(Data(bytes))
    }
    static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func authorizationURL(client: GoogleOAuthClient, redirect: String, verifier: String, state: String) throws
        -> URL
    {
        var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        parts?.queryItems = [
            "client_id": client.clientID, "redirect_uri": redirect, "response_type": "code",
            "scope": scopes.joined(separator: " "), "access_type": "offline", "prompt": "consent select_account",
            "code_challenge": base64(Data(SHA256.hash(data: Data(verifier.utf8)))), "code_challenge_method": "S256",
            "state": state,
        ].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts?.url else { throw URLError(.badURL) }
        return url
    }
    static func callback(_ target: String, state: String) throws -> String? {
        guard target.hasPrefix("/oauth/callback?"), let parts = URLComponents(string: "http://127.0.0.1" + target),
            parts.path == "/oauth/callback"
        else { return nil }
        let states = parts.queryItems?.filter { $0.name == "state" } ?? []
        guard states.count == 1, states.first?.value == state else { return nil }
        if parts.queryItems?.contains(where: { $0.name == "error" }) == true {
            throw AppError.message("Google連携がキャンセルされました。")
        }
        let codes = parts.queryItems?.filter { $0.name == "code" } ?? []
        guard codes.count == 1, let code = codes.first?.value, !code.isEmpty else { return nil }
        return code
    }
    func authorize(_ client: GoogleOAuthClient) async throws -> Code {
        guard continuation == nil else { throw AppError.message("Google認証はすでに開始しています。") }
        try Task.checkCancellation()
        verifier = try Self.random()
        state = try Self.random()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                server.stateUpdateHandler = { [weak self] status in
                    MainActor.assumeIsolated {
                        guard let self, self.listener === server, self.continuation != nil else { return }
                        switch status {
                        case .ready:
                            guard let port = server.port else {
                                self.cancel()
                                return
                            }
                            self.redirect = "http://127.0.0.1:\(port.rawValue)/oauth/callback"
                            do {
                                let url = try Self.authorizationURL(
                                    client: client, redirect: self.redirect, verifier: self.verifier, state: self.state)
                                if !self.openBrowser(url) {
                                    self.finish(.failure(AppError.message("ブラウザを開けませんでした。")))
                                }
                            } catch { self.finish(.failure(error)) }
                        case .failed: self.finish(.failure(AppError.message("Google認証の受け取りを開始できませんでした。")))
                        default: break
                        }
                    }
                }
                server.newConnectionHandler = { [weak self] connection in
                    MainActor.assumeIsolated {
                        guard let self, self.listener === server, self.continuation != nil,
                            self.connections.count < 16
                        else {
                            connection.cancel()
                            return
                        }
                        self.connections.append(connection)
                        connection.start(queue: .main)
                        self.receive(connection, data: Data())
                    }
                }
                server.start(queue: .main)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 180_000_000_000) } catch { return }
                    self?.finish(.failure(AppError.message("Google認証が時間切れになりました。もう一度接続してください。")))
                }
            }
        } onCancel: {
            Task { @MainActor in
                if self.listener === server { self.cancel() }
            }
        }
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] part, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, self.continuation != nil, self.connections.contains(where: { $0 === connection }) else {
                    connection.cancel()
                    return
                }
                let all = data + (part ?? Data())
                guard all.count <= 16384, error == nil else {
                    connection.cancel()
                    return
                }
                let request = String(decoding: all, as: UTF8.self)
                guard request.contains("\r\n\r\n") else {
                    if complete { connection.cancel() } else { self.receive(connection, data: all) }
                    return
                }
                let line = request.components(separatedBy: "\r\n")[0].split(separator: " ")
                do {
                    guard line.count == 3, line[0] == "GET",
                        let code = try Self.callback(String(line[1]), state: self.state)
                    else {
                        self.respond(connection, success: false)
                        return
                    }
                    // Send the page before closing this connection; the listener can stop immediately.
                    self.connections.removeAll { $0 === connection }
                    self.respond(connection, success: true)
                    self.finish(.success(Code(value: code, verifier: self.verifier, redirect: self.redirect)))
                } catch {
                    self.connections.removeAll { $0 === connection }
                    self.respond(connection, success: false)
                    self.finish(.failure(error))
                }
            }
        }
    }
    private func respond(_ connection: NWConnection, success: Bool) {
        connections.removeAll { $0 === connection }
        let body = success ? "認証を受け取りました。ギジログに戻って接続結果を確認してください。" : "認証を受け取れませんでした。ギジログに戻ってください。"
        let reply =
            "HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
            + body
        connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<Code, Error>) {
        let pending = continuation
        continuation = nil
        timeout?.cancel()
        timeout = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections { connection.cancel() }
        connections = []
        pending?.resume(with: result)
    }
}
