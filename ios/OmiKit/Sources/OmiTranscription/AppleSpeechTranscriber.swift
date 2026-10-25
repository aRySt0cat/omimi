@preconcurrency import AVFoundation
import Foundation
import NaturalLanguage
import OmiKit
import Speech

public enum AppleSpeechError: Error, LocalizedError {
    case unsupportedLocale(String)
    case modelNotInstalled(String)
    case noAudio
    case formatUnavailable

    public var errorDescription: String? {
        switch self {
        case let .unsupportedLocale(id): return "この端末は \(id) の文字起こしに対応していません"
        case let .modelNotInstalled(id): return "\(id) の音声認識モデルが未インストールです (設定からダウンロードしてください)"
        case .noAudio: return "音声がありません"
        case .formatUnavailable: return "音声形式を変換できません"
        }
    }
}

/// Apple の SpeechAnalyzer / SpeechTranscriber (iOS 26+) による端末内文字起こし。
/// 音声は端末外へ送信されない。初回のみ Apple から言語モデルをダウンロードする。
///
/// 複数の言語を指定すると、言語ごとの認識器を同じ音声に並行して掛け、
/// `MultilingualMerge` で発話ごとに言語を選ぶ (先頭が主言語)。
public enum AppleSpeechTranscriber {
    public static let engineName = "apple-speech"

    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    public static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    public enum ModelStatus: Sendable {
        case unsupported, notInstalled, downloading, installed
    }

    public static func modelStatus(for locale: Locale) async -> ModelStatus {
        await modelStatus(for: [locale])
    }

