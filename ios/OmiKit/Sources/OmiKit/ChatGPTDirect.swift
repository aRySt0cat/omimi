import CryptoKit
import Foundation
import Security

/// Sign in with ChatGPT を iPhone から直接使う (自宅サーバの chatgpt.py と同じ手順)。
/// https://developers.openai.com/siwc/token-sharing-open-source
/// - 認可: https://auth.openai.com/api/accounts/authorize (PKCE S256。戻り先はこの iPhone の 127.0.0.1)
/// - トークン: https://auth.openai.com/api/accounts/oauth/token (authorization_code / refresh_token)
/// - 推論: https://api.openai.com/v1/responses (store=false, stream=true)
/// この iPhone を 1 つのホスト (ext_agent_host_id) として登録する。トークンは Keychain (この端末だけ) に置く。
public enum ChatGPTEndpoints {
    public static let auth = URL(string: "https://auth.openai.com")!
    public static let authorize = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    public static let token = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    public static let oidcConfig = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    public static let api = URL(string: "https://api.openai.com/v1")!
    public static let usage = URL(string: "https://chatgpt.com/settings/usage")!
    public static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    public static let planScope = "chatgpt.tokens.use.direct"
    public static let registrationClient = "dynamic_agent_client"
    public static let appName = "Omimi"
}

/// 接続の情報 (この iPhone の Keychain に保存する)
public struct ChatGPTCredentials: Codable, Equatable, Sendable {
    /// この iPhone のホスト ID (最初のサインインの前に決めて、ずっと同じものを使う)
    public var hostId: String
    /// 登録で発行された client_id (oaiapp_...)。接続を解除しても残す
    public var clientId: String?
    public var accessToken: String?
    public var refreshToken: String?
    public var idToken: String?
    public var expiresAt: Date?
    public var scopes: [String]
    public var subject: String?
    public var email: String?
    /// はじめての案内を見たか
    public var welcomed: Bool

    public init(hostId: String = "urn:uuid:\(UUID().uuidString.lowercased())") {
        self.hostId = hostId
        scopes = []
        welcomed = false
    }

    public var connected: Bool { accessToken != nil }
    public var planUsage: Bool { scopes.contains(ChatGPTEndpoints.planScope) }

    mutating func clearTokens() {
        accessToken = nil
        refreshToken = nil
        idToken = nil
        expiresAt = nil
        scopes = []
        welcomed = false
    }
}

public protocol ChatGPTCredentialStore: Sendable {
    func load() -> ChatGPTCredentials?
    func save(_ credentials: ChatGPTCredentials)
}

public struct ChatGPTError: Error, LocalizedError, Equatable, Sendable {
    public var message: String
    public var code: String?
    public var status: Int?
    /// 接続し直す必要がある
    public var reconnect: Bool

    public init(_ message: String, code: String? = nil, status: Int? = nil, reconnect: Bool = false) {
        self.message = message
        self.code = code
        self.status = status
        self.reconnect = reconnect
    }

    public var errorDescription: String? { message }

    /// 公式の「Errors and recovery」のコードと、そのときの案内 (自宅サーバと同じ)
    static let messages: [String: String] = [
        "subscription_sharing_usage_limit_exceeded": "ChatGPT プランの使用量の上限に達しました。ChatGPT の設定 → 使用量 で確かめてください。",
        "subscription_sharing_user_not_eligible": "このアカウントでは ChatGPT プランを使えません (Plus または Pro が必要です)。",
        "subscription_sharing_usage_unavailable": "ChatGPT プランが一時的に使えません。少し待ってからもう一度試してください。",
        "subscription_sharing_user_unavailable": "ChatGPT プランが一時的に使えません。少し待ってからもう一度試してください。",
        "subscription_sharing_unsupported_capability": "選んだモデルか機能は ChatGPT プランでは使えません。別のモデルを選んでください。",
        "subscription_sharing_route_not_supported": "ChatGPT プランでは使えない呼び出しです。",
        "subscription_sharing_invalid_user": "ChatGPT の接続が使えなくなりました。もう一度「ChatGPT で続ける」から接続してください。",
    ]
    static let terminalRefresh: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                                               "refresh_token_invalidated", "refresh_token_reused"]

    static func from(status: Int, body: Data, fallback: String) -> ChatGPTError {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        let code = error?["code"] as? String ?? (json?["error"] as? String)
        if let code, let message = messages[code] {
            var m = message
            if code == "subscription_sharing_unsupported_capability", let param = error?["param"] as? String { m += " (\(param))" }
            return ChatGPTError(m, code: code, status: status, reconnect: code == "subscription_sharing_invalid_user")
        }
        switch status {
        case 401: return ChatGPTError("ChatGPT が接続を受け付けませんでした。「ChatGPT で続ける」から接続し直してください",
                                      code: code, status: status, reconnect: true)
        case 403: return ChatGPTError("ChatGPT プランでのこの呼び出しは許可されていません (地域などの制限)", code: code, status: status)
        case 429, 503: return ChatGPTError("ChatGPT が混み合っています。少し待ってからもう一度試してください", code: code, status: status)
        default:
            let detail = (error?["message"] as? String).map { ": " + String($0.prefix(200)) } ?? ""
            return ChatGPTError("\(fallback) (\(code ?? String(status))\(detail))", code: code, status: status)
        }
    }
}

