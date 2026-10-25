import CryptoKit
import Foundation
import Security
import Testing
@testable import OmiKit

/// iPhone から直接使う Sign in with ChatGPT。OpenAI の代わりに、この中の偽物のサーバ (URLProtocol) と話す。
@Suite(.serialized) struct ChatGPTDirectTests {
    final class MemoryStore: ChatGPTCredentialStore, @unchecked Sendable {
        private let lock = NSLock()
        private var value: ChatGPTCredentials?
        func load() -> ChatGPTCredentials? { lock.withLock { value } }
        func save(_ credentials: ChatGPTCredentials) { lock.withLock { value = credentials } }
    }

    /// 偽物の auth.openai.com / api.openai.com
    final class FakeOpenAI: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, [String: String], [Data]))?
        nonisolated(unsafe) static var requests: [(URLRequest, Data)] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    body.append(buf, count: n)
                }
                stream.close()
            }
            Self.requests.append((request, body))
            let (status, headers, chunks) = Self.handler!(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for c in chunks { client?.urlProtocol(self, didLoad: c) }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    let privateKey: SecKey
    let n: Data
    let e: Data

    init() throws {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, nil)!
        let der = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data
        (n, e) = Self.parseRSAPublic(der)
    }

    /// PKCS#1 RSAPublicKey (SEQUENCE { INTEGER n, INTEGER e }) を読む
    static func parseRSAPublic(_ der: Data) -> (Data, Data) {
        let b = [UInt8](der)
        var i = 0
        func readLength() -> Int {
            let first = Int(b[i]); i += 1
            guard first & 0x80 != 0 else { return first }
            var len = 0
            for _ in 0..<(first & 0x7f) { len = len << 8 | Int(b[i]); i += 1 }
            return len
        }
        i += 1; _ = readLength()  // SEQUENCE
        i += 1; let nl = readLength(); let n = Data(b[i..<(i + nl)]); i += nl
        i += 1; let el = readLength(); let e = Data(b[i..<(i + el)])
        return (n, e)
    }

    func idToken(sub: String = "user-1", aud: String = "oaiapp_test", nonce: String?, exp: Double = 4_000_000_000) -> String {
        func b64(_ d: Data) -> String { ChatGPTDirect.base64URL(d) }
        var claims: [String: Any] = ["iss": "https://auth.openai.com", "sub": sub, "aud": aud, "exp": exp, "email": "me@example.com"]
        if let nonce { claims["nonce"] = nonce }
        let head = b64(try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "k1", "typ": "JWT"]))
        let body = b64(try! JSONSerialization.data(withJSONObject: claims))
        let sig = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data("\(head).\(body)".utf8) as CFData, nil)! as Data
        return "\(head).\(body).\(b64(sig))"
    }

    static func json(_ object: Any, status: Int = 200) -> (Int, [String: String], [Data]) {
        (status, ["Content-Type": "application/json"], [try! JSONSerialization.data(withJSONObject: object)])
    }

    static func form(_ body: Data) -> [String: String] {
        Dictionary(String(decoding: body, as: UTF8.self).split(separator: "&").map { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            return (kv[0], kv.count > 1 ? kv[1] : "")
        }, uniquingKeysWith: { a, _ in a })
    }

    func makeClient(store: MemoryStore, clock: @escaping @Sendable () -> Date = Date.init) -> ChatGPTDirect {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeOpenAI.self]
        return ChatGPTDirect(store: store, session: URLSession(configuration: config), now: clock)
    }

    /// 認可 → コードの交換 → ID トークンの確認 → 使う → 更新 → 解除 まで
    @Test func signInRefreshRespondAndSignOut() async throws {
        let store = MemoryStore()
        let client = makeClient(store: store)
        nonisolated(unsafe) var refreshCount = 0
        nonisolated(unsafe) var nonce = ""
        let (n, e) = (self.n, self.e)
        let token = { (nonce: String?) in self.idToken(nonce: nonce) }
        FakeOpenAI.requests = []
        FakeOpenAI.handler = { req, body in
            switch req.url!.path {
            case "/.well-known/openid-configuration":
                return Self.json(["issuer": "https://auth.openai.com", "jwks_uri": "https://auth.openai.com/jwks",
                                  "revocation_endpoint": "https://auth.openai.com/oauth/revoke"])
            case "/jwks":
                return Self.json(["keys": [["kty": "RSA", "kid": "k1", "alg": "RS256",
                                            "n": ChatGPTDirect.base64URL(n), "e": ChatGPTDirect.base64URL(e)]]])
            case "/api/accounts/oauth/token":
                let f = Self.form(body)
                if f["grant_type"] == "authorization_code" {
                    #expect(f["code"] == "c1" && f["client_id"] == "oaiapp_test" && f["code_verifier"]?.isEmpty == false)
                    #expect(f["resource"] == "https://api.openai.com/v1" && f["redirect_uri"] == "http://127.0.0.1:1455/auth/callback")
                    return Self.json(["access_token": "at1", "refresh_token": "rt1", "id_token": token(nonce),
                                      "expires_in": 3600, "scope": ChatGPTEndpoints.scopes])
                }
                refreshCount += 1
                #expect(f["grant_type"] == "refresh_token" && f["refresh_token"] == "rt1")
                return Self.json(["access_token": "at2", "refresh_token": "rt2", "expires_in": 3600, "scope": ChatGPTEndpoints.scopes])
            case "/v1/models":
                return Self.json(["models": [["slug": "gpt-test", "display_name": "GPT Test"], ["slug": "hidden", "visibility": "hide"]]])
            case "/v1/responses":
                #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer at2")
                let payload = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
                #expect(payload["store"] as? Bool == false && payload["stream"] as? Bool == true)
                let events = [
                    #"{"type":"response.created"}"#,
                    #"{"type":"response.output_text.delta","delta":"<<<NOTE>>>\n# 今日"}"#,
                    #"{"type":"response.output_text.delta","delta":"\n<<<TODO>>>\n# やること\n<<<END>>>"}"#,
                    #"{"type":"response.completed","response":{}}"#,
                ].map { Data("event: x\ndata: \($0)\n\n".utf8) }
                return (200, ["Content-Type": "text/event-stream"], events)
            case "/oauth/revoke":
                #expect(Self.form(body)["token"] == "rt2")
                return (200, [:], [])
            default:
                return Self.json(["error": "not found"], status: 404)
            }
        }

        // 1. 許可の画面の URL (はじめての登録)
        let login = await client.startLogin(redirectURI: "http://127.0.0.1:1455/auth/callback")
        let items = Dictionary(URLComponents(url: login.authorizeURL, resolvingAgainstBaseURL: false)!.queryItems!
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        #expect(login.authorizeURL.host() == "auth.openai.com" && login.authorizeURL.path() == "/api/accounts/authorize")
        #expect(items["client_id"] == "dynamic_agent_client" && items["agent_name_hint"] == "Omimi")
        #expect(items["code_challenge_method"] == "S256" && items["scope"] == ChatGPTEndpoints.scopes)
        #expect(items["ext_agent_host_id"]?.hasPrefix("urn:uuid:") == true && items["resource"] == "https://api.openai.com/v1")
        nonce = items["nonce"]!
        let state = items["state"]!

        // 違う state は受け付けない
        await #expect(throws: ChatGPTError.self) {
            _ = try await client.complete(callback: URL(string: "http://127.0.0.1:1455/auth/callback?code=c1&state=x")!)
        }
        // 2. 戻り (発行された client_id 付き)
        let cred = try await client.complete(callback: URL(string:
            "http://127.0.0.1:1455/auth/callback?code=c1&state=\(state)&client_id=oaiapp_test")!)
        #expect(cred.connected && cred.planUsage && cred.email == "me@example.com" && cred.subject == "user-1")
        #expect(cred.clientId == "oaiapp_test" && cred.refreshToken == "rt1" && !cred.welcomed)
        #expect(try await client.accessToken() == "at1")

        // 3. 期限が近づいたら更新 (更新トークンは入れ替わる)
        var c = store.load()!
        c.expiresAt = Date().addingTimeInterval(30)
        store.save(c)
        #expect(try await client.models() == [ChatGPTModel(slug: "gpt-test", displayName: "GPT Test")])
        #expect(refreshCount == 1 && store.load()?.refreshToken == "rt2")

        // 4. Responses API (ストリーム)
        let out = try await client.respond(model: "gpt-test", instructions: "指示", text: "添付")
        #expect(AINotes.parse(out).note == "# 今日\n" && AINotes.parse(out).todo == "# やること\n")

        // 5. 2 回目のサインインは登録済みの client_id で
        let again = await client.startLogin(redirectURI: "http://127.0.0.1:1455/auth/callback")
        #expect(again.authorizeURL.absoluteString.contains("client_id=oaiapp_test"))
        #expect(again.authorizeURL.absoluteString.contains("login_hint=me%40example.com"))
        await client.cancelLogin()

        // 6. 解除: 更新トークンを取り消し、トークンは消す。登録とホスト ID は残す
        #expect(await client.signOut())
        let after = store.load()!
        #expect(!after.connected && after.refreshToken == nil && after.clientId == "oaiapp_test" && after.hostId == cred.hostId)
    }

    @Test func idTokenChecks() async throws {
        let store = MemoryStore()
        let client = makeClient(store: store)
        let (n, e) = (self.n, self.e)
        FakeOpenAI.handler = { req, _ in
            switch req.url!.path {
            case "/.well-known/openid-configuration":
                return Self.json(["issuer": "https://auth.openai.com", "jwks_uri": "https://auth.openai.com/jwks"])
            default:
                return Self.json(["keys": [["kty": "RSA", "kid": "k1", "n": ChatGPTDirect.base64URL(n), "e": ChatGPTDirect.base64URL(e)]]])
            }
        }
        #expect(try await client.verifyIDToken(idToken(nonce: "x"), clientId: "oaiapp_test", nonce: "x").sub == "user-1")
        await #expect(throws: ChatGPTError.self) { _ = try await client.verifyIDToken(idToken(nonce: "x"), clientId: "other", nonce: "x") }
        await #expect(throws: ChatGPTError.self) { _ = try await client.verifyIDToken(idToken(nonce: "y"), clientId: "oaiapp_test", nonce: "x") }
        await #expect(throws: ChatGPTError.self) {
            _ = try await client.verifyIDToken(idToken(nonce: nil, exp: 1000), clientId: "oaiapp_test", nonce: nil)
        }
        // 署名を書き換えたもの
        var parts = idToken(nonce: nil).split(separator: ".").map(String.init)
        parts[1] = ChatGPTDirect.base64URL(Data(#"{"iss":"https://auth.openai.com","sub":"evil","aud":"oaiapp_test","exp":4000000000}"#.utf8))
        await #expect(throws: ChatGPTError.self) {
            _ = try await client.verifyIDToken(parts.joined(separator: "."), clientId: "oaiapp_test", nonce: nil)
        }
    }

    @Test func errorsAndTerminalRefresh() async throws {
        let store = MemoryStore()
        var c = ChatGPTCredentials()
        c.clientId = "oaiapp_test"
        c.accessToken = "at"
        c.refreshToken = "rt"
        c.expiresAt = Date().addingTimeInterval(3600)
        c.scopes = [ChatGPTEndpoints.planScope]
        store.save(c)
        let client = makeClient(store: store)
        FakeOpenAI.handler = { req, _ in
            if req.url!.path == "/v1/responses" {
                return Self.json(["error": ["code": "subscription_sharing_usage_limit_exceeded", "message": "limit"]], status: 429)
            }
            return Self.json(["error": "invalid_grant"], status: 400)
        }
        do {
            _ = try await client.respond(model: "m", instructions: "i", text: "t")
            Issue.record("should fail")
        } catch let e as ChatGPTError {
            #expect(e.code == "subscription_sharing_usage_limit_exceeded" && e.message.contains("使用量"))
        }
        // 更新トークンが使えなくなったら、接続し直しを求める (トークンは消すが登録は残す)
        do {
            _ = try await client.refresh()
            Issue.record("should fail")
        } catch let e as ChatGPTError {
            #expect(e.reconnect)
        }
        #expect(store.load()?.connected == false && store.load()?.clientId == "oaiapp_test")
        // プランの利用を許可していない接続
        var noPlan = ChatGPTCredentials()
        noPlan.accessToken = "x"
        store.save(noPlan)
        await #expect(throws: ChatGPTError.self) { _ = try await client.accessToken() }
    }
}

