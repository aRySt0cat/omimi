import Foundation

/// 時間帯 (0:00 からの分。end は 24:00 = 1440 まで)
public struct TimeRange: Codable, Equatable, Hashable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = max(0, min(start, 1440))
        self.end = max(0, min(end, 1440))
    }

    public var isValid: Bool { end > start }

    /// `10:00〜12:30`
    public var label: String { "\(Self.clock(start))〜\(Self.clock(end))" }

    /// ファイル名に使う `10.00-12.30`
    var fileLabel: String { "\(Self.clock(start, separator: "."))-\(Self.clock(end, separator: "."))" }

    static func clock(_ minutes: Int, separator: String = ":") -> String {
        String(format: "%d%@%02d", minutes / 60, separator, minutes % 60)
    }

    /// その日の、この時間帯 (日付は `YYYY-MM-DD`)
    public func interval(day: String, timeZone: TimeZone) -> DateInterval? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, isValid else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        guard let midnight = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return DateInterval(start: midnight.addingTimeInterval(Double(start) * 60), end: midnight.addingTimeInterval(Double(end) * 60))
    }
}

/// 「AI で整理」の指示 (利用者が書き換えて保存し、いくつも持って付け替える)
public struct AIPrompt: Codable, Identifiable, Equatable, Hashable, Sendable {
    public enum Output: String, Codable, CaseIterable, Sendable {
        /// その日のまとめ (`YYYY-MM-DD.md`。「記録」のその日にも出る)
        case dayNote
        /// 別のノート (日付・時間帯・指示の名前で保存する)
        case note
    }

    public var id: String
    public var name: String
    /// 指示の本文。{{day}} {{day_title}} {{range}} {{timeline}} {{note}} {{previous_note}} {{name}} を置き換える
    public var body: String
    public var output: Output
    /// やること (todo.md) を添付し、書き直させる
    public var updatesTodo: Bool
    /// 前の日のまとめを添付する
    public var attachPrevious: Bool
    /// 既定の時間帯 (nil は終日)。整理するときに変えられる
    public var defaultRange: TimeRange?
    /// 元にした既定の指示 (「元に戻す」に使う)
    public var builtIn: String?
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, name: String, body: String, output: Output, updatesTodo: Bool,
                attachPrevious: Bool, defaultRange: TimeRange? = nil, builtIn: String? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.body = body
        self.output = output
        self.updatesTodo = updatesTodo
        self.attachPrevious = attachPrevious
        self.defaultRange = defaultRange
        self.builtIn = builtIn
        self.updatedAt = updatedAt
    }

    /// 書き出すまとめの名前
    public func noteName(day: String, range: TimeRange?) -> String {
        switch output {
        case .dayNote: return "\(day).md"
        case .note:
            let cleaned = name.replacingOccurrences(of: "/", with: "・").trimmingCharacters(in: .whitespaces)
            return "\(day) \(range?.label ?? "終日") \(cleaned.isEmpty ? "ノート" : cleaned).md"
        }
    }
}

/// AI に渡すもの (指示・添付) と、書いたものの保存先
public struct AIRequest: Sendable {
    public var instructions: String
    public var materials: String
    public var noteName: String
    public var updatesTodo: Bool
    /// 添付した会話の文字数
    public var timelineChars: Int
}

public enum AIPrompts {
    public static let dailyID = "builtin.daily"
    public static let meetingID = "builtin.meeting"
    public static let todoID = "builtin.todo"
    public static let diaryID = "builtin.diary"

    /// 置き換えられる言葉 (編集画面の説明に出す)
    public static let placeholders: [(String, String)] = [
        ("{{day_title}}", "整理する日 (10月20日 (月))"),
        ("{{day}}", "整理する日 (2026-10-20)"),
        ("{{range}}", "時間帯 (終日 / 10:00〜12:00)"),
        ("{{timeline}}", "その日の会話の添付の名前"),
        ("{{previous_note}}", "前の日のまとめの添付の名前"),
        ("{{note}}", "書いたまとめの保存先"),
        ("{{name}}", "この指示の名前"),
    ]

    public static let builtIns: [AIPrompt] = [
        AIPrompt(id: dailyID, name: "1 日のまとめ", body: dailyBody, output: .dayNote, updatesTodo: true, attachPrevious: true,
                 builtIn: dailyID, updatedAt: Date(timeIntervalSince1970: 0)),
        AIPrompt(id: meetingID, name: "会議の議事録", body: meetingBody, output: .note, updatesTodo: false, attachPrevious: false,
                 defaultRange: TimeRange(start: 10 * 60, end: 11 * 60), builtIn: meetingID, updatedAt: Date(timeIntervalSince1970: 0)),
        AIPrompt(id: todoID, name: "やることの洗い出し", body: todoBody, output: .note, updatesTodo: true, attachPrevious: false,
                 builtIn: todoID, updatedAt: Date(timeIntervalSince1970: 0)),
        AIPrompt(id: diaryID, name: "ふり返り日記", body: diaryBody, output: .note, updatesTodo: false, attachPrevious: true,
                 builtIn: diaryID, updatedAt: Date(timeIntervalSince1970: 0)),
    ]