/// サインインの途中 (許可の画面を出してから、戻ってくるまで)
public struct ChatGPTPendingLogin: Sendable {
    public var authorizeURL: URL
    public var redirectURI: String
    var state: String
    var nonce: String
    var verifier: String
    var clientId: String?
    var subject: String?
    var created: Date
}

public actor ChatGPTDirect {
    static let refreshMargin: TimeInterval = 120
    static let loginTimeout: TimeInterval = 600

    private let store: ChatGPTCredentialStore
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var pending: ChatGPTPendingLogin?
    private var oidc: [String: Any]?
    private var jwks: [[String: Any]]?
    private var refreshing: Task<String, Error>?

    public init(store: ChatGPTCredentialStore, session: URLSession? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 120
            config.httpCookieStorage = nil
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    public var credentials: ChatGPTCredentials {
        if let c = store.load() { return c }
        let c = ChatGPTCredentials()
        store.save(c)
        return c
    }

    public func markWelcomed() {
        var c = credentials
        c.welcomed = true
        store.save(c)
    }

    // MARK: - サインイン

    /// 許可の画面の URL を作る (戻り先 redirectURI で待ち受けてから呼ぶ)
    public func startLogin(redirectURI: String) -> ChatGPTPendingLogin {
        let cred = credentials
        let issued = cred.clientId
        let verifier = Self.randomURLSafe(32)
        let state = Self.randomURLSafe(32), nonce = Self.randomURLSafe(32)
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: issued ?? ChatGPTEndpoints.registrationClient),
            .init(name: "ext_agent_host_id", value: cred.hostId),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: ChatGPTEndpoints.scopes),
            .init(name: "resource", value: ChatGPTEndpoints.api.absoluteString),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
        ]
        if issued != nil {
            // 2 回目からは、登録済みの client_id で同じアカウントにサインインし直す
            if let hint = cred.idToken { items.append(.init(name: "id_token_hint", value: hint)) }
            if let email = cred.email { items.append(.init(name: "login_hint", value: email)) }
        } else {
            items.append(.init(name: "agent_name_hint", value: ChatGPTEndpoints.appName))
        }
        var comps = URLComponents(url: ChatGPTEndpoints.authorize, resolvingAgainstBaseURL: false)!
        // + や : をそのまま送らないよう、値は厳しめにエンコードする
        comps.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed))
        }
        let login = ChatGPTPendingLogin(authorizeURL: comps.url!, redirectURI: redirectURI, state: state, nonce: nonce,
                                        verifier: verifier, clientId: issued, subject: issued != nil ? cred.subject : nil,
                                        created: now())
        pending = login
        return login
    }

    /// 戻ってきたアドレス (code・state を含む) から、サインインを完了する
    public func complete(callback: URL) async throws -> ChatGPTCredentials {
        guard let p = pending, now().timeIntervalSince(p.created) < Self.loginTimeout else {
            throw ChatGPTError("サインインの受付が終わっています。もう一度「ChatGPT で続ける」を押してください")
        }
        let query = Dictionary(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?
            .map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        guard let state = query["state"], Self.constantTimeEqual(state, p.state) else {
            throw ChatGPTError("今回のサインインの結果ではありません (state が違います)")
        }
        if let error = query["error"] {
            pending = nil
            if error == "access_denied" { throw ChatGPTError("ChatGPT での許可が取り消されました", code: error) }
            throw ChatGPTError("ChatGPT でのサインインに失敗しました (\(error))", code: error)
        }
        guard let code = query["code"], !code.isEmpty else { throw ChatGPTError("許可の結果に code がありません") }
        var clientId = p.clientId
        let returned = query["client_id"]
        if clientId == nil {
            // はじめての登録: 発行された client_id を受け取り、コードの交換に失敗しても登録をやり直さずに済むよう先に保存する
            guard let returned, !returned.isEmpty, returned != ChatGPTEndpoints.registrationClient else {
                throw ChatGPTError("ChatGPT での登録が完了していません (client_id がありません)")
            }
            clientId = returned
            var c = credentials
            c.clientId = returned
            store.save(c)
        } else if let returned, !returned.isEmpty, returned != clientId {
            throw ChatGPTError("登録済みのものと違う client_id が返ってきました")
        }
        let tokens = try await tokenRequest([
            "grant_type": "authorization_code", "client_id": clientId!, "code": code,
            "code_verifier": p.verifier, "redirect_uri": p.redirectURI, "resource": ChatGPTEndpoints.api.absoluteString,
        ])
        let claims = try await verifyIDToken(tokens["id_token"] as? String ?? "", clientId: clientId!, nonce: p.nonce)
        if let subject = p.subject, claims.sub != subject {
            throw ChatGPTError("前と違う ChatGPT アカウントでサインインしました。前のアカウントを使ってください")
        }
        pending = nil
        return save(tokens, clientId: clientId!, claims: claims)
    }

    public func cancelLogin() {
        pending = nil
    }

    // MARK: - トークン

    public func accessToken() async throws -> String {
        let c = credentials
        guard let token = c.accessToken else {
            throw ChatGPTError("ChatGPT とつながっていません。「ChatGPT で続ける」から接続してください", reconnect: true)
        }
        guard c.planUsage else {
            throw ChatGPTError("ChatGPT プランの利用が許可されていません。もう一度「ChatGPT で続ける」から、プランの利用を許可してください",
                               reconnect: true)
        }
        if let exp = c.expiresAt, exp.timeIntervalSince(now()) > Self.refreshMargin { return token }
        return try await refresh()
    }

    /// 更新トークンは使うたびに変わるので、同時に 2 回更新しない
    public func refresh() async throws -> String {
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.doRefresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func doRefresh() async throws -> String {
        var c = credentials
        guard let refreshToken = c.refreshToken, let clientId = c.clientId else {
            throw ChatGPTError("ChatGPT の接続が切れています。「ChatGPT で続ける」から接続し直してください", reconnect: true)
        }
        let tokens: [String: Any]
        do {
            tokens = try await tokenRequest(["grant_type": "refresh_token", "client_id": clientId,
                                             "refresh_token": refreshToken, "resource": ChatGPTEndpoints.api.absoluteString])
        } catch let e as ChatGPTError where e.reconnect {
            c.clearTokens()
            store.save(c)
            throw ChatGPTError("ChatGPT の接続が切れました。「ChatGPT で続ける」から接続し直してください", code: e.code, reconnect: true)
        }
        var claims: IDClaims?
        if let id = tokens["id_token"] as? String {
            claims = try await verifyIDToken(id, clientId: clientId, nonce: nil)
            if let subject = c.subject, claims?.sub != subject {
                throw ChatGPTError("ChatGPT のアカウントが変わりました。接続し直してください", reconnect: true)
            }
        }
        return save(tokens, clientId: clientId, claims: claims).accessToken!
    }

    @discardableResult
    private func save(_ tokens: [String: Any], clientId: String, claims: IDClaims?) -> ChatGPTCredentials {
        var c = credentials
        c.clientId = clientId
        c.accessToken = tokens["access_token"] as? String
        let expiresIn = (tokens["expires_in"] as? Double) ?? (tokens["expires_in"] as? Int).map(Double.init) ?? 3600
        c.expiresAt = now().addingTimeInterval(expiresIn)
        if let scope = tokens["scope"] as? String {
            c.scopes = scope.split(separator: " ").map(String.init).sorted()
        } else if let scopes = tokens["scopes"] as? [String] {
            c.scopes = scopes.sorted()
        }
        if let r = tokens["refresh_token"] as? String { c.refreshToken = r }
        if let id = tokens["id_token"] as? String { c.idToken = id }
        if let claims {
            c.subject = claims.sub
            c.email = claims.email ?? c.email
        }
        store.save(c)
        return c
    }

    /// 更新トークンを取り消してから、手元のトークンを消す (登録とホスト ID は残す)。取り消せたら true
    public func signOut() async -> Bool {
        var c = credentials
        var revoked = true
        if let refreshToken = c.refreshToken, let clientId = c.clientId {
            revoked = false
            if let endpoint = (try? await oidcConfig())?["revocation_endpoint"] as? String, let url = URL(string: endpoint) {
                var r = URLRequest(url: url)
                r.httpMethod = "POST"
                r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                r.httpBody = Self.form(["token": refreshToken, "token_type_hint": "refresh_token", "client_id": clientId])
                if let (_, response) = try? await session.data(for: r), (response as? HTTPURLResponse)?.statusCode == 200 {
                    revoked = true
                }
            }
        }
        c.clearTokens()
        store.save(c)
        return revoked
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var r = URLRequest(url: ChatGPTEndpoints.token)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = Self.form(form)
        let (data, response) = try await session.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status < 400 else {
            let code = body["error"] as? String ?? (body["error"] as? [String: Any])?["code"] as? String
            if code == "invalid_grant" && form["grant_type"] == "authorization_code" {
                throw ChatGPTError("許可の結果が使えませんでした。もう一度「ChatGPT で続ける」を押してください", code: code, status: status)
            }
            throw ChatGPTError("ChatGPT のトークンを受け取れませんでした (\(code ?? String(status)))", code: code, status: status,
                               reconnect: code.map(ChatGPTError.terminalRefresh.contains) ?? false)
        }
        guard body["access_token"] is String else { throw ChatGPTError("ChatGPT のトークンを受け取れませんでした (応答が不正)") }
        return body
    }

    // MARK: - ID トークンの確認

    private func oidcConfig() async throws -> [String: Any] {
        if let oidc { return oidc }
        let (data, response) = try await session.data(from: ChatGPTEndpoints.oidcConfig)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTError("ChatGPT の設定を読めませんでした")
        }
        oidc = json
        return json
    }

    private func jwk(kid: String?) async throws -> [String: Any] {
        for attempt in 0..<2 {
            if jwks == nil || attempt > 0 {
                guard let uri = try await oidcConfig()["jwks_uri"] as? String, let url = URL(string: uri) else {
                    throw ChatGPTError("ChatGPT の署名の鍵の場所が分かりません")
                }
                let (data, _) = try await session.data(from: url)
                jwks = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["keys"] as? [[String: Any]] ?? []
            }
            if let key = jwks?.first(where: { kid == nil || $0["kid"] as? String == kid }) { return key }
        }
        throw ChatGPTError("ChatGPT の ID トークンの署名を確かめられませんでした (鍵が見つかりません)")
    }

    /// ID トークンで確かめたアカウント
    struct IDClaims: Sendable {
        var sub: String
        var email: String?
    }

    /// 署名 (RS256)・発行元・宛先・期限・nonce を確かめる
    @discardableResult
    func verifyIDToken(_ token: String, clientId: String, nonce: String?) async throws -> IDClaims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = Self.base64URLDecode(parts[0]), let payloadData = Self.base64URLDecode(parts[1]),
              let signature = Self.base64URLDecode(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw ChatGPTError("ChatGPT から受け取った ID トークンを読めませんでした")
        }
        guard header["alg"] as? String == "RS256" else { throw ChatGPTError("ChatGPT の ID トークンの形式が想定と違います") }
        let key = try await jwk(kid: header["kid"] as? String)
        guard let n = (key["n"] as? String).flatMap(Self.base64URLDecode), let e = (key["e"] as? String).flatMap(Self.base64URLDecode),
              Self.verifyRS256(Data("\(parts[0]).\(parts[1])".utf8), signature: signature, modulus: n, exponent: e) else {
            throw ChatGPTError("ChatGPT の ID トークンの署名が正しくありません")
        }
        let issuer = try await oidcConfig()["issuer"] as? String ?? "https://auth.openai.com"
        let audiences = (claims["aud"] as? [String]) ?? [(claims["aud"] as? String) ?? ""]
        guard claims["iss"] as? String == issuer, audiences.contains(clientId) else {
            throw ChatGPTError("ChatGPT の ID トークンの発行元か宛先が違います")
        }
        let exp = (claims["exp"] as? Double) ?? (claims["exp"] as? Int).map(Double.init) ?? 0
        guard exp >= now().timeIntervalSince1970 - 60 else { throw ChatGPTError("ChatGPT の ID トークンの期限が切れています") }
        if let nonce, claims["nonce"] as? String != nonce {
            throw ChatGPTError("ChatGPT の ID トークンが今回のサインインのものではありません")
        }
        guard let sub = claims["sub"] as? String, !sub.isEmpty else { throw ChatGPTError("ChatGPT の ID トークンにアカウントの情報がありません") }
        return IDClaims(sub: sub, email: claims["email"] as? String)
    }

    /// RSA 公開鍵 (n, e) で PKCS#1 v1.5 / SHA-256 の署名を確かめる
    static func verifyRS256(_ message: Data, signature: Data, modulus: Data, exponent: Data) -> Bool {
        let der = DER.sequence([DER.integer(modulus), DER.integer(exponent)])
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                                    kSecAttrKeySizeInBits as String: modulus.drop(while: { $0 == 0 }).count * 8]
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
    }

    // MARK: - モデルと Responses API

    public func models() async throws -> [ChatGPTModel] {
        let token = try await accessToken()
        var r = URLRequest(url: ChatGPTEndpoints.api.appendingPathComponent("models"))
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 400 else { throw ChatGPTError.from(status: status, body: data, fallback: "モデルの一覧を取れませんでした") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let items = (json["models"] as? [[String: Any]]) ?? (json["data"] as? [[String: Any]]) ?? []
        return items.compactMap { m in
            guard (m["visibility"] as? String ?? "list") == "list",
                  let slug = (m["slug"] as? String) ?? (m["id"] as? String) else { return nil }
            return ChatGPTModel(slug: slug, displayName: m["display_name"] as? String ?? slug)
        }
    }

    /// Responses API を呼び、出力の文字列を返す。response.completed まで読んで初めて成功とする
    public func respond(model: String, instructions: String, text: String,
                        onDelta: (@Sendable (Int) -> Void)? = nil) async throws -> String {
        let token = try await accessToken()
        var r = URLRequest(url: ChatGPTEndpoints.api.appendingPathComponent("responses"))
        r.httpMethod = "POST"
        r.timeoutInterval = 300
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let payload: [String: Any] = [
            "model": model, "instructions": instructions, "store": false, "stream": true,
            "input": [["role": "user", "content": [["type": "input_text", "text": text]]]],
        ]
        r.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (bytes, response) = try await session.bytes(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 64_000 { break } }
            throw ChatGPTError.from(status: status, body: body, fallback: "AI に頼めませんでした")
        }
        var out = ""
        var completed = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !data.isEmpty, data != "[DONE]",
                  let event = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "response.output_text.delta":
                out += event["delta"] as? String ?? ""
                onDelta?(out.count)
            case "response.completed":
                completed = true
            case "response.failed":
                let error = (event["response"] as? [String: Any])?["error"] ?? [:]
                throw ChatGPTError.from(status: 200, body: (try? JSONSerialization.data(withJSONObject: ["error": error])) ?? Data(),
                                        fallback: "AI の処理が失敗しました")
            case "response.incomplete":
                let reason = ((event["response"] as? [String: Any])?["incomplete_details"] as? [String: Any])?["reason"] as? String
                throw ChatGPTError("AI の出力が途中で終わりました (\(reason ?? "incomplete"))", code: "incomplete")
            case "error":
                let error = event["error"] ?? event
                throw ChatGPTError.from(status: 200, body: (try? JSONSerialization.data(withJSONObject: ["error": error])) ?? Data(),
                                        fallback: "AI の処理が失敗しました")
            default:
                break
            }
            if completed { break }
        }
        guard completed else { throw ChatGPTError("AI の応答が途中で切れました。もう一度試してください", code: "interrupted") }
        return out
    }

    // MARK: - 小さな道具

    static let queryValueAllowed: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()

    static func form(_ values: [String: String]) -> Data {
        Data(values.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? "")"
        }.joined(separator: "&").utf8)
    }

    static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// RSA 公開鍵 (PKCS#1) を組み立てるための最小限の DER
enum DER {
    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func integer(_ value: Data) -> Data {
        var v = Array(value.drop(while: { $0 == 0 }))
        if v.isEmpty { v = [0] }
        if v[0] & 0x80 != 0 { v.insert(0, at: 0) }
        return Data([0x02] + length(v.count) + v)
    }

    static func sequence(_ items: [Data]) -> Data {
        let body = items.reduce(Data(), +)
        return Data([0x30] + length(body.count)) + body
    }
}
