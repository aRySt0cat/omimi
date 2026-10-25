@preconcurrency import AVFoundation
import CoreML
import Foundation
import OmiKit
import OmiSpeakers
import OmiTranscription

// 開発用 CLI: Omi 実機なしでアプリと同じパイプラインを macOS 上で動かす。
//
//   omikit-cli simulate <音声ファイル> <保存先> [--segment-seconds 300] [--loss 0.0] [--pause 5:12,20:60]
//     --pause 秒:長さ  音声の 5 秒目で 12 秒間受信が止まる (デバイスのマイク休止) を模擬する
//   omikit-cli transcribe <保存先> [--locale ja-JP,en-US]   (複数指定で言語を自動判別)
//   omikit-cli list <保存先>
//   omikit-cli decode <in.opus> <out.wav>
//   omikit-cli speakers <in.opus|in.f32> --models <dir> [--threshold 0.3] [--out result.json]
//     iPhone と同じ話者分離 (Core ML)。dir には SpeakerSegmentation / SpeakerEmbedding の .mlpackage か .mlmodelc

func usage() -> Never {
    print("""
    usage:
      omikit-cli simulate <audio> <store-dir> [--segment-seconds N] [--loss RATE] [--pause AT:SEC,...]
      omikit-cli transcribe <store-dir> [--locale ja-JP[,en-US]]
      omikit-cli list <store-dir>
      omikit-cli decode <in.opus> <out.wav>
      omikit-cli speakers <in.opus|in.f32> --models DIR [--threshold 0.3] [--out result.json]
    """)
    exit(2)
}

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String], flagNames: Set<String>) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if flagNames.contains(name) {
                    flags.insert(name)
                } else if i + 1 < raw.count {
                    options[name] = raw[i + 1]
                    i += 1
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }
}

/// 任意の音声ファイルを 16 kHz / 16 bit / モノラルに変換して読み込む。
func loadPCM16k(_ url: URL) throws -> [Int16] {
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
    let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: source)
    let converter = AVAudioConverter(from: file.processingFormat, to: target)!
    let capacity = AVAudioFrameCount(Double(source.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1024
    let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
    var supplied = false
    var error: NSError?
    _ = converter.convert(to: out, error: &error) { _, status in
        if supplied { status.pointee = .endOfStream; return nil }
        supplied = true
        status.pointee = .haveData
        return source
    }
    if let error { throw error }
    return Array(UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength)))
}

/// Omi の BLE notification を模擬する (`[index u16 LE][sub 0][opus]`)。
func notifications(for packets: [Data], startIndex: UInt16 = 0) -> [Data] {
    packets.enumerated().map { i, p in
        let idx = startIndex &+ UInt16(truncatingIfNeeded: i)
        return Data([UInt8(idx & 0xFF), UInt8(idx >> 8), 0]) + p
    }
}

func simulate(_ args: Args) throws {
    guard args.positional.count == 3 else { usage() }
    let input = URL(fileURLWithPath: args.positional[1])
    let store = try SegmentStore(directory: URL(fileURLWithPath: args.positional[2]))
    let segmentSeconds = Double(args.options["segment-seconds"] ?? "300") ?? 300
    let loss = Double(args.options["loss"] ?? "0") ?? 0
    // [(音声上の位置, 止まる秒数)]
    let pauses: [(Double, Double)] = (args.options["pause"] ?? "").split(separator: ",").compactMap { item in
        let p = item.split(separator: ":").compactMap { Double($0) }
        return p.count == 2 ? (p[0], p[1]) : nil
    }

    let samples = try loadPCM16k(input)
    let packets = try OpusEncoder(sampleRate: 16_000, framesPerPacket: 320).encode(samples: samples)
    print("encoded \(samples.count) samples -> \(packets.count) opus packets")

    var assembler = AudioPacketAssembler()
    let recorder = SegmentRecorder(store: store)
    let context = SegmentRecorder.Context(
        deviceId: "simulator", deviceName: "omikit-cli", firmware: "sim", codec: .opusFS320,
        maxSegmentSeconds: segmentSeconds, transcribeOnDevice: true)
    let start = Date()
    var dropped = 0
    assembler.maxFragmentPayload = 182
    for (i, n) in notifications(for: packets).enumerated() {
        if loss > 0, Double.random(in: 0..<1) < loss { dropped += 1; continue }
        let audioTime = Double(i + 1) * 0.02
        let paused = pauses.filter { $0.0 < audioTime }.reduce(0) { $0 + $1.1 }
        let now = start.addingTimeInterval(audioTime + paused)
        // アプリと同じく、30 秒無音ならセグメントを閉じる
        if let meta = try recorder.closeIfIdle(now: now, after: context.splitAfterSilence) {
            print("closed (idle) \(meta.id) \(String(format: "%.2f", meta.durationSeconds))s")
        }
        for meta in try recorder.append(assembler.push(n), context: context, now: now) {
            print("closed \(meta.id) \(String(format: "%.2f", meta.durationSeconds))s")
        }
    }
    _ = try recorder.append(assembler.flush(), context: context)
    if let meta = try recorder.close() {
        print("closed \(meta.id) \(String(format: "%.2f", meta.durationSeconds))s frames=\(meta.frameCount) concealed=\(meta.concealedFrames) silence=\(meta.silenceFilledSeconds ?? 0)")
    }
    print("dropped \(dropped) notifications, stats: \(assembler.stats)")
}

