import Foundation
import AppKit
import Network
import CryptoKit

/// OAuth 2.0 for a Google "Desktop app" client.
///
/// Google requires a loopback redirect for desktop clients, which
/// `ASWebAuthenticationSession` cannot intercept (it only handles custom
/// schemes). So we open the system browser and listen on 127.0.0.1 ourselves —
/// the same flow gcloud and VS Code use.
actor GoogleDriveAuth {

    struct Tokens {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date

        var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
    }

    enum AuthError: LocalizedError {
        case missingClientID
        case listenerFailed
        case denied(String)
        case tokenExchange(String)

        var errorDescription: String? {
            switch self {
            case .missingClientID: "Google istemci kimliği girilmemiş."
            case .listenerFailed: "Yerel yönlendirme dinleyicisi başlatılamadı."
            case .denied(let reason): "Yetkilendirme reddedildi: \(reason)"
            case .tokenExchange(let reason): "Jeton alınamadı: \(reason)"
            }
        }
    }

    private static let scope = "https://www.googleapis.com/auth/drive.readonly"
    private static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private static let keychainAccount = "google-drive-refresh-token"

    private var tokens: Tokens?

    // MARK: - Sign-in

    func signIn(clientID: String, clientSecret: String) async throws -> Tokens {
        guard !clientID.isEmpty else { throw AuthError.missingClientID }

        let verifier = Self.randomURLSafeString(length: 64)
        let challenge = Self.codeChallenge(for: verifier)

        let listener = try LoopbackListener()
        let redirectURI = "http://127.0.0.1:\(listener.port)"

        var components = URLComponents(string: Self.authEndpoint)!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent")
        ]

        guard let authURL = components.url else { throw AuthError.listenerFailed }
        NSWorkspace.shared.open(authURL)

        let code = try await listener.waitForCode()
        let tokens = try await exchange(
            code: code, verifier: verifier, clientID: clientID,
            clientSecret: clientSecret, redirectURI: redirectURI
        )
        self.tokens = tokens
        if let refresh = tokens.refreshToken {
            Keychain.set(refresh, for: Self.keychainAccount)
        }
        return tokens
    }

    func signOut() {
        tokens = nil
        Keychain.remove(account: Self.keychainAccount)
    }

    var hasStoredCredentials: Bool {
        Keychain.get(account: Self.keychainAccount) != nil
    }

    /// Returns a usable access token, refreshing it when needed.
    func validAccessToken(clientID: String, clientSecret: String) async throws -> String {
        if let tokens, !tokens.isExpired { return tokens.accessToken }

        guard let refreshToken = tokens?.refreshToken ?? Keychain.get(account: Self.keychainAccount) else {
            throw AuthError.denied("Oturum yok, yeniden bağlanın.")
        }
        let refreshed = try await refresh(
            refreshToken: refreshToken, clientID: clientID, clientSecret: clientSecret
        )
        tokens = refreshed
        return refreshed.accessToken
    }

    // MARK: - Token endpoints

    private func exchange(code: String,
                          verifier: String,
                          clientID: String,
                          clientSecret: String,
                          redirectURI: String) async throws -> Tokens {
        var fields = [
            "code": code,
            "client_id": clientID,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        if !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
        return try await postToken(fields: fields, existingRefresh: nil)
    }

    private func refresh(refreshToken: String,
                         clientID: String,
                         clientSecret: String) async throws -> Tokens {
        var fields = [
            "refresh_token": refreshToken,
            "client_id": clientID,
            "grant_type": "refresh_token"
        ]
        if !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
        return try await postToken(fields: fields, existingRefresh: refreshToken)
    }

    private func postToken(fields: [String: String], existingRefresh: String?) async throws -> Tokens {
        var request = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.tokenExchange(body.prefix(200).description)
        }

        struct TokenResponse: Decodable {
            var access_token: String
            var refresh_token: String?
            var expires_in: Double?
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return Tokens(
            accessToken: decoded.access_token,
            // A refresh grant does not return a new refresh token.
            refreshToken: decoded.refresh_token ?? existingRefresh,
            expiresAt: Date().addingTimeInterval(decoded.expires_in ?? 3600)
        )
    }

    // MARK: - PKCE helpers

    private static func randomURLSafeString(length: Int) -> String {
        let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in charset.randomElement()! })
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Single-shot HTTP listener that captures Google's `?code=` redirect.
///
/// Uses a plain BSD socket rather than `NWListener`: every `NWListener`
/// configuration tried here fails to bind with `EINVAL`, while a socket bound to
/// 127.0.0.1:0 works and needs no entitlements.
private final class LoopbackListener {
    let port: UInt16
    private let descriptor: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GoogleDriveAuth.AuthError.listenerFailed }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                       // let the OS pick a free port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw GoogleDriveAuth.AuthError.listenerFailed
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }

        descriptor = fd
        port = UInt16(bigEndian: assigned.sin_port)
        guard port != 0 else {
            close(fd)
            throw GoogleDriveAuth.AuthError.listenerFailed
        }
    }

    /// Blocks on `accept` off the main thread until Google redirects back.
    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [descriptor] in
                defer { close(descriptor) }

                let client = accept(descriptor, nil, nil)
                guard client >= 0 else {
                    continuation.resume(throwing: GoogleDriveAuth.AuthError.listenerFailed)
                    return
                }
                defer { close(client) }

                var buffer = [UInt8](repeating: 0, count: 8192)
                let count = read(client, &buffer, buffer.count)
                let request = String(bytes: buffer[0..<max(count, 0)], encoding: .utf8) ?? ""

                // "GET /?code=XXXX&scope=... HTTP/1.1"
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let query = URLComponents(string: "http://127.0.0.1\(path)")?.queryItems ?? []
                let code = query.first { $0.name == "code" }?.value
                let failure = query.first { $0.name == "error" }?.value

                let message = code != nil
                    ? "ZyPlayer bağlandı. Bu sekmeyi kapatabilirsiniz."
                    : "Yetkilendirme başarısız."
                let html = "<html><head><meta charset=\"utf-8\"></head>"
                    + "<body style=\"font-family:-apple-system;text-align:center;padding-top:80px\">"
                    + "<h2>\(message)</h2></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                _ = response.withCString { write(client, $0, strlen($0)) }

                if let code {
                    continuation.resume(returning: code)
                } else {
                    continuation.resume(
                        throwing: GoogleDriveAuth.AuthError.denied(failure ?? "bilinmeyen")
                    )
                }
            }
        }
    }
}