    public static func builtIn(_ id: String?) -> AIPrompt? { builtIns.first { $0.id == id } }

    /// 指示と添付を作る
    public static func request(prompt: AIPrompt, day: String, range: TimeRange?, timeline: String,
                               vocabulary: String?, previous: (name: String, text: String)?, todo: String?) -> AIRequest {
        let note = prompt.noteName(day: day, range: range)
        let timelineName = range.map { "timeline/\(day) \($0.fileLabel).md" } ?? "timeline/\(day).md"
        let previousName = prompt.attachPrevious ? previous.map { "notes/\($0.name)" } : nil
        let values = [
            "day": day, "day_title": AINotes.dayTitle(day), "range": range?.label ?? "終日",
            "timeline": timelineName, "timeline_md": timelineName, "note": "notes/\(note)",
            "previous_note": previousName ?? "(なし)", "name": prompt.name,
        ]
        let body = values.reduce(prompt.body) { $0.replacingOccurrences(of: "{{\($1.key)}}", with: $1.value) }
        var files: [(name: String, text: String)] = [("guide.md", guide)]
        if let vocabulary { files.append(("vocabulary.md", vocabulary)) }
        files.append((timelineName, timeline))
        if let previousName, let previous { files.append((previousName, previous.text)) }
        if prompt.updatesTodo { files.append(("notes/todo.md", todo ?? "# やること\n")) }
        return AIRequest(instructions: body + suffix(note: "notes/\(note)", updatesTodo: prompt.updatesTodo),
                         materials: AINotes.materials(files), noteName: note, updatesTodo: prompt.updatesTodo,
                         timelineChars: timeline.count)
    }

    /// 出力の形の約束 (アプリがそれぞれのファイルに保存する)
    public static func suffix(note: String, updatesTodo: Bool) -> String {
        var lines = ["", "", "## この実行での読み書き", "",
                     "この実行では、iPhone の Omimi アプリが AI を直接呼んでいます。ファイルを開いたり書いたりはできません。", "",
                     "- 読むものは、入力に `<file path=\"...\">` ごとに添付してあります。無いものは添付していません。",
                     "- `guide.md` (添付) の取り扱いの注意に従ってください。",
                     "- 書くものは、次の形式だけで出力してください。前後に説明を付けないでください。アプリがそれぞれのファイルに保存します。", "",
                     AINotes.noteMark, "(\(note) の全文)"]
        if updatesTodo { lines += [AINotes.todoMark, "(notes/todo.md の全文。変更がなくても全文)"] }
        lines += [AINotes.endMark, ""]
        return lines.joined(separator: "\n")
    }

    // MARK: - 添付する説明と、既定の指示

