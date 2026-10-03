import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// "Sign in with ChatGPT": uses the writer's own ChatGPT plan for AI features.
///
/// Follows OpenAI's documented flow for local and personal apps
/// (https://developers.openai.com/siwc): OAuth 2 authorization code with PKCE
/// over a 127.0.0.1 loopback redirect, dynamic client registration on first
/// sign-in, ID-token verification against OpenAI's published keys, and
/// requests to the Responses API with the resulting access token.
/// Credentials live in the login Keychain.
@MainActor
final class ChatGPTAuth: ObservableObject {
    static let shared = ChatGPTAuth()

    struct Connection: Codable {
        var clientId: String
        var subject: String
        var email: String?
        var name: String?
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        var earliestRefreshAt: Date?
        var scopes: [String]
        var idToken: String
    }

    struct Model: Identifiable, Hashable {
        var id: String { slug }
        let slug: String
        let displayName: String
        /// Reasoning levels this model accepts, lightest first.
        var levels: [ReasoningLevel] = []
        /// The level the model uses when none is requested.
        var defaultLevel: String?
    }

    struct ReasoningLevel: Hashable, Codable {
        let effort: String
        let description: String
    }

    @Published private(set) var connection: Connection?
    @Published private(set) var models: [Model] = []
    @Published private(set) var signingIn = false
    @Published var lastError: String?

    private static let issuer = "https://auth.openai.com"
    private static let resource = "https://api.openai.com/v1"
    private static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    private static let planScope = "chatgpt.tokens.use.direct"
    private static let appName = "Redraft"
    private static let clientIdKey = "chatgptClientId"

    private let keychain = KeychainData(account: "chatgpt-connection")
    private var signInTask: Task<Void, Never>?
    private var refreshTask: Task<Connection, Error>?
    private(set) var structuredOutputUnsupported = false

    private var loaded = false

    private init() {}

