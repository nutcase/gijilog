import Foundation
import Security

struct GoogleCredential: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expires: Date
    var client: GoogleOAuthClient
}
struct CalendarVault: Sendable {
    var read: @Sendable () throws -> Data? = {
        var query = Self.query
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AppError.message("Google連携の認証情報を読み込めません（\(status)）。") }
        return item as? Data
    }
    var write: @Sendable (Data?) throws -> Void = { data in
        guard let data else {
            let status = SecItemDelete(Self.query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AppError.message("Google連携を解除できません（\(status)）。")
            }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: "ギジログ Googleカレンダー"]
        var status = SecItemUpdate(Self.query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(Self.query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppError.message("Google連携の認証情報を保存できません（\(status)）。") }
    }
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.nutcase.gijilog.google-calendar",
            kSecAttrAccount as String: "oauth", kSecAttrSynchronizable as String: false,
        ]
    }
}
actor GoogleCalendarClient {
    private let session: URLSession
    private let vault: CalendarVault
    private var credential: GoogleCredential?
    private var generation = 0
    init(session: URLSession = .shared, vault: CalendarVault = CalendarVault()) {
        self.session = session
        self.vault = vault
    }
    func restore() throws -> Bool {
        credential = try vault.read().map { try JSONDecoder().decode(GoogleCredential.self, from: $0) }
        return credential != nil
    }
    func disconnect() throws {
        generation += 1
        credential = nil
        try vault.write(nil)
    }
    private struct Token: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }
    static func form(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
    private func token(_ fields: [String: String]) async throws -> Token {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(fields)
        return try await requestJSON(request)
    }
    func connect(client: GoogleOAuthClient, code: String, verifier: String, redirect: String) async throws {
        let epoch = generation
        var fields = [
            "client_id": client.clientID, "code": code, "code_verifier": verifier,
            "redirect_uri": redirect, "grant_type": "authorization_code",
        ]
        fields["client_secret"] = client.clientSecret
        let result = try await token(fields)
        guard epoch == generation else { throw CancellationError() }
        guard let refresh = result.refreshToken, !refresh.isEmpty else {
            throw AppError.message("継続アクセスを取得できません。Google連携をやり直してください。")
        }
        let saved = GoogleCredential(
            accessToken: result.accessToken, refreshToken: refresh,
            expires: Date().addingTimeInterval(result.expiresIn), client: client)
        try vault.write(JSONEncoder().encode(saved))
        credential = saved
    }
    private func accessToken() async throws -> String {
        guard var current = credential else { throw AppError.message("Googleアカウントを接続してください。") }
        if current.expires.timeIntervalSinceNow > 60 { return current.accessToken }
        let epoch = generation
        var fields = [
            "client_id": current.client.clientID, "refresh_token": current.refreshToken, "grant_type": "refresh_token",
        ]
        fields["client_secret"] = current.client.clientSecret
        let result = try await token(fields)
        guard epoch == generation else { throw CancellationError() }
        current.accessToken = result.accessToken
        current.refreshToken = result.refreshToken ?? current.refreshToken
        current.expires = Date().addingTimeInterval(result.expiresIn)
        try vault.write(JSONEncoder().encode(current))
        credential = current
        return current.accessToken
    }
    private struct Page<Item: Decodable>: Decodable {
        let items: [Item]?
        let nextPageToken: String?
    }
    private func pages<Item: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> [Item] {
        let epoch = generation
        let token = try await accessToken()
        var result: [Item] = []
        var next: String?
        var visited: Set<String> = []
        repeat {
            guard var url = URLComponents(string: "https://www.googleapis.com/calendar/v3/" + path) else {
                throw URLError(.badURL)
            }
            url.queryItems = query + (next.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            guard let endpoint = url.url else { throw URLError(.badURL) }
            var request = URLRequest(url: endpoint)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let page: Page<Item> = try await requestJSON(request)
            guard epoch == generation else { throw CancellationError() }
            result += page.items ?? []
            next = page.nextPageToken
            if let next, !visited.insert(next).inserted { throw AppError.message("Googleの予定一覧を最後まで取得できませんでした。") }
        } while next != nil
        return result
    }
    func calendars() async throws -> [GoogleCalendarInfo] { try await pages("users/me/calendarList") }
    func events(calendars: Set<String>, now: Date = Date(), window: TimeInterval? = nil) async throws -> [CalendarEvent]
    {
        var result: [CalendarEvent] = []
        let formatter = ISO8601DateFormatter()
        // API bounds are exclusive and ignore fractions; pad by a second, then filter precisely locally.
        let from = window.map { now.addingTimeInterval(-$0 - 1) } ?? Calendar.current.startOfDay(for: now)
        let until = window.map { now.addingTimeInterval($0 + 1) } ?? now.addingTimeInterval(7 * 86400)
        let query = [
            URLQueryItem(name: "singleEvents", value: "true"), URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "timeMin", value: formatter.string(from: from)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: until)),
            URLQueryItem(name: "maxResults", value: "250"), URLQueryItem(name: "showDeleted", value: "false"),
        ]
        for calendar in calendars.sorted() {
            guard let encoded = calendar.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { continue }
            let items: [GoogleEvent] = try await pages("calendars/\(encoded)/events", query: query)
            result += items.compactMap { $0.event(calendarID: calendar) }
        }
        return result.sorted { $0.start < $1.start }
    }
    private func requestJSON<T: Decodable>(_ request: URLRequest) async throws -> T {
        var request = request
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            // Never display token responses or URLs containing authorization codes.
            if code == 401 || code == 400 { throw AppError.message("Googleの認証を更新できません。再接続してください。") }
            if code == 403 { throw AppError.message("予定を取得できません。カレンダーの読み取り権限とCalendar APIの設定を確認してください。") }
            throw AppError.message("Googleカレンダーとの通信に失敗しました（\(code)）。")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