    /// すべての言語のモデルがそろっているか
    public static func modelStatus(for locales: [Locale]) async -> ModelStatus {
        var modules: [SpeechTranscriber] = []
        for l in locales {
            guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: l) else { return .unsupported }
            modules.append(makeModule(locale: resolved))
        }
        switch await AssetInventory.status(forModules: modules) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .notInstalled
        default: return .unsupported
        }
    }

    public static func installModel(for locale: Locale, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await installModel(for: [locale], progress: progress)
    }

    /// 言語モデルをダウンロードする (Apple のサーバから。音声は送信しない)。
    public static func installModel(for locales: [Locale], progress: (@Sendable (Double) -> Void)? = nil) async throws {
        var modules: [SpeechTranscriber] = []
        for l in locales {
            guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: l) else {
                throw AppleSpeechError.unsupportedLocale(l.identifier)
            }
            modules.append(makeModule(locale: resolved))
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else { return }
        let observation = progress.map { handler in
            request.progress.observe(\.fractionCompleted) { p, _ in handler(p.fractionCompleted) }
        }
        defer { observation?.invalidate() }
        try await request.downloadAndInstall()
    }

    static func makeModule(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    static func languageCode(_ locale: Locale) -> String {
        locale.language.languageCode?.identifier ?? locale.identifier
    }

    public static func transcribe(segmentURL: URL, locale: Locale) async throws -> Transcript {
        try await transcribe(segmentURL: segmentURL, locales: [locale])
    }

    /// Ogg Opus セグメントを文字起こしする。
    /// - Parameter contextualStrings: 用語集の語 (人名・専門用語)。認識しやすくするヒント
    public static func transcribe(segmentURL: URL, locales: [Locale], contextualStrings: [String] = []) async throws -> Transcript {
        let file = try OggOpusReader.read(url: segmentURL, verifyCRC: false)
        guard !file.packets.isEmpty else { throw AppleSpeechError.noAudio }
        let decoder = try OpusDecoder(sampleRate: Double(file.head.inputSampleRate == 0 ? 16_000 : file.head.inputSampleRate))
        let samples = decoder.decodeSamples(file.packets)
        return try await transcribe(samples: samples, sampleRate: decoder.sampleRate, locales: locales,
                                    contextualStrings: contextualStrings)
    }

    public static func transcribe(samples: [Int16], sampleRate: Double, locale: Locale) async throws -> Transcript {
        try await transcribe(samples: samples, sampleRate: sampleRate, locales: [locale])
    }

    /// 16 bit モノラル PCM を文字起こしする。`locales` の先頭が主言語。
    public static func transcribe(samples: [Int16], sampleRate: Double, locales: [Locale],
                                  contextualStrings: [String] = []) async throws -> Transcript {
        guard !samples.isEmpty else { throw AppleSpeechError.noAudio }
        guard !locales.isEmpty else { throw AppleSpeechError.unsupportedLocale("-") }
        var resolved: [Locale] = []
        for l in locales {
            guard let r = await SpeechTranscriber.supportedLocale(equivalentTo: l) else {
                throw AppleSpeechError.unsupportedLocale(l.identifier)
            }
            resolved.append(r)
        }
        let modules = resolved.map(makeModule(locale:))
        for (m, l) in zip(modules, resolved) where await AssetInventory.status(forModules: [m]) != .installed {
            throw AppleSpeechError.modelNotInstalled(l.identifier)
        }

        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false)
        else { throw AppleSpeechError.formatUnavailable }
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: sourceFormat) ?? sourceFormat
        let buffers = try makeBuffers(samples: samples, format: sourceFormat, target: analyzerFormat)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        for b in buffers { continuation.yield(AnalyzerInput(buffer: b)) }
        continuation.finish()

        let analyzer = SpeechAnalyzer(modules: modules, options: .init(priority: .utility, modelRetention: .lingering))
        let collectors = zip(modules, resolved).map { module, locale in
            let language = languageCode(locale)
            return Task { () throws -> [RecognizedResult] in
                var results: [RecognizedResult] = []
                for try await result in module.results where result.isFinal {
                    results.append(recognized(result, language: language))
                }
                return results
            }
        }
        do {
            if !contextualStrings.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings = [.general: contextualStrings]
                try await analyzer.setContext(context)
            }
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            _ = try await analyzer.analyzeSequence(stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
            collectors.forEach { $0.cancel() }
            throw error
        }
        var perLocale: [[RecognizedResult]] = []
        for c in collectors { perLocale.append(try await c.value) }

        let pieces: [TranscriptPiece]
        if perLocale.count == 1 {
            pieces = perLocale[0].flatMap(MultilingualMerge.pieces(of:))
        } else {
            let candidates = resolved.map(languageCode)
            pieces = MultilingualMerge.merge(primary: perLocale[0], secondary: perLocale.dropFirst().flatMap { $0 }) {
                textLanguage($0, candidates: candidates)
            }
        }
        let localeLabel = resolved.map { $0.identifier(.bcp47) }.joined(separator: "+")
        return Transcript(engine: engineName, locale: localeLabel, pieces: pieces)
    }

    static func recognized(_ result: SpeechTranscriber.Result, language: String) -> RecognizedResult {
        var tokens: [RecognizedToken] = []
        for run in result.text.runs {
            let text = String(result.text[run.range].characters)
            let range = run.audioTimeRange ?? result.range
            tokens.append(RecognizedToken(start: range.start.seconds, end: range.end.seconds, text: text,
                                          confidence: run.transcriptionConfidence))
        }
        return RecognizedResult(language: language, start: result.range.start.seconds, end: result.range.end.seconds,
                                text: String(result.text.characters), tokens: tokens)
    }

    /// 文字列の言語を候補の中から判定する
    static func textLanguage(_ text: String, candidates: [String]) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = candidates.map { NLLanguage(rawValue: $0) }
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    /// 1 秒ごとのバッファに分割し、必要なら解析器の形式へ変換する。
    static func makeBuffers(samples: [Int16], format: AVAudioFormat, target: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        let chunk = Int(format.sampleRate)
        let converter = format == target ? nil : AVAudioConverter(from: format, to: target)
        if format != target && converter == nil { throw AppleSpeechError.formatUnavailable }
        var result: [AVAudioPCMBuffer] = []
        var offset = 0
        while offset < samples.count {
            let n = min(chunk, samples.count - offset)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else {
                throw AppleSpeechError.formatUnavailable
            }
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                buf.int16ChannelData![0].update(from: src.baseAddress! + offset, count: n)
            }
            offset += n
            if let converter {
                let ratio = target.sampleRate / format.sampleRate
                guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(n) * ratio) + 64) else {
                    throw AppleSpeechError.formatUnavailable
                }
                var supplied = false
                var error: NSError?
                _ = converter.convert(to: out, error: &error) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true
                    status.pointee = .haveData
                    return buf
                }
                if let error { throw error }
                result.append(out)
            } else {
                result.append(buf)
            }
        }
        return result
    }
}
