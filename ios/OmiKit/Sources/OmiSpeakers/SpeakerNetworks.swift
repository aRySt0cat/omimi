import CoreML
import Foundation

public enum SpeakerNetworkError: Error, LocalizedError {
    case modelMissing(String)
    case badOutput(String)

    public var errorDescription: String? {
        switch self {
        case let .modelMissing(name): "話者のモデル (\(name)) が見つかりません"
        case let .badOutput(detail): "話者のモデルの出力が不正です (\(detail))"
        }
    }
}

/// 話者分離の 2 つのモデル (Core ML)。自宅サーバの sherpa-onnx と同じモデルを変換したもの。
/// 1 つのタスクから順に使う (同時に呼ばない)。
public final class SpeakerNetworks: @unchecked Sendable {
    /// 区切り用モデルの窓 (10 秒) とずらし幅 (1 秒)
    public static let windowSize = 160_000
    public static let windowShift = 16_000
    public static let sampleRate = 16_000
    /// 1 窓の出力フレーム数と、フレームのずらし幅・受容野 (サンプル)
    public static let framesPerWindow = 589
    public static let receptiveFieldShift = 270
    public static let receptiveFieldSize = 991
    public static let classes = 7
    public static let embeddingDim = 256
    /// 声の特徴を取れる長さ (fbank のフレーム数)。これより短いとサーバでも取れない (NaN)
    public static let minEmbeddingFrames = 9
    public static let maxEmbeddingFrames = 6000
    static let segmentationBatch = 8

    private let segmentation: MLModel
    private let embedding: MLModel
    private let fbank = KaldiFbank()

    /// - Parameters: コンパイル済み (.mlmodelc) のモデル
    public init(segmentationURL: URL, embeddingURL: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        segmentation = try MLModel(contentsOf: segmentationURL, configuration: config)
        embedding = try MLModel(contentsOf: embeddingURL, configuration: config)
    }

    /// アプリに同梱したモデル
    public static func bundled(in bundle: Bundle = .main, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws -> SpeakerNetworks {
        guard let seg = bundle.url(forResource: "SpeakerSegmentation", withExtension: "mlmodelc") else {
            throw SpeakerNetworkError.modelMissing("SpeakerSegmentation")
        }
        guard let emb = bundle.url(forResource: "SpeakerEmbedding", withExtension: "mlmodelc") else {
            throw SpeakerNetworkError.modelMissing("SpeakerEmbedding")
        }
        return try SpeakerNetworks(segmentationURL: seg, embeddingURL: emb, computeUnits: computeUnits)
    }

    /// 10 秒ずつの音声 (各 160000 サンプル) → 窓ごとの (589 × 7) 対数確率
    func segment(_ chunks: [[Float]]) throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(chunks.count)
        var i = 0
        while i < chunks.count {
            // モデルが受け付ける束は 1 か 8。8 未満の残りは 1 つずつ
            let size = chunks.count - i >= Self.segmentationBatch ? Self.segmentationBatch : 1
            let batch = chunks[i..<(i + size)]
            let input = try MLMultiArray(shape: [NSNumber(value: size), 1, NSNumber(value: Self.windowSize)], dataType: .float32)
            let p = input.dataPointer.bindMemory(to: Float.self, capacity: size * Self.windowSize)
            for (b, chunk) in batch.enumerated() {
                precondition(chunk.count == Self.windowSize)
                chunk.withUnsafeBufferPointer { src in
                    (p + b * Self.windowSize).update(from: src.baseAddress!, count: Self.windowSize)
                }
            }
            let result = try segmentation.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": input]))
            guard let y = result.featureValue(for: "log_probs")?.multiArrayValue, y.shape.count == 3,
                  y.shape[0].intValue == size, y.shape[1].intValue == Self.framesPerWindow,
                  y.shape[2].intValue == Self.classes else {
                throw SpeakerNetworkError.badOutput("segmentation")
            }
            let values = y.floatValues()
            let per = Self.framesPerWindow * Self.classes
            for b in 0..<size { out.append(Array(values[(b * per)..<((b + 1) * per)])) }
            i += size
        }
        return out
    }

    /// 音声 (16 kHz, -1〜1) の声の特徴 (正規化していない 256 次元)。短すぎる・計算できないときは nil
    public func embed(_ samples: [Float]) throws -> [Float]? {
        var frames = KaldiFbank.frameCount(samples: samples.count)
        guard frames >= Self.minEmbeddingFrames else { return nil }
        var feats = fbank.compute(samples)
        if frames > Self.maxEmbeddingFrames {
            frames = Self.maxEmbeddingFrames
            feats.removeLast(feats.count - frames * KaldiFbank.bins)
        }
        let input = try MLMultiArray(shape: [1, NSNumber(value: frames), NSNumber(value: KaldiFbank.bins)], dataType: .float32)
        let p = input.dataPointer.bindMemory(to: Float.self, capacity: feats.count)
        feats.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: feats.count) }
        let result = try embedding.prediction(from: MLDictionaryFeatureProvider(dictionary: ["feats": input]))
        guard let y = result.featureValue(for: "embedding")?.multiArrayValue, y.count == Self.embeddingDim else {
            throw SpeakerNetworkError.badOutput("embedding")
        }
        let v = y.floatValues()
        return v.contains(where: { !$0.isFinite }) ? nil : v
    }
}

extension MLMultiArray {
    /// 値を行優先で取り出す (半精度・パディングのある配置にも対応)
    func floatValues() -> [Float] {
        let shape = self.shape.map(\.intValue)
        let strides = self.strides.map(\.intValue)
        var out = [Float](repeating: 0, count: count)
        var index = [Int](repeating: 0, count: shape.count)
        func read<T>(_: T.Type, _ convert: (T) -> Float) {
            let p = dataPointer.bindMemory(to: T.self, capacity: 1)
            for k in 0..<count {
                var offset = 0
                for d in 0..<shape.count { offset += index[d] * strides[d] }
                out[k] = convert(p[offset])
                var d = shape.count - 1
                while d >= 0 {
                    index[d] += 1
                    if index[d] < shape[d] { break }
                    index[d] = 0
                    d -= 1
                }
            }
        }
        switch dataType {
        case .float16: read(Float16.self) { Float($0) }
        case .double: read(Double.self) { Float($0) }
        case .int32: read(Int32.self) { Float($0) }
        default: read(Float.self) { $0 }
        }
        return out
    }
}