    /// AI 向けの、添付の読み方と取り扱いの注意
    public static let guide = """
    # 添付について (AI 向け)

    Omi (身につける常時録音デバイス) で録った **個人の会話記録** です。iPhone の Omimi アプリが作りました。

    ## 取り扱いの注意

    - 個人や周囲の人の会話を含みます。**外部のサービス・Web 検索・共有リンクに内容を送らないでください。**
    - 内容は、頼まれたまとめを書くためだけに使ってください。

    ## 添付

    | 名前 | 中身 |
    |---|---|
    | `timeline/YYYY-MM-DD.md` | その日 (または指定の時間帯) の会話を時系列に並べたもの。まずこれを読む |
    | `vocabulary.md` | (あれば) 用語集。人名・専門用語の正しい表記・読み・よく間違う表記・説明。まとめではこの表記を使う |
    | `notes/YYYY-MM-DD.md` | (あれば) 前の日のまとめ |
    | `notes/todo.md` | (あれば) 日をまたいで続くやること (`- [ ]` / `- [x]`) |

    ## 用語

    | 用語 | 意味 |
    |---|---|
    | 録音 | 録音の 1 単位。話し終えて 30 秒無音 / 最大 5 分 / ボタンの「区切り」で区切られる。`## 時刻 – 時刻` の見出し 1 つが 1 件 |
    | 話者 | 声で識別した人。名前は本人が付ける (`自分` = 装着者本人)。大事な人にだけ名前を付けるので、名前のない人 (店員・駅や電車のアナウンス・通りすがりなど) はすべて `その他`。`不明` は短くて分からなかった発話 |
    | 言語 | 発話ごとの言語 (`ja` / `en`)。自動判別 |
    | 印 | 装着者が Omi のボタンで付けた印。下の表を参照 |

    ### 印の意味

    | 表示 | 意味と扱い方 |
    |---|---|
    | ⭐ 注目 | **直前〜直後の会話が大事**。要約では必ず触れる。前後 1〜2 分を重点的に読む |
    | ✂️ 区切り | **話題・場面の切れ目**。会話をまとまりに分けるときの境界として使う |
    | 📝 メモ | **この後に本人が話す内容は、自分へのメモや指示** (TODO・覚え書き・依頼)。次の区切りか、話し手が変わるまでを 1 つのメモとして扱う |

    ## timeline の形式

    - `## 10:40:12 – 10:44:51 · 4分39秒 · 自分, 田中` が録音 1 件。その下の `<!-- segment: <segment_id> ... -->` が録音の ID。
    - `- 10:40:15 **自分** (ja): 発言` が発話 1 つ。

    ## 文字起こしの注意

    - 自動の文字起こしなので誤りがあります。固有名詞・数字は特に誤りやすいです。用語集の語の聞き間違いは、文脈に合えば正しい語として読んでください。
    - 話者の識別も誤ることがあります。会話の流れと矛盾する場合は、その旨を書き添えてください。

    ## まとめの書き方の決まり

    書いた Markdown は、本人の iPhone (Omimi アプリの「まとめ」) に表示されます。

    - 最初の `# 見出し` が題名、その直後の `> 引用` (無ければ最初の段落) が一覧に出る要約になります。
    - 会話を指すときは `[12:42](omimi://segment/<segment_id>)` と書くと、タップでその会話が開きます。
    - 表示できるのは、見出し・段落・箇条書き (チェックボックス付きも可)・番号付きリスト・引用・表・コード・区切り線・**太字**・*斜体*・`コード`・リンクです。HTML は表示されません。
    """

    static let dailyBody = """
    # {{day_title}} のまとめ ({{range}})

    あなたは、Omi を身につけている本人 (話者名 `自分`) の 1 日の会話記録を整理するアシスタントです。最初に `guide.md` を読み、添付の読み方と取り扱いの注意に従ってください。

    ## 読むもの

    - `{{timeline}}`: その日の会話。まずこれを読む
    - `{{previous_note}}`: 前の日のまとめ (続いている話題や、やることの確認に)
    - `notes/todo.md`: 日をまたいで続くやること
    - `vocabulary.md`: あれば (用語集)

    ## 書くもの

    1. `{{note}}` を書く。書式は下の通り。
    2. `notes/todo.md` を書き直す。今日の 📝 メモや会話から出たやることを足し、終わったと分かるものは `- [x]` にする。無ければ `# やること` の見出しで新しく作る。

    ## {{note}} の書式

    ~~~markdown
    # {{day_title}}

    > 今日を 1〜2 文で。(iPhone の一覧にこの行が出ます)

    ## 話したこと

    - **12:42 話題の名前** — 誰と何を話したかを 1〜2 文で。[12:42](omimi://segment/<segment_id>)

    ## 大事なところ

    - ⭐ 注目の印の前後で話していたこと。印が無い日はこの節ごと省く。

    ## やること

    - [ ] 📝 メモや会話から出たやること (期限・相手が分かれば書く)

    ## 人

    - **名前** — 今日話したこと・分かったこと

    ## 気になったこと

    - 文字起こしや話者の誤りと思われる箇所など。無ければこの節ごと省く。
    ~~~

    - 会話を指すときは `[時刻](omimi://segment/<segment_id>)` と書く。`segment_id` は timeline の `<!-- segment: ... -->`。
    - 話し声のない録音や、短い相づちだけの録音は無視してよいです。
    - 話者の `その他` は、名前を付けていない人 (店員・アナウンス・通りすがりなど) です。「人」の節には書かず、必要なら「店員」「アナウンス」のように役割で触れてください。
    - 人名・専門用語は用語集の正しい表記で書いてください。
    - 推測で事実を足さないでください。不確かなことには「(不確か)」と書き添えてください。
    - 日本語で、簡潔に書いてください。
    """