@Suite struct AINotesTests {
    @Test func promptAndOutput() {
        #expect(AINotes.dayTitle("2026-10-13") == "10月13日 (火)")
        // 1 日のまとめ: その日のまとめ + やること。前の日のまとめを添付
        let daily = AIPrompts.builtIn(AIPrompts.dailyID)!
        let r = AIPrompts.request(prompt: daily, day: "2026-10-13", range: nil, timeline: "# 会話\n", vocabulary: "# 用語集\n",
                                  previous: ("2026-10-12.md", "# 12日\n"), todo: nil)
        #expect(r.noteName == "2026-10-13.md" && r.updatesTodo)
        #expect(r.instructions.hasPrefix("# 10月13日 (火) のまとめ (終日)") && r.instructions.contains("`notes/2026-10-12.md`"))
        #expect(r.instructions.contains("(notes/2026-10-13.md の全文)") && r.instructions.contains("<<<TODO>>>"))
        #expect(!r.instructions.contains("{{"))
        for name in ["guide.md", "vocabulary.md", "timeline/2026-10-13.md", "notes/2026-10-12.md", "notes/todo.md"] {
            #expect(r.materials.contains("<file path=\"\(name)\">"), "\(name)")
        }
        // 会議の議事録: 時間帯つきの別のノート。やることは書き換えない
        let meeting = AIPrompts.builtIn(AIPrompts.meetingID)!
        let range = TimeRange(start: 10 * 60, end: 11 * 60 + 30)
        let m = AIPrompts.request(prompt: meeting, day: "2026-10-13", range: range, timeline: "# 会話\n", vocabulary: nil,
                                  previous: ("2026-10-12.md", "# 12日\n"), todo: "# やること\n")
        #expect(m.noteName == "2026-10-13 10:00〜11:30 会議の議事録.md" && !m.updatesTodo)
        #expect(m.instructions.contains("10月13日 (火) 10:00〜11:30") && !m.instructions.contains("<<<TODO>>>"))
        #expect(m.materials.contains("<file path=\"timeline/2026-10-13 10.00-11.30.md\">"))
        #expect(!m.materials.contains("<file path=\"notes/todo.md\">") && !m.materials.contains("<file path=\"notes/2026-10-12.md\">"))
        #expect(TimeRange(start: 600, end: 540).isValid == false && range.label == "10:00〜11:30")
        let fenced = "前置き\n<<<NOTE>>>\n```markdown\n# まとめ\n```\n<<<TODO>>>\n# やること\n- [ ] a\n<<<END>>>\n後書き"
        #expect(AINotes.parse(fenced).note == "# まとめ\n" && AINotes.parse(fenced).todo == "# やること\n- [ ] a\n")
        #expect(AINotes.parse("<<<NOTE>>>\n# だけ\n<<<END>>>").todo == nil)
        #expect(AINotes.parse("形式なし").note == nil)
        let mat = AINotes.materials([("guide.md", "a\n\n"), ("timeline/x.md", String(repeating: "あ", count: AINotes.maxTimelineChars + 5))])
        #expect(mat.hasPrefix("<file path=\"guide.md\">\na\n</file>") && mat.contains("(長いので、ここから後ろは省きました)"))
        let v = AINotes.vocabularyMarkdown([VocabularyEntry(id: 1, term: "下河内", reading: "しもがうち", aliases: ["下川内"], note: "a|b")])!
        #expect(v.contains("| 下河内 | しもがうち | 下川内 | a\\|b |"))
        #expect(AINotes.vocabularyMarkdown([]) == nil)
    }

