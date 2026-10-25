import Foundation
import OmiKit
import Security
import UIKit

/// 「AI で整理」の進み具合
struct AIJob: Equatable {
    enum State: Equatable { case idle, running, done, failed }
    var state: State = .idle
    var day: String?
    var range: TimeRange?
    var promptName: String?
    /// 準備しています / AI が書いています / 保存しています
    var phase: String?
    var chars = 0
    var message: String?
    var code: String?
    /// 書いたまとめ
    var noteName: String?
}

/// ChatGPT の接続の情報を、この iPhone の Keychain (バックアップ・iCloud に入らない) に置く
struct ChatGPTKeychain: ChatGPTCredentialStore {
    private static let service = "omimi.chatgpt"

    func load() -> ChatGPTCredentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder.omi.decode(ChatGPTCredentials.self, from: data)
    }

    func save(_ credentials: ChatGPTCredentials) {
        guard let data = try? JSONEncoder.omi.encode(credentials) else { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        // 充電中のバックグラウンドの処理でも読めるよう、初回のロック解除後は読める。この端末だけ
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// 「AI で整理」: この iPhone から ChatGPT (Sign in with ChatGPT) に頼み、まとめを iPhone に保存する
extension AppModel {
    // MARK: - 接続とモデル

    var aiModelSlug: String? {
        aiModelSelected.flatMap { s in aiModels.isEmpty || aiModels.contains { $0.slug == s } ? s : nil } ?? aiModels.first?.slug
    }

    func setAIModel(_ slug: String) {
        Prefs.defaults.set(slug, forKey: "directAIModel")
        aiModelSelected = slug
    }

    func refreshAI() async {
        let cred = await chatGPT.credentials
        aiAccount = cred
        guard cred.connected, aiModels.isEmpty else { return }
        do {
            aiModels = try await chatGPT.models()
        } catch let e as ChatGPTError {
            aiMessage = e.message
            aiAccount = await chatGPT.credentials
        } catch {
            aiMessage = error.localizedDescription
        }
    }

    /// ChatGPT に接続する (許可の戻りは、この iPhone の 127.0.0.1 で受け取る)
    func connectChatGPT() async {
        connectingChatGPT = true
        aiMessage = nil
        defer { connectingChatGPT = false }
        // はじめての登録は 1455 番。使えなければ次の番号 (変えてよいのは番号だけ)
        var link: LoopbackCallback?
        var lastError: Error?
        for port in UInt16(1455)...1459 {
            let candidate = LoopbackCallback(port: port, successPage: "ChatGPT との接続を受け取りました。この画面は自動で閉じます。")
            do {
                try await candidate.start()
                link = candidate
                break
            } catch {
                lastError = error
            }
        }
        guard let link else {
            aiMessage = (lastError as? LocalizedError)?.errorDescription ?? "ChatGPT からの戻りを受け取る準備ができませんでした"
            return
        }
        defer { link.stop() }
        do {
            let login = await chatGPT.startLogin(redirectURI: link.redirectURI)
            let callback = try await ChatGPTSignIn().authorize(url: login.authorizeURL, link: link)
            aiAccount = try await chatGPT.complete(callback: callback)
            aiModels = []
            await refreshAI()
        } catch LoopbackError.cancelled {
            await chatGPT.cancelLogin()
        } catch {
            await chatGPT.cancelLogin()
            aiMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func dismissAIWelcome() async {
        await chatGPT.markWelcomed()
        aiAccount = await chatGPT.credentials
    }

    func disconnectChatGPT() async {
        let revoked = await chatGPT.signOut()
        aiModels = []
        aiAccount = await chatGPT.credentials
        aiJob = AIJob()
        aiMessage = revoked ? nil : "この iPhone からは接続を消しました。念のため ChatGPT の設定から、このアプリの接続を解除してください。"
    }

    // MARK: - 指示

    var selectedPrompt: AIPrompt? {
        prompts.first { $0.id == promptSelected } ?? prompts.first
    }

    func selectPrompt(_ id: String) {
        promptSelected = id
        Prefs.defaults.set(id, forKey: "aiPrompt")
    }

    func savePrompt(_ prompt: AIPrompt) {
        promptStore.save(prompt)
        prompts = promptStore.all()
    }

    @discardableResult
    func duplicatePrompt(_ id: String) -> AIPrompt? {
        let copy = promptStore.duplicate(id)
        prompts = promptStore.all()
        return copy
    }

    func deletePrompt(_ id: String) {
        promptStore.delete(id)
        prompts = promptStore.all()
        if promptSelected == id { promptSelected = prompts.first?.id }
    }

    func restorePrompt(_ builtInID: String) {
        promptStore.restore(builtInID)
        prompts = promptStore.all()
    }

    func movePrompts(from: IndexSet, to: Int) {
        promptStore.move(fromOffsets: from, toOffset: to)
        prompts = promptStore.all()
    }

    /// 消した既定の指示 (元に戻せるもの)
    var removedBuiltInPrompts: [AIPrompt] {
        AIPrompts.builtIns.filter { b in !prompts.contains { $0.id == b.id } }
    }

    // MARK: - 整理する

    /// 整理できる日 (話し声のある録音がある日。新しい順)
    var aiDays: [String] {
        let f = Self.dayFormatter
        let days = Set(segments.filter { $0.state == .closed && $0.hasSpeech != false }.map { f.string(from: $0.startedAt) })
        return days.sorted(by: >)
    }

    /// 今夜に整理する日 (午前 5 時より前なら前の日)
    var aiDefaultDay: String {
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        return Self.dayFormatter.string(from: hour < 5 ? now.addingTimeInterval(-86_400) : now)
    }

    static var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// その日 (時間帯) の会話。なければ nil
    func aiTimeline(day: String, range: TimeRange?) -> String? {
        AINotes.timeline(day: day, timeZone: .current, segments: store.all(), markers: markers,
                         corrector: vocabularyCorrector, range: range)
    }

    /// ChatGPT に渡すもの (送る前に中身を確かめられるように)
    func aiRequest(prompt: AIPrompt, day: String, range: TimeRange?) -> AIRequest? {
        guard let timeline = aiTimeline(day: day, range: range) else { return nil }
        let previous = notesStore.all().filter { $0.isDay && ($0.date ?? "") < day }.first
        return AIPrompts.request(prompt: prompt, day: day, range: range, timeline: timeline,
                                 vocabulary: AINotes.vocabularyMarkdown(vocabulary),
                                 previous: previous.flatMap { p in notesStore.text(of: p.name).map { (p.name, $0) } },
                                 todo: notesStore.text(of: "todo.md"))
    }

    /// ChatGPT に頼んで、まとめを書かせる
    func runAI(prompt: AIPrompt, day: String, range: TimeRange?) async {
        guard aiJob.state != .running else { return }
        aiMessage = nil
        aiJob = AIJob(state: .running, day: day, range: range, promptName: prompt.name, phase: "準備しています")
        // 書いている途中でアプリを離れても、少しの間は続けられるようにする
        let background = UIApplication.shared.beginBackgroundTask(withName: "AI で整理")
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        do {
            var slug = aiModelSlug
            if slug == nil {
                aiModels = try await chatGPT.models()
                slug = aiModels.first?.slug
            }
            guard let model = slug else { throw ChatGPTError("この ChatGPT アカウントで使えるモデルがありません") }
            guard let request = aiRequest(prompt: prompt, day: day, range: range) else {
                throw ChatGPTError(range == nil ? "この日の記録がありません" : "この時間帯の記録がありません")
            }
            aiJob.phase = "AI が書いています"
            let output = try await chatGPT.respond(model: model, instructions: request.instructions, text: request.materials) { chars in
                Task { @MainActor [weak self] in
                    guard let self, self.aiJob.state == .running, chars - self.aiJob.chars >= 40 || chars < 40 else { return }
                    self.aiJob.chars = chars
                }
            }
            aiJob.phase = "保存しています"
            let (note, todo) = AINotes.parse(output)
            guard let note else { throw ChatGPTError("AI の出力から、まとめを読み取れませんでした。もう一度試してください") }
            try notesStore.put(name: request.noteName, text: note)
            if request.updatesTodo, let todo { try notesStore.put(name: "todo.md", text: todo) }
            notes = notesStore.all()
            aiJob = AIJob(state: .done, day: day, range: range, promptName: prompt.name, chars: output.count, noteName: request.noteName)
        } catch let e as ChatGPTError {
            aiJob = AIJob(state: .failed, day: day, range: range, promptName: prompt.name, message: e.message, code: e.code)
            if e.reconnect { aiAccount = await chatGPT.credentials }
        } catch {
            aiJob = AIJob(state: .failed, day: day, range: range, promptName: prompt.name, message: error.localizedDescription)
        }
    }

    /// その日のまとめ
    func note(for day: Date) -> NoteSummary? {
        notesStore.day(Self.dayFormatter.string(from: day))
    }

    func noteText(_ name: String) -> String? {
        notesStore.text(of: name)
    }

    func deleteNote(_ name: String) {
        notesStore.remove(name)
        notes = notesStore.all()
    }
}