func transcribe(_ args: Args) async throws {
    guard args.positional.count == 2 else { usage() }
    let store = try SegmentStore(directory: URL(fileURLWithPath: args.positional[1]))
    // --locale ja-JP,en-US のようにカンマ区切りで複数指定すると言語を自動判別する (先頭が主言語)
    let locales = (args.options["locale"] ?? "ja-JP").split(separator: ",").map { Locale(identifier: String($0)) }
    let status = await AppleSpeechTranscriber.modelStatus(for: locales)
    if status != .installed {
        print("installing speech models for \(locales.map(\.identifier))... (\(status))")
        try await AppleSpeechTranscriber.installModel(for: locales)
    }
    for meta in store.all().reversed() where meta.state == .closed && meta.transcriptionState == .pending {
        let t0 = Date()
        do {
            let transcript = try await AppleSpeechTranscriber.transcribe(segmentURL: store.audioURL(for: meta), locales: locales)
            store.update(meta.id) {
                $0.transcript = transcript
                $0.transcriptionState = .done
                $0.transcriptionError = nil
            }
            print("[\(meta.id)] (\(String(format: "%.1f", Date().timeIntervalSince(t0)))s)")
            for p in transcript.pieces {
                print(String(format: "  %6.2f-%6.2f [%@] ", p.start, p.end, p.language ?? "-") + p.text)
            }
        } catch {
            store.update(meta.id) {
                $0.transcriptionState = .failed
                $0.transcriptionError = error.localizedDescription
            }
            print("[\(meta.id)] failed: \(error)")
        }
    }
}

func list(_ args: Args) throws {
    guard args.positional.count == 2 else { usage() }
    let store = try SegmentStore(directory: URL(fileURLWithPath: args.positional[1]))
    for m in store.all() {
        print("\(m.id) \(m.state.rawValue) \(String(format: "%.1f", m.durationSeconds))s stt=\(m.transcriptionState.rawValue)")
        if let t = m.transcript { print("  " + t.text.replacingOccurrences(of: "\n", with: " ")) }
    }
}