    static let meetingBody = """
    # 会議の議事録: {{day_title}} {{range}}

    あなたは、Omi を身につけている本人 (話者名 `自分`) が参加した会議の議事録を書くアシスタントです。最初に `guide.md` を読み、添付の読み方と取り扱いの注意に従ってください。

    `{{timeline}}` は {{day_title}} {{range}} の会話です。この中の会議について、`{{note}}` を次の書式で書いてください。会議ではない雑談は省きます。会議が複数あれば、会議ごとに分けて書きます。

    ~~~markdown
    # 会議の名前か議題 ({{day_title}} {{range}})

    > 何を話し、何が決まったかを 1〜2 文で。

    ## 参加者

    - 名前 (話者名。`その他` は役割が分かれば役割で)

    ## 議題と話したこと

    - **議題** — 要点を 2〜3 文で。[時刻](omimi://segment/<segment_id>)

    ## 決まったこと

    - 決まったこと (決めた人・理由が分かれば書く)

    ## 宿題

    - [ ] やること — 担当・期限 (分かれば)

    ## 決まっていないこと・次回

    - 持ち越したこと、次回の予定
    ~~~

    - 発言の言い回しより、決まったことと宿題を正確に書いてください。
    - 推測で事実を足さないでください。不確かなことには「(不確か)」と書き添えてください。
    - 日本語で、簡潔に書いてください。
    """

    static let todoBody = """
    # やることの洗い出し: {{day_title}} {{range}}

    あなたは、Omi を身につけている本人 (話者名 `自分`) のやることを整理するアシスタントです。最初に `guide.md` を読んでください。

    `{{timeline}}` の会話から、本人がやること・頼まれたこと・頼んだこと・約束を漏れなく拾ってください。特に 📝 メモの印の後の本人の発言は、自分への指示です。

    1. `{{note}}` に、見つけたものを次の書式で書く。
    2. `notes/todo.md` を書き直す。新しいものを足し、終わったと分かるものは `- [x]` にする。重複はまとめる。

    ~~~markdown
    # やること ({{day_title}} {{range}})

    > 見つけた数と、いちばん急ぐものを 1 文で。

    ## 自分がやること

    - [ ] 内容 — 期限・相手 (分かれば) [時刻](omimi://segment/<segment_id>)

    ## 人に頼んだこと・待っていること

    - [ ] 内容 — 相手

    ## 約束・予定

    - 日時 — 内容
    ~~~

    - 会話にないことを足さないでください。日本語で、簡潔に書いてください。
    """

    static let diaryBody = """
    # ふり返り日記: {{day_title}}

    あなたは、Omi を身につけている本人 (話者名 `自分`) の日記を代筆するアシスタントです。最初に `guide.md` を読んでください。

    `{{timeline}}` ({{range}} の会話) をもとに、本人の一人称 (「私」) で、その日の日記を `{{note}}` に書いてください。

    - 題名は `# {{day_title}} の日記`、その下に `> ` で始まる 1 文の要約を置く。
    - 出来事を時間の順に、会った人・話したこと・感じたこと (会話から分かる範囲で) を 400〜800 字ほどで。
    - 最後に「明日に持ち越すこと」を箇条書きで (無ければ省く)。
    - 会話にない出来事や気持ちを作らないでください。
    """
}

/// 指示を iPhone に保存する (`prompts.json`)。はじめは既定の指示を入れておく
public final class AIPromptStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var prompts: [AIPrompt]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder.omi.decode([AIPrompt].self, from: data), !saved.isEmpty {
            prompts = saved
        } else {
            prompts = AIPrompts.builtIns
        }
    }

    public func all() -> [AIPrompt] { lock.withLock { prompts } }

    public func get(_ id: String) -> AIPrompt? { all().first { $0.id == id } }

    /// 追加または書き換え
    public func save(_ prompt: AIPrompt, now: Date = Date()) {
        var p = prompt
        p.updatedAt = now
        lock.withLock {
            if let i = prompts.firstIndex(where: { $0.id == p.id }) { prompts[i] = p } else { prompts.append(p) }
            persist()
        }
    }

    /// 複製 (名前に「のコピー」を付ける)
    @discardableResult
    public func duplicate(_ id: String, now: Date = Date()) -> AIPrompt? {
        guard var p = get(id) else { return nil }
        p.id = UUID().uuidString
        p.name += " のコピー"
        p.builtIn = nil
        save(p, now: now)
        return p
    }

    /// 消す (最後の 1 つは消さない)
    public func delete(_ id: String) {
        lock.withLock {
            guard prompts.count > 1 else { return }
            prompts.removeAll { $0.id == id }
            persist()
        }
    }

    /// 既定の指示を元の文面に戻す。消してしまった既定の指示を戻すときも使う
    public func restore(_ builtInID: String) {
        guard let original = AIPrompts.builtIn(builtInID) else { return }
        lock.withLock {
            if let i = prompts.firstIndex(where: { $0.id == builtInID }) { prompts[i] = original } else { prompts.append(original) }
            persist()
        }
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) {
        lock.withLock {
            var moved = prompts
            let items = fromOffsets.sorted().map { moved[$0] }
            for i in fromOffsets.sorted(by: >) { moved.remove(at: i) }
            let target = toOffset - fromOffsets.filter { $0 < toOffset }.count
            moved.insert(contentsOf: items, at: max(0, min(target, moved.count)))
            prompts = moved
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder.omi.encode(prompts) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
