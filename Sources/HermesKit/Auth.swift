import Foundation
import CryptoKit
import Security

public struct Credentials: Codable, Sendable, Equatable {
    public var baseURL: URL
    public var username: String
    public var accessToken: String
    public var refreshToken: String
    public var provider: String
}

public enum AuthError: LocalizedError {
    case badCredentials, rateLimited, expired, server(Int, String)

    public var errorDescription: String? {
        switch self {
        case .badCredentials: "Wrong username or password."
        case .rateLimited: "Too many attempts. Wait a minute and try again."
        case .expired: "Your session expired. Sign in again."
        case .server(let code, let body): "Server error \(code): \(body.prefix(200))"
        }
    }
}

/// Password sign-in through the gateway's native PKCE flow (the same one Hermes Desktop uses):
/// authorize → password-login → redeem the one-time code for bearer tokens.
public enum Auth {
    // The server only accepts loopback redirect URIs. We never listen on it: the code comes
    // back in password-login's `next` field, so any loopback URL works.
    static let redirectURI = "http://127.0.0.1:1/callback"

    public static func login(baseURL: URL, username: String, password: String, provider: String = "basic") async throws -> Credentials {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let verifier = randomToken()
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomToken()

        var authorize = URLComponents(url: baseURL.appending(path: "auth/native/authorize"), resolvingAgainstBaseURL: false)!
        authorize.queryItems = [
            .init(name: "provider", value: provider),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "state", value: state),
        ]
        // Sets the PKCE cookie that links the password login below to this authorization.
        let (_, authResp) = try await session.data(from: authorize.url!)
        let authStatus = (authResp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<400).contains(authStatus) else { throw AuthError.server(authStatus, "authorize failed") }

        let login = try await post(session, baseURL.appending(path: "auth/password-login"),
                                   ["provider": .string(provider), "username": .string(username), "password": .string(password)])
        guard let next = login["next"]?.string, let comps = URLComponents(string: next),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,
              comps.queryItems?.first(where: { $0.name == "state" })?.value == state
        else { throw AuthError.server(200, "login did not return an authorization code") }

        let tokens = try await post(session, baseURL.appending(path: "auth/native/token"),
                                    ["code": .string(code), "code_verifier": .string(verifier)])
        return try credentials(from: tokens, baseURL: baseURL, username: username, fallbackProvider: provider)
    }

    /// Token calls never follow redirects, so a 3xx can't carry the bearer or refresh token elsewhere.
    static let noRedirects = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    public static func refresh(_ c: Credentials) async throws -> Credentials {
        let tokens = try await post(noRedirects, c.baseURL.appending(path: "auth/native/refresh"),
                                    ["refresh_token": .string(c.refreshToken), "provider": .string(c.provider)])
        return try credentials(from: tokens, baseURL: c.baseURL, username: c.username, fallbackProvider: c.provider)
    }

    /// Single-use, 30 s ticket for the WebSocket upgrade.
    public static func wsTicket(_ c: Credentials) async throws -> String {
        let r = try await post(noRedirects, c.baseURL.appending(path: "api/auth/ws-ticket"), [:], bearer: c.accessToken)
        guard let t = r["ticket"]?.string else { throw AuthError.server(200, "no ticket") }
        return t
    }

    static func credentials(from j: JSON, baseURL: URL, username: String, fallbackProvider: String) throws -> Credentials {
        guard let at = j["access_token"]?.string, let rt = j["refresh_token"]?.string else {
            throw AuthError.server(200, "token response missing tokens")
        }
        return Credentials(baseURL: baseURL, username: username, accessToken: at, refreshToken: rt,
                           provider: j["provider"]?.string ?? fallbackProvider)
    }

    static func post(_ session: URLSession, _ url: URL, _ body: [String: JSON], bearer: String? = nil) async throws -> JSON {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSON.object(body).data()
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return (try? JSON.parse(data)) ?? .null
        case 401 where url.path.hasSuffix("password-login"): throw AuthError.badCredentials
        case 401: throw AuthError.expired
        case 429: throw AuthError.rateLimited
        default: throw AuthError.server(status, String(decoding: data, as: UTF8.self))
        }
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// Credentials live in the Keychain as one JSON blob.
public enum Keychain {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: "hermes-mobile.credentials"]

    public static func load() -> Credentials? {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    public static func save(_ c: Credentials?) {
        SecItemDelete(query as CFDictionary)
        guard let c, let data = try? JSONEncoder().encode(c) else { return }
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}