func decode(_ args: Args) throws {
    guard args.positional.count == 3 else { usage() }
    let file = try OggOpusReader.read(url: URL(fileURLWithPath: args.positional[1]))
    let decoder = try OpusDecoder(sampleRate: Double(file.head.inputSampleRate))
    let samples = decoder.decodeSamples(file.packets)
    let out = try AVAudioFile(forWriting: URL(fileURLWithPath: args.positional[2]), settings: decoder.outputFormat.settings,
                              commonFormat: .pcmFormatInt16, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: decoder.outputFormat, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = buf.frameCapacity
    samples.withUnsafeBufferPointer { buf.int16ChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try out.write(from: buf)
    print("decoded \(file.packets.count) packets, \(String(format: "%.2f", file.durationSeconds))s, tags=\(file.tags)")
}

/// .mlpackage ならコンパイルして .mlmodelc を返す
func compiledModel(_ dir: URL, _ name: String) async throws -> URL {
    let compiled = dir.appendingPathComponent("\(name).mlmodelc")
    if FileManager.default.fileExists(atPath: compiled.path) { return compiled }
    return try await MLModel.compileModel(at: dir.appendingPathComponent("\(name).mlpackage"))
}

func speakers(_ args: Args) async throws {
    guard args.positional.count == 2, let models = args.options["models"] else { usage() }
    let input = URL(fileURLWithPath: args.positional[1])
    let audio: [Float]
    if input.pathExtension == "f32" {
        let data = try Data(contentsOf: input)
        audio = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    } else {
        let file = try OggOpusReader.read(url: input)
        let rate = file.head.inputSampleRate == 0 ? 16_000 : Double(file.head.inputSampleRate)
        audio = try OpusDecoder(sampleRate: rate).decodeSamples(file.packets).map { Float($0) / 32768 }
    }
    let dir = URL(fileURLWithPath: models)
    let t0 = Date()
    let networks = try SpeakerNetworks(segmentationURL: try await compiledModel(dir, "SpeakerSegmentation"),
                                       embeddingURL: try await compiledModel(dir, "SpeakerEmbedding"),
                                       computeUnits: .all)
    let load = Date().timeIntervalSince(t0)
    var settings = VoiceLibrary.Settings()
    if let t = args.options["threshold"].flatMap(Double.init) { settings.diarizationThreshold = t }
    let result = try SpeakerAnalyzer(networks: networks).analyze(audio, settings: settings)
    let seconds = Double(audio.count) / 16_000
    FileHandle.standardError.write(Data(String(format: "audio %.1fs, load %.2fs, analyze %.2fs (RTF %.3f), %d turns, %d voices, %d utterances\n",
                                               seconds, load, result.processingSeconds, result.processingSeconds / max(seconds, 0.001),
                                               result.turns.count, result.voices.count, result.utterances.count).utf8))
    let json = try JSONEncoder.omi.encode(result)
    if let out = args.options["out"] {
        try json.write(to: URL(fileURLWithPath: out))
    } else {
        FileHandle.standardOutput.write(json)
    }
}

let args = Args(Array(CommandLine.arguments.dropFirst()), flagNames: [])
do {
    switch args.positional.first {
    case "simulate": try simulate(args)
    case "transcribe": try await transcribe(args)
    case "list": try list(args)
    case "decode": try decode(args)
    case "speakers": try await speakers(args)
    case "match":  // 開発用: iPhone の話者分離の結果に、学習した声で名前を当てる
        let device = try JSONDecoder.omi.decode(DeviceSpeakers.self, from: Data(contentsOf: URL(fileURLWithPath: args.positional[1])))
        let d = JSONDecoder.omi
        d.keyDecodingStrategy = .convertFromSnakeCase
        let library = try d.decode(VoiceLibrary.self, from: Data(contentsOf: URL(fileURLWithPath: args.positional[2])))
        let result = VoiceMatcher(library: library).match(device)
        let rows: [[String: Any]] = zip(device.utterances, result.utterances).map { u, r in
            ["start": u.start, "end": u.end, "label": u.label ?? "", "name": r.name ?? NSNull(), "speaker_id": r.speakerId ?? NSNull()]
        }
        let labels = result.labels.mapValues { ["name": $0.name ?? NSNull(), "speaker_id": $0.speakerId ?? NSNull()] as [String: Any] }
        let json = try JSONSerialization.data(withJSONObject: ["utterances": rows, "labels": labels], options: [.sortedKeys])
        FileHandle.standardOutput.write(json)
    case "voices-train":  // 開発用: 話者分離の結果のラベルに名前を付けて (S0=名前,...)、iPhone と同じ学習をする
        let device = try JSONDecoder.omi.decode(DeviceSpeakers.self, from: Data(contentsOf: URL(fileURLWithPath: args.positional[1])))
        var names: [String: String] = [:]
        for pair in args.positional[2].split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { names[kv[0]] = kv[1] }
        }
        let samples = device.utterances.compactMap { u -> VoiceTrainer.Sample? in
            guard let e = u.embedding?.values, let name = u.label.flatMap({ names[$0] }) else { return nil }
            return VoiceTrainer.Sample(embedding: e, person: name, weight: 3, confirmed: true)
        }
        guard let library = VoiceTrainer.train(samples: samples, background: []) else { throw CocoaError(.featureUnsupported) }
        FileHandle.standardError.write(Data("samples \(samples.count), people \(library.profiles.map { $0.name ?? "" })\n".utf8))
        FileHandle.standardOutput.write(try JSONEncoder.omi.encode(library))
    case "fbank":  // 開発用: Kaldi 互換 fbank を書き出す (比較用)
        let data = try Data(contentsOf: URL(fileURLWithPath: args.positional[1]))
        let audio = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let feats = KaldiFbank().compute(audio)
        try feats.withUnsafeBufferPointer { try Data(buffer: $0).write(to: URL(fileURLWithPath: args.positional[2])) }
    default: usage()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