    /// Reads the saved connection from the Keychain, once, off the main
    /// thread. macOS may ask permission (e.g. after a rebuild changes the
    /// app's signature); that prompt must never block launch or typing.
    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        let keychain = self.keychain
        let data = await Task.detached(priority: .userInitiated) { keychain.read() }.value
        if connection == nil, let data, let saved = try? JSONDecoder().decode(Connection.self, from: data) {
            connection = saved
        }
    }

    var isConnected: Bool { connection != nil }

    /// The model chosen in Settings, or the default.
    var currentModel: String? {
        let stored = AISettings.storedModel(.chatGPT)
        if !stored.isEmpty { return stored }
        return defaultModel?.slug ?? UserDefaults.standard.string(forKey: "chatgptDefaultModelCache")
    }

    /// Astra when the plan offers it, otherwise the first model listed.
    var defaultModel: Model? {
        models.first { $0.slug.localizedCaseInsensitiveContains("astra") } ?? models.first
    }

    /// Reasoning levels for a model, lightest first (from the last catalog seen).
    static func reasoningLadder(for slug: String) -> [String]? {
        (UserDefaults.standard.dictionary(forKey: "chatgptReasoningLevels") as? [String: [String]])?[slug]
    }

    // MARK: Sign in / out

    func signIn() {
        guard !signingIn else { return }
        lastError = nil
        signingIn = true
        signInTask = Task {
            defer { signingIn = false; signInTask = nil }
            do {
                let result = try await authorize()
                save(result)
                await loadModels()
            } catch is CancellationError {
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }

    func signOut() {
        let old = connection
        connection = nil
        models = []
        keychain.delete()
        // The client registration isn't secret; keep it so signing in again
        // reuses this app's registration instead of creating another.
        guard let old, let token = old.refreshToken else { return }
        Task {
            guard let discovery = try? await Self.discovery(), let revoke = discovery.revocationEndpoint else { return }
            var request = URLRequest(url: revoke)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
            request.httpBody = Self.form(["token": token, "token_type_hint": "refresh_token", "client_id": old.clientId])
            let status = (try? await URLSession.shared.data(for: request).1 as? HTTPURLResponse)?.statusCode
            if status != 200 {
                lastError = "Signed out here, but couldn't confirm with OpenAI. You can also disconnect Redraft in ChatGPT settings."
            }
        }
    }

    private func save(_ new: Connection) {
        connection = new
        UserDefaults.standard.set(new.clientId, forKey: Self.clientIdKey)
        if let data = try? JSONEncoder().encode(new) { keychain.write(data) }
    }

    private func authorize() async throws -> Connection {
        await loadIfNeeded()
        let discovery = try await Self.discovery()
        let state = Self.randomValue()
        let nonce = Self.randomValue()
        let verifier = Self.randomValue()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let savedClientId = connection?.clientId ?? UserDefaults.standard.string(forKey: Self.clientIdKey)

        let server = try LoopbackServer()
        defer { server.stop() }
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)/auth/callback"

        var components = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "client_id", value: savedClientId ?? "dynamic_agent_client"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "resource", value: Self.resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]
        if savedClientId == nil { query.append(URLQueryItem(name: "agent_name_hint", value: Self.appName)) }
        if let email = connection?.email { query.append(URLQueryItem(name: "login_hint", value: email)) }
        components.queryItems = query
        guard let url = components.url else { throw ChatGPTFailure("Couldn't build the sign-in link.") }
        NSWorkspace.shared.open(url)

        let callback = try await server.waitForCallback(state: state)
        if let error = callback.error {
            throw ChatGPTFailure(error == "access_denied" ? "Sign-in wasn't completed. Try again whenever you're ready." : Self.message(forCode: error))
        }
        guard let code = callback.code else { throw ChatGPTFailure("ChatGPT didn't finish signing in. Please try again.") }
        guard let clientId = callback.clientId ?? savedClientId,
              clientId != "dynamic_agent_client",
              clientId.range(of: #"^[A-Za-z0-9_-]{1,200}$"#, options: .regularExpression) != nil else {
            throw ChatGPTFailure("ChatGPT didn't finish registering Redraft. Please try again.")
        }
        // Keep the registration even if the code exchange below fails.
        UserDefaults.standard.set(clientId, forKey: Self.clientIdKey)

        let data = try await Self.tokenRequest(discovery, [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirect,
            "resource": Self.resource,
        ])
        guard let idToken = data["id_token"] as? String else {
            throw ChatGPTFailure("ChatGPT didn't return an identity to verify. Please sign in again.")
        }
        let identity = try await IDToken.verify(idToken, clientId: clientId, nonce: nonce, discovery: discovery)
        if let previous = connection, previous.subject != identity.subject {
            throw ChatGPTFailure("That's a different ChatGPT account than the one connected. Disconnect first to switch accounts.")
        }
        let tokens = try Self.tokens(from: data, previousScopes: nil, previousRefresh: nil)
        guard tokens.scopes.contains(Self.planScope) else {
            throw ChatGPTFailure("ChatGPT didn't grant permission to use your plan. Try signing in again and approve plan usage.")
        }
        return Connection(
            clientId: clientId, subject: identity.subject, email: identity.email, name: identity.name,
            accessToken: tokens.access, refreshToken: tokens.refresh, expiresAt: tokens.expiresAt,
            earliestRefreshAt: tokens.earliestRefresh, scopes: tokens.scopes, idToken: idToken
        )
    }

    // MARK: Tokens

    /// A usable access token, renewing it first if it's about to expire.
    func accessToken() async throws -> String {
        await loadIfNeeded()
        guard let current = connection else { throw AIError.notSetUp }
        let soon = Date().addingTimeInterval(60)
        if current.expiresAt > soon { return current.accessToken }
        if let earliest = current.earliestRefreshAt, earliest > Date(), current.expiresAt > Date() {
            return current.accessToken
        }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let task = Task { try await refresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let renewed = try await task.value
            save(renewed)
            return renewed.accessToken
        } catch let failure as ChatGPTFailure where failure.signInAgain {
            connection = nil
            keychain.delete()
            throw failure
        }
    }

    private func refresh(_ current: Connection) async throws -> Connection {
        guard let refreshToken = current.refreshToken else {
            throw ChatGPTFailure("Your ChatGPT connection has expired. Sign in again in Settings.", signInAgain: true)
        }
        let discovery = try await Self.discovery()
        let data: [String: Any]
        do {
            data = try await Self.tokenRequest(discovery, [
                "grant_type": "refresh_token",
                "client_id": current.clientId,
                "refresh_token": refreshToken,
                "resource": Self.resource,
            ])
        } catch let failure as ChatGPTFailure where failure.code.map(Self.refreshFatalCodes.contains) == true {
            throw ChatGPTFailure("Your ChatGPT connection can't be renewed anymore. Sign in again in Settings.", signInAgain: true)
        }
        let tokens = try Self.tokens(from: data, previousScopes: current.scopes, previousRefresh: refreshToken)
        var renewed = current
        renewed.accessToken = tokens.access
        renewed.refreshToken = tokens.refresh
        renewed.expiresAt = tokens.expiresAt
        renewed.earliestRefreshAt = tokens.earliestRefresh
        renewed.scopes = tokens.scopes
        if let idToken = data["id_token"] as? String {
            let identity = try await IDToken.verify(idToken, clientId: current.clientId, nonce: nil, discovery: discovery)
            guard identity.subject == current.subject else {
                throw ChatGPTFailure("The renewed ChatGPT identity doesn't match. Sign in again.", signInAgain: true)
            }
            renewed.idToken = idToken
            renewed.email = identity.email ?? renewed.email
            renewed.name = identity.name ?? renewed.name
        }
        return renewed
    }

    private static let refreshFatalCodes: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
        "refresh_token_invalidated", "refresh_token_reused",
    ]

    private struct Tokens {
        let access: String
        let refresh: String?
        let expiresAt: Date
        let earliestRefresh: Date?
        let scopes: [String]
    }

    private static func tokens(from data: [String: Any], previousScopes: [String]?, previousRefresh: String?) throws -> Tokens {
        let scopeString = (data["scope"] as? String) ?? previousScopes?.joined(separator: " ")
        guard let scopeString else { throw ChatGPTFailure("ChatGPT didn't confirm the granted permissions. Please sign in again.") }
        let scopes = scopeString.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let access = data["access_token"] as? String, !access.isEmpty,
              (data["token_type"] as? String)?.lowercased() == "bearer",
              let expiresIn = (data["expires_in"] as? NSNumber)?.doubleValue, expiresIn > 0 else {
            throw ChatGPTFailure("ChatGPT returned incomplete credentials. Please sign in again.")
        }
        let refresh = (data["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? previousRefresh
        if scopes.contains("offline_access") && refresh == nil {
            throw ChatGPTFailure("ChatGPT returned incomplete credentials. Please sign in again.")
        }
        return Tokens(
            access: access, refresh: refresh, expiresAt: Date().addingTimeInterval(expiresIn),
            earliestRefresh: parseDate(data["earliest_refresh_at"]), scopes: scopes
        )
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let seconds = number.doubleValue > 1e12 ? number.doubleValue / 1000 : number.doubleValue
            return Date(timeIntervalSince1970: seconds)
        }
        if let string = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        }
        return nil
    }

    // MARK: Models

    func loadModels() async {
        do {
            let token = try await accessToken()
            var request = URLRequest(url: URL(string: "\(Self.resource)/models")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            request.setValue("application/json", forHTTPHeaderField: "accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data)
            guard status == 200, let body = json as? [String: Any], let list = body["models"] as? [[String: Any]] else {
                throw Self.apiFailure(json, status: status)
            }
            models = list.compactMap { item in
                guard item["visibility"] as? String == "list",
                      let slug = item["slug"] as? String, !slug.isEmpty,
                      let name = item["display_name"] as? String, !name.isEmpty else { return nil }
                let levels = (item["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { level -> ReasoningLevel? in
                    guard let effort = level["effort"] as? String else { return nil }
                    return ReasoningLevel(effort: effort, description: level["description"] as? String ?? "")
                }
                return Model(slug: slug, displayName: name, levels: levels, defaultLevel: item["default_reasoning_level"] as? String)
            }
            // Remember each model's levels so requests can step down correctly before the list reloads.
            let ladders = Dictionary(models.map { ($0.slug, $0.levels.map(\.effort)) }, uniquingKeysWith: { a, _ in a })
            UserDefaults.standard.set(ladders, forKey: "chatgptReasoningLevels")
            if let slug = defaultModel?.slug {
                UserDefaults.standard.set(slug, forKey: "chatgptDefaultModelCache")
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    #if DEBUG
    /// Writes the raw model catalog (no credentials) for inspection.
    func debugDumpModels(to path: String) async {
        guard let token = try? await accessToken() else { return }
        var request = URLRequest(url: URL(string: "\(Self.resource)/models")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if let (data, _) = try? await URLSession.shared.data(for: request) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
    #endif

    // MARK: Requests

    /// Runs one streamed request against the Responses API on the writer's
    /// plan, reporting text as it arrives. Returns the model's full text (JSON,
    /// when a schema is supplied).
    func respond(
        instructions: String, input: String, schema: [String: Any],
        onText: ((String) -> Void)? = nil
    ) async throws -> String {
        await loadIfNeeded()
        #if DEBUG
        if ProcessInfo.processInfo.environment["REDRAFT_FAKE_DISCONNECTED"] != nil { throw AIError.notSetUp }
        #endif
        guard isConnected else { throw AIError.notSetUp }
        if currentModel == nil {
            await loadModels()
        } else if models.isEmpty {
            // Refresh the list in the background; don't make this request wait for it.
            Task { await loadModels() }
        }
        let effort = AISettings.effort(.chatGPT)
        guard let model = currentModel else {
            throw ChatGPTFailure("No ChatGPT models are available for this account. Check Settings.")
        }
        let token = try await accessToken()
        let failure: (Any?, Int) -> Error = { body, status in Self.apiFailure(body, status: status) }
        if !structuredOutputUnsupported {
            do {
                return try await ResponsesStream.run(
                    bearer: token, model: model, instructions: instructions, input: input,
                    schema: schema, effort: effort, ladder: Self.reasoningLadder(for: model), failure: failure, onText: onText
                )
            } catch let failure as ChatGPTFailure where failure.status == 400 || failure.code == "subscription_sharing_unsupported_capability" {
                // This route may not accept structured output; fall back to asking for JSON.
                structuredOutputUnsupported = true
            }
        }
        let schemaText = String(decoding: (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        let text = try await ResponsesStream.run(
            bearer: token, model: model,
            instructions: instructions + "\n\nRespond with only a JSON object matching this JSON Schema, with no Markdown fences or commentary:\n" + schemaText,
            input: input, schema: nil, effort: effort, ladder: Self.reasoningLadder(for: model), failure: failure, onText: onText
        )
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { throw AIError.badResponse }
        return String(text[start...end])
    }

    // MARK: Plumbing

    struct Discovery {
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let revocationEndpoint: URL?
        let jwksURL: URL
        let issuer: String
    }

    private static var cachedDiscovery: Discovery?

    static func discovery() async throws -> Discovery {
        if let cachedDiscovery { return cachedDiscovery }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "\(issuer)/.well-known/openid-configuration")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["issuer"] as? String == issuer else {
            throw ChatGPTFailure("Couldn't verify ChatGPT's sign-in configuration. Try again shortly.")
        }
        func endpoint(_ key: String) -> URL? {
            guard let s = json[key] as? String, let url = URL(string: s), url.scheme == "https", url.host == "auth.openai.com" else { return nil }
            return url
        }
        guard let auth = endpoint("authorization_endpoint"), let token = endpoint("token_endpoint"), let jwks = endpoint("jwks_uri") else {
            throw ChatGPTFailure("Couldn't verify ChatGPT's sign-in configuration. Try again shortly.")
        }
        let result = Discovery(authorizationEndpoint: auth, tokenEndpoint: token, revocationEndpoint: endpoint("revocation_endpoint"), jwksURL: jwks, issuer: issuer)
        cachedDiscovery = result
        return result
    }

    private static func tokenRequest(_ discovery: Discovery, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: discovery.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = form(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(status), let object = json as? [String: Any] else { throw apiFailure(json, status: status) }
        return object
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
    }

    private static func randomValue() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    static func apiFailure(_ body: Any?, status: Int) -> ChatGPTFailure {
        var detail = body as? [String: Any] ?? [:]
        for _ in 0..<4 {
            if let inner = detail["error"] as? [String: Any] { detail = inner }
            else if let inner = detail["detail"] as? [String: Any] { detail = inner }
            else { break }
        }
        let code = (detail["error"] as? String) ?? (detail["code"] as? String)
        var text = code.map(message(forCode:)) ?? ""
        if text.isEmpty {
            switch status {
            case 400, 422: text = (detail["message"] as? String) ?? "ChatGPT couldn't accept this request."
            case 401: text = "ChatGPT didn't accept the saved connection. Try signing in again."
            case 403: text = "A ChatGPT policy or permission blocked this request."
            case 429: text = "Too many requests. Wait a moment and try again."
            case 500...: text = "ChatGPT is temporarily unavailable. Try again shortly."
            default: text = "ChatGPT couldn't complete this request."
            }
        }
        return ChatGPTFailure(text, code: code, status: status)
    }

    static func message(forCode code: String) -> String {
        switch code.replacingOccurrences(of: "_v2_", with: "_") {
        case "subscription_sharing_usage_limit_exceeded":
            "You've reached a usage limit for Redraft on your ChatGPT plan. Check your usage and app limits in ChatGPT settings."
        case "subscription_sharing_user_not_eligible":
            "This ChatGPT account or workspace can't share its plan with apps."
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            "ChatGPT couldn't check your plan right now. Try again shortly."
        case "subscription_sharing_unsupported_capability", "subscription_sharing_route_not_supported":
            "ChatGPT plan usage doesn't support this kind of request."
        case "subscription_sharing_invalid_user", "chatpass_scope_not_authorized", "chatpass_invalid_authorization_context":
            "The ChatGPT connection doesn't have permission for this. Try signing in again."
        case "subscription_sharing_client_not_enabled":
            "ChatGPT plan usage isn't enabled for this app."
        case "model_not_found":
            "That model isn't available on your ChatGPT plan. Pick another in Settings."
        case "invalid_token", "invalid_api_key":
            "ChatGPT didn't accept the saved connection. Try signing in again."
        case "invalid_client":
            "ChatGPT rejected Redraft's registration. Disconnect and sign in again."
        default:
            ""
        }
    }
}

struct ChatGPTFailure: LocalizedError {
    let message: String
    var code: String?
    var status: Int?
    var signInAgain = false

    init(_ message: String, code: String? = nil, status: Int? = nil, signInAgain: Bool = false) {
        self.message = message
        self.code = code
        self.status = status
        self.signInAgain = signInAgain
    }

    var errorDescription: String? { message }
}

// MARK: - ID token verification

/// Verifies an OpenID Connect ID token's RS256 signature against OpenAI's
/// published keys, then checks issuer, audience, expiry and nonce.
enum IDToken {
    struct Identity {
        let subject: String
        let email: String?
        let name: String?
    }

    static func verify(_ token: String, clientId: String, nonce: String?, discovery: ChatGPTAuth.Discovery) async throws -> Identity {
        let invalid = ChatGPTFailure("Couldn't verify your ChatGPT identity. Please sign in again.")
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = Data(base64URLEncoded: parts[0]),
              let payloadData = Data(base64URLEncoded: parts[1]),
              let signature = Data(base64URLEncoded: parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              header["alg"] as? String == "RS256" else { throw invalid }

        let (jwksData, response) = try await URLSession.shared.data(from: discovery.jwksURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let jwks = try? JSONSerialization.jsonObject(with: jwksData) as? [String: Any],
              let keys = jwks["keys"] as? [[String: Any]] else {
            throw ChatGPTFailure("ChatGPT identity verification is temporarily unavailable. Try again shortly.")
        }
        let kid = header["kid"] as? String
        let candidates = keys.filter { $0["kty"] as? String == "RSA" && (kid == nil || $0["kid"] as? String == kid) }
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        let verified = candidates.contains { jwk in
            guard let n = (jwk["n"] as? String).flatMap(Data.init(base64URLEncoded:)),
                  let e = (jwk["e"] as? String).flatMap(Data.init(base64URLEncoded:)),
                  let key = rsaPublicKey(modulus: n, exponent: e) else { return false }
            return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil)
        }
        guard verified else { throw invalid }

        let now = Date().timeIntervalSince1970
        let audience: [String] = (claims["aud"] as? [String]) ?? ((claims["aud"] as? String).map { [$0] } ?? [])
        guard claims["iss"] as? String == discovery.issuer,
              audience.contains(clientId),
              audience.count == 1 || claims["azp"] as? String == clientId,
              (claims["azp"] as? String).map({ $0 == clientId }) ?? true,
              let exp = (claims["exp"] as? NSNumber)?.doubleValue, exp + 5 > now,
              let sub = claims["sub"] as? String, !sub.isEmpty else { throw invalid }
        if let nonce, claims["nonce"] as? String != nonce { throw invalid }
        return Identity(subject: sub, email: claims["email"] as? String, name: claims["name"] as? String)
    }

    /// Builds a SecKey from a JWK's modulus and exponent (PKCS#1 RSAPublicKey DER).
    private static func rsaPublicKey(modulus: Data, exponent: Data) -> SecKey? {
        func length(_ n: Int) -> [UInt8] {
            if n < 0x80 { return [UInt8(n)] }
            var bytes: [UInt8] = []
            var v = n
            while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        func integer(_ data: Data) -> [UInt8] {
            var bytes = Array(data.drop(while: { $0 == 0 }))
            if bytes.isEmpty { bytes = [0] }
            if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return [0x02] + length(bytes.count) + bytes
        }
        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30] + length(body.count) + body)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }
}

// MARK: - Loopback redirect listener

/// A one-shot HTTP listener on 127.0.0.1 that receives the OAuth redirect.
final class LoopbackServer: @unchecked Sendable {
    struct Callback {
        let code: String?
        let clientId: String?
        let error: String?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "Redraft.loopback")
    private var port: UInt16 = 0
    private var expectedState = ""
    private var continuation: CheckedContinuation<Callback, Error>?
    private var finished = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    self.port = self.listener.port?.rawValue ?? 0
                    ready.resume(returning: self.port)
                case .failed(let error):
                    resumed = true
                    ready.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    func waitForCallback(state: String) async throws -> Callback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.expectedState = state
                    self.continuation = continuation
                    self.queue.asyncAfter(deadline: .now() + 300) {
                        self.finish(.failure(ChatGPTFailure("Sign-in timed out. Please try again.")))
                    }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    func stop() {
        listener.cancel()
    }

    private func finish(_ result: Result<Callback, Error>) {
        guard !finished, let continuation else { return }
        finished = true
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let lines = request.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ") ?? []
            let host = lines.first { $0.lowercased().hasPrefix("host:") }?
                .dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard parts.count >= 2, parts[0] == "GET", host == "127.0.0.1:\(self.port)",
                  let url = URLComponents(string: "http://127.0.0.1:\(self.port)\(parts[1])"),
                  url.path == "/auth/callback", !self.finished else {
                self.reply(connection, status: "404 Not Found", body: "Not found")
                return
            }
            let items = url.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            let states = items.filter { $0.name == "state" }
            guard states.count == 1, states[0].value == self.expectedState else {
                self.reply(connection, status: "400 Bad Request", body: "This sign-in link has expired. Return to Redraft and try again.")
                return
            }
            self.reply(connection, status: "200 OK", body: Self.page)
            self.finish(.success(Callback(code: value("code"), clientId: value("client_id"), error: value("error"))))
        }
    }

    private func reply(_ connection: NWConnection, status: String, body: String) {
        let isHTML = body.hasPrefix("<!doctype")
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: \(isHTML ? "text/html" : "text/plain"); charset=utf-8\r
        Cache-Control: no-store\r
        Referrer-Policy: no-referrer\r
        Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r
        Connection: close\r
        Content-Length: \(Data(body.utf8).count)\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static let page = """
    <!doctype html><html lang="en"><meta charset="utf-8"><title>Back to Redraft</title>\
    <style>body{font:17px ui-serif,Georgia,serif;max-width:30rem;margin:20vh auto;padding:24px;color:#2B2A26;background:#F8F6F1}\
    h1{font-size:26px;font-weight:600}@media(prefers-color-scheme:dark){body{color:#E0DCD3;background:#1B1A18}}</style>\
    <h1>You're connected.</h1><p>Head back to Redraft. You can close this tab.</p></html>
    """
}

// MARK: - Helpers

/// One Keychain item holding arbitrary data.
struct KeychainData {
    let account: String
    private let service = "com.brettsmith.Redraft"

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    func write(_ data: Data) {
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    func delete() {
        SecItemDelete(base as CFDictionary)
    }
}

extension Data {
    init?(base64URLEncoded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }

    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
