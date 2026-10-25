import Accelerate
import Foundation

/// 声の特徴のモデル (WeSpeaker) に入れる 80 次元の対数メルフィルタバンク。
/// 自宅サーバ (sherpa-onnx / kaldi-native-fbank) と同じ計算にする:
/// 16 kHz, 25 ms 窓 / 10 ms ずらし, 端は折り返し (snip_edges = false), 直流を除く, プリエンファシス 0.97,
/// povey 窓, 512 点 FFT のパワー, 20〜7600 Hz のメル 80 本, 自然対数。音声は ×32768 (normalize_samples = 0)。
public struct KaldiFbank: Sendable {
    public static let bins = 80
    static let frameLength = 400
    static let frameShift = 160
    static let fftLength = 512

    private let window: [Float]
    /// メルフィルタ (80 × 256, 行ごと)
    private let banks: [Float]

    public init() {
        let n = Self.frameLength
        let a = 2 * Double.pi / Double(n - 1)
        window = (0..<n).map { Float(pow(0.5 - 0.5 * cos(a * Double($0)), 0.85)) }
        banks = Self.melBanks()
    }

    /// 音声 (-1〜1) のフレーム数。末尾まで使う (Kaldi の flush と同じ)。
    public static func frameCount(samples: Int) -> Int {
        (samples + frameShift / 2) / frameShift
    }

    /// 特徴 (フレーム × 80, 行ごと)
    public func compute(_ samples: [Float]) -> [Float] {
        let frames = Self.frameCount(samples: samples.count)
        guard frames > 0 else { return [] }
        let n = Self.frameLength, half = Self.fftLength / 2
        var out = [Float](repeating: 0, count: frames * Self.bins)
        let log2n = vDSP_Length(9)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return out }
        defer { vDSP_destroy_fftsetup(setup) }

        var frame = [Float](repeating: 0, count: Self.fftLength)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        var mel = [Float](repeating: 0, count: Self.bins)
        let count = samples.count
        samples.withUnsafeBufferPointer { wave in
            for f in 0..<frames {
                // 窓の中心は f * 10 ms + 5 ms。範囲の外は端で折り返す
                let start = f * Self.frameShift + Self.frameShift / 2 - n / 2
                for s in 0..<n {
                    var i = start + s
                    while i < 0 || i >= count {
                        i = i < 0 ? -i - 1 : 2 * count - 1 - i
                    }
                    frame[s] = wave[i] * 32768
                }
                for s in n..<Self.fftLength { frame[s] = 0 }
                // 直流を除く → プリエンファシス → povey 窓
                var mean: Float = 0
                vDSP_meanv(frame, 1, &mean, vDSP_Length(n))
                for s in 0..<n { frame[s] -= mean }
                for s in stride(from: n - 1, to: 0, by: -1) { frame[s] -= 0.97 * frame[s - 1] }
                frame[0] -= 0.97 * frame[0]
                for s in 0..<n { frame[s] *= window[s] }

                // 実数 FFT (vDSP は 2 倍の値を返すので、パワーは 1/4 にする)
                real.withUnsafeMutableBufferPointer { re in
                    imag.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        frame.withUnsafeBufferPointer { p in
                            p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    }
                }
                // パワー (0〜255 番。real[0] は直流、imag[0] はナイキスト (使わない))
                power[0] = real[0] * real[0] / 4
                for k in 1..<half { power[k] = (real[k] * real[k] + imag[k] * imag[k]) / 4 }
                vDSP_mmul(banks, 1, power, 1, &mel, 1, vDSP_Length(Self.bins), 1, vDSP_Length(half))
                let base = f * Self.bins
                for b in 0..<Self.bins { out[base + b] = log(max(mel[b], Float.ulpOfOne)) }
            }
        }
        return out
    }

    /// Kaldi のメルフィルタ (三角形, メル尺度で等間隔)
    static func melBanks(bins: Int = bins, sampleRate: Double = 16_000, low: Double = 20, high: Double = -400) -> [Float] {
        let half = fftLength / 2
        func melScale(_ f: Double) -> Double { 1127 * log(1 + f / 700) }
        let nyquist = sampleRate / 2
        let highFreq = high <= 0 ? nyquist + high : high
        let binWidth = sampleRate / Double(fftLength)
        let melLow = melScale(low), melHigh = melScale(highFreq)
        let delta = (melHigh - melLow) / Double(bins + 1)
        var out = [Float](repeating: 0, count: bins * half)
        for b in 0..<bins {
            let left = melLow + Double(b) * delta, center = left + delta, right = center + delta
            for i in 0..<half {
                let m = melScale(binWidth * Double(i))
                guard m > left && m < right else { continue }
                out[b * half + i] = Float(m <= center ? (m - left) / (center - left) : (right - m) / (right - center))
            }
        }
        return out
    }
}
