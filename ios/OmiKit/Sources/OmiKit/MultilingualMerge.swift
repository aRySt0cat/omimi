import Foundation

/// 認識結果の最小単位 (Apple の SpeechTranscriber では文字・単語ごとに時刻と信頼度が付く)。
public struct RecognizedToken: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var confidence: Double?

    public init(start: Double, end: Double, text: String, confidence: Double? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
    }
}

/// 1 つの言語モデルが返した認識結果 (文・発話単位)。
public struct RecognizedResult: Equatable, Sendable {
    /// "ja", "en" など
    public var language: String
    public var start: Double
    public var end: Double
    public var text: String
    public var tokens: [RecognizedToken]

    public init(language: String, start: Double, end: Double, text: String, tokens: [RecognizedToken] = []) {
        self.language = language
        self.start = start
        self.end = end
        self.text = text
        self.tokens = tokens
    }

    /// 文字数で重み付けした平均信頼度 (信頼度が無ければ 1)
    public var meanConfidence: Double {
        var sum = 0.0, weight = 0.0
        for t in tokens {
            guard let c = t.confidence else { continue }
            let w = Double(max(1, t.text.trimmingCharacters(in: .whitespaces).count))
            sum += c * w
            weight += w
        }
        return weight > 0 ? sum / weight : 1
    }

    /// 実際に発話のあった区間 (結果全体の範囲は前後の無音を含むことがあるので、トークンの時刻を使う)
    public var spokenRange: ClosedRange<Double> {
        guard let first = tokens.first, let last = tokens.last, first.start <= last.end else { return start...max(start, end) }
        return first.start...last.end
    }
}

/// 複数言語の認識器を同時に動かした結果を 1 本の文字起こしにまとめる。
///
/// Apple の音声認識は 1 つの認識器につき 1 言語なので、主言語 (例: 日本語) と副言語 (例: 英語) の
/// 認識器を同じ音声に並行して掛ける。副言語の認識器は自分の言語以外の音声には低い信頼度を返すため、
/// 「信頼度が高く、文字列もその言語として判定される」副言語の結果を "島" として採用し、
/// その時間帯の主言語の認識結果を置き換える。
public enum MultilingualMerge {
    /// - Parameters:
    ///   - primary: 主言語の認識結果
    ///   - secondary: 副言語の認識結果 (複数言語可)
    ///   - minConfidence: 副言語の結果を採用する平均信頼度の下限
    ///   - textLanguage: 文字列の言語を判定する関数 (例: NLLanguageRecognizer)。"ja" などを返す
    ///   - looseMargin: 島の前後この秒数以内にある主言語のトークンは、文字列が主言語でなければ捨てる
    ///     (言語モデル間で時刻が少しずれるため、英語の端の単語が日本語側に残るのを防ぐ)
    public static func merge(primary: [RecognizedResult], secondary: [RecognizedResult], minConfidence: Double = 0.6,
                             padding: Double = 0.15, looseMargin: Double = 1.0,
                             textLanguage: (String) -> String?) -> [TranscriptPiece] {
        let accepted = secondary.filter { r in
            hasContent(r.text) && r.meanConfidence >= minConfidence && textLanguage(r.text) == r.language
        }
        let islands = mergeRanges(accepted.map { ($0.spokenRange.lowerBound - padding)...($0.spokenRange.upperBound + padding) })
        func inIsland(_ t: Double) -> Bool { islands.contains { $0.contains(t) } }
        func nearIsland(_ t: Double) -> Bool {
            islands.contains { ($0.lowerBound - looseMargin)...($0.upperBound + looseMargin) ~= t }
        }

        var pieces: [TranscriptPiece] = []
        for r in primary {
            if r.tokens.isEmpty {
                let mid = (r.start + r.end) / 2
                if !inIsland(mid), hasContent(r.text) {
                    pieces.append(TranscriptPiece(start: r.start, end: r.end, text: clean(r.text), language: r.language))
                }
                continue
            }
            var group: [RecognizedToken] = []
            func flush() {
                defer { group.removeAll() }
                pieces += sentences(group, language: r.language)
            }
            for token in r.tokens {
                let mid = (token.start + token.end) / 2
                let foreignEdge = nearIsland(mid) && hasContent(token.text) && textLanguage(token.text) != r.language
                if inIsland(mid) || foreignEdge {
                    flush()
                } else {
                    group.append(token)
                }
            }
            flush()
        }
        for r in accepted {
            pieces += Self.pieces(of: r)
        }
        return pieces.sorted { $0.start < $1.start }
    }

    /// 1 つの認識結果を文ごとの区間にする (トークンが無ければ結果全体)。
    public static func pieces(of r: RecognizedResult) -> [TranscriptPiece] {
        if r.tokens.isEmpty {
            return hasContent(r.text) ? [TranscriptPiece(start: r.start, end: r.end, text: clean(r.text), language: r.language)] : []
        }
        return sentences(r.tokens, language: r.language)
    }

    /// トークン列を文末記号と長い間 (`pause` 秒) で区切る。
    /// Apple の認識結果は複数の話者の発話を 1 つにまとめることがあるので、話者の割り当てを細かくするために使う。
    public static func sentences(_ tokens: [RecognizedToken], language: String?, pause: Double = 0.8) -> [TranscriptPiece] {
        let terminators: Set<Character> = ["。", "！", "？", ".", "!", "?"]
        var out: [TranscriptPiece] = []
        var current: [RecognizedToken] = []
        func flush() {
            defer { current.removeAll() }
            let text = clean(current.map(\.text).joined())
            guard hasContent(text), let first = current.first, let last = current.last else { return }
            out.append(TranscriptPiece(start: first.start, end: last.end, text: text, language: language))
        }
        for token in tokens {
            if let last = current.last, token.start - last.end > pause {
                flush()
            }
            current.append(token)
            if let c = token.text.trimmingCharacters(in: .whitespaces).last, terminators.contains(c) {
                flush()
            }
        }
        flush()
        return out
    }

    static func mergeRanges(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// 文字・数字を含むか (句読点だけの断片を捨てる)
    static func hasContent(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// 前後の空白と、先頭に取り残された句読点を除く
    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = CharacterSet(charactersIn: "。、，,.!?！？・ ")
        while let f = t.unicodeScalars.first, leading.contains(f) {
            t = String(t.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return t
    }
}
