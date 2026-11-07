import Foundation
import Security

struct CloudUser: Codable {
    var id: UUID
    var email: String?
}

struct CloudSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: TimeInterval
    var user: CloudUser

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresAt = "expires_at", user
    }
}

struct CloudSnapshot: Decodable {
    var revision: Int
    var payload: TodoSnapshot
}

struct CloudError: LocalizedError {
    var status: Int
    var code: String?

    var requiresLogin: Bool {
        ["refresh_token_not_found", "refresh_token_already_used", "session_not_found",
         "session_expired", "user_not_found"].contains(code ?? "")
    }

    var errorDescription: String? {
        switch code {
        case "invalid_credentials": return "邮箱或密码不正确。"
        case "email_not_confirmed": return "请先打开邮箱确认注册，再返回 Wo行 登录。"
        case "email_address_not_authorized": return "当前测试邮件仅能发送给 Supabase 项目团队成员。"
        case "over_email_send_rate_limit", "over_request_rate_limit": return "操作过于频繁，请稍后再试。"
        case "user_already_exists": return "这个邮箱已注册，请登录。"
        case "weak_password": return "密码不符合要求，请使用更长、更难猜的密码。"
        case "PGRST202", "PGRST205", "42P01", "42501": return "云端数据表尚未准备好或缺少访问权限。"
        default:
            if requiresLogin { return "登录已过期，请重新登录。" }
            return "云服务请求失败（\(status)）。请稍后重试。"
        }
    }
}

enum CloudAPI {
    private static let base = URL(string: "https://rlyolafslllmfjmxtdkp.supabase.co")!
    private static let key = "sb_publishable_VHxEwJwijignVl1zdmoiig_MNlWY25F"

    private struct ErrorBody: Decodable {
        var code: String?
        var errorCode: String?
        var error: String?

        private enum CodingKeys: String, CodingKey {
            case code, errorCode = "error_code", error
        }
    }

    private struct Credentials: Encodable {
        var email: String
        var password: String
    }

    private struct Refresh: Encodable {
        var refreshToken: String

        private enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token" }
    }

    private struct Save: Encodable {
        var expectedRevision: Int
        var newPayload: TodoSnapshot

        private enum CodingKeys: String, CodingKey {
            case expectedRevision = "expected_revision", newPayload = "new_payload"
        }
    }

    static func signIn(email: String, password: String) async throws -> CloudSession {
        try await decode(CloudSession.self, path: "auth/v1/token", query: [.init(name: "grant_type", value: "password")],
                         method: "POST", body: encode(Credentials(email: email, password: password)))
    }

    static func signUp(email: String, password: String) async throws -> CloudSession? {
        let data = try await request(path: "auth/v1/signup", method: "POST",
                                     body: encode(Credentials(email: email, password: password)))
        // When confirmation is required Supabase returns the user without tokens.
        if let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           response["access_token"] != nil {
            return try JSONDecoder().decode(CloudSession.self, from: data)
        }
        return nil
    }

    static func renew(_ session: CloudSession) async throws -> CloudSession {
        try await decode(CloudSession.self, path: "auth/v1/token",
                         query: [.init(name: "grant_type", value: "refresh_token")],
                         method: "POST", body: encode(Refresh(refreshToken: session.refreshToken)))
    }

    static func signOut(_ session: CloudSession) async {
        _ = try? await request(path: "auth/v1/logout", query: [.init(name: "scope", value: "local")],
                               method: "POST", token: session.accessToken)
    }

    static func load(_ session: CloudSession) async throws -> CloudSnapshot? {
        let rows = try await decode([CloudSnapshot].self, path: "rest/v1/woxing_snapshots",
                                    query: [.init(name: "select", value: "revision,payload"),
                                            .init(name: "user_id", value: "eq.\(session.user.id.uuidString)")],
                                    token: session.accessToken)
        return rows.first
    }

    static func save(_ snapshot: TodoSnapshot, after revision: Int, with session: CloudSession) async throws -> Bool {
        try await decode(Bool.self, path: "rest/v1/rpc/woxing_save_snapshot", method: "POST",
                         token: session.accessToken, body: encode(Save(expectedRevision: revision, newPayload: snapshot)))
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private static func decode<T: Decodable>(
        _ type: T.Type, path: String, query: [URLQueryItem] = [],
        method: String = "GET", token: String? = nil, body: Data? = nil
    ) async throws -> T {
        let data = try await request(path: path, query: query, method: method, token: token, body: body)
        return try JSONDecoder().decode(type, from: data)
    }

    private static func request(
        path: String, query: [URLQueryItem] = [],
        method: String = "GET", token: String? = nil, body: Data? = nil
    ) async throws -> Data {
        let url = base.appending(path: path)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "apikey")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw CloudError(status: http.statusCode, code: error?.errorCode ?? error?.code ?? error?.error)
        }
        return data
    }
}

enum SessionVault {
    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.woxing.cloud",
        kSecAttrAccount as String: "supabase-session"
    ]

    static func load() throws -> CloudSession? {
        var query = item
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw URLError(.cannotDecodeContentData) }
        return try JSONDecoder().decode(CloudSession.self, from: data)
    }

    static func save(_ session: CloudSession) throws {
        let values = [kSecValueData as String: try JSONEncoder().encode(session)]
        let status = SecItemUpdate(item as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = item.merging(values) { _, value in value }
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(newItem as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    static func clear() throws {
        let status = SecItemDelete(item as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法访问系统钥匙串（\(status)）。"])
        }
    }
}