    @Test func summarizeLikeServer() {
        let (title, summary) = NoteSummarizer.summarize("# 10月13日 (火)\n\n> 打ち合わせの日。\n> 午後は**倉庫**の話。\n\n## 話したこと\n- a")
        #expect(title == "10月13日 (火)" && summary == "打ち合わせの日。 午後は倉庫の話。")
        #expect(NoteSummarizer.summarize("# t\n\n- list\n\n本文の[リンク](omimi://x)です").summary == "本文のリンクです")
    }

    @Test func timelineFromPhoneRecordings() throws {
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        var a = SegmentMetadata(id: "s1", codec: .opusFS320, sampleRate: 16_000, startedAt: Date(timeIntervalSince1970: 1_791_850_000))
        a.state = .closed
        a.durationSeconds = 65
        a.transcriptionState = .done
        a.transcript = Transcript(engine: "apple", locale: "ja-JP", pieces: [
            TranscriptPiece(start: 0, end: 2, text: "下川内さんおはよう", language: "ja", speaker: "自分", speakerId: 1),
            TranscriptPiece(start: 3, end: 5, text: "おはよう", speaker: otherSpeakerName),
        ])
        var silent = SegmentMetadata(id: "s2", codec: .opusFS320, sampleRate: 16_000, startedAt: a.startedAt.addingTimeInterval(600))
        silent.state = .closed
        silent.transcriptionState = .done
        silent.transcript = Transcript(engine: "apple", locale: "ja-JP", pieces: [])
        let marker = Marker(kind: .highlight, at: a.startedAt.addingTimeInterval(4), deviceId: nil)
        let corrector = VocabularyCorrector([VocabularyEntry(id: 1, term: "下河内", aliases: ["下川内"])])
        let md = try #require(AINotes.timeline(day: "2026-10-13", timeZone: tz, segments: [a, silent], markers: [marker], corrector: corrector))
        #expect(md.hasPrefix("# 2026-10-13 (火) のライフログ\n\n- 録音: 話し声あり 1 件 / 話し声なし 1 件 (省略)"))
        #expect(md.contains("- 話者: 自分 (2秒), その他 (2秒)") || md.contains("- 話者: その他 (2秒), 自分 (2秒)"))
        #expect(md.contains("- 印: ⭐ 注目 1") && md.contains("- タイムゾーン: +0900"))
        #expect(md.contains("<!-- segment: s1 source: device -->"))
        #expect(md.contains("**自分** (ja): 下河内さんおはよう") && md.contains("⭐ **注目** (ここは大事)"))
        #expect(!md.contains("s2"))
        #expect(AINotes.timeline(day: "2026-10-14", timeZone: tz, segments: [a], markers: [], corrector: corrector) == nil)
    }

    /// 指示は書き換えて保存し、複製・削除・元に戻すができる
    @Test func promptStore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prompts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AIPromptStore(url: url)
        #expect(store.all().map(\.id) == AIPrompts.builtIns.map(\.id))
        var daily = try #require(store.get(AIPrompts.dailyID))
        daily.body = "短く書いて"
        store.save(daily)
        let copy = try #require(store.duplicate(AIPrompts.meetingID))
        #expect(copy.name == "会議の議事録 のコピー" && copy.builtIn == nil && copy.defaultRange == TimeRange(start: 600, end: 660))
        store.delete(AIPrompts.diaryID)
        let reopened = AIPromptStore(url: url)
        #expect(reopened.get(AIPrompts.dailyID)?.body == "短く書いて" && reopened.get(AIPrompts.diaryID) == nil)
        #expect(reopened.all().count == 4)
        reopened.restore(AIPrompts.dailyID)
        reopened.restore(AIPrompts.diaryID)
        #expect(reopened.get(AIPrompts.dailyID)?.body == AIPrompts.builtIn(AIPrompts.dailyID)?.body && reopened.all().count == 5)
        reopened.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        #expect(AIPromptStore(url: url).all().first?.id == AIPrompts.diaryID)
    }

    /// 時間帯を指定すると、その間の発話と印だけを添付する
    @Test func timelineForTimeRange() throws {
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        // 2026-10-13 09:06:40 (日本時間) から 1 時間の録音
        var a = SegmentMetadata(id: "s1", codec: .opusFS320, sampleRate: 16_000, startedAt: Date(timeIntervalSince1970: 1_791_850_000))
        a.state = .closed
        a.durationSeconds = 3600
        a.transcriptionState = .done
        a.transcript = Transcript(engine: "apple", locale: "ja-JP", pieces: [
            TranscriptPiece(start: 60, end: 62, text: "九時台", speaker: "自分"),
            TranscriptPiece(start: 1800, end: 1802, text: "九時半すぎ", speaker: "自分"),
        ])
        let markers = [Marker(kind: .memo, at: a.startedAt.addingTimeInterval(100)), Marker(kind: .highlight, at: a.startedAt.addingTimeInterval(1900))]
        let md = try #require(AINotes.timeline(day: "2026-10-13", timeZone: tz, segments: [a], markers: markers,
                                               corrector: VocabularyCorrector([]), range: TimeRange(start: 9 * 60 + 30, end: 10 * 60)))
        #expect(md.hasPrefix("# 2026-10-13 (火) 9:30〜10:00 のライフログ") && md.contains("- 時間帯: 9:30〜10:00"))
        #expect(md.contains("九時半すぎ") && !md.contains("九時台") && md.contains("⭐ **注目**") && !md.contains("📝"))
        #expect(AINotes.timeline(day: "2026-10-13", timeZone: tz, segments: [a], markers: [], corrector: VocabularyCorrector([]),
                                 range: TimeRange(start: 12 * 60, end: 13 * 60)) == nil)
    }
}
