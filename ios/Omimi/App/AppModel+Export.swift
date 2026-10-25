import Foundation
import OmiKit

/// 録音と文字起こしの書き出し (PC での分析用)。zip にして、共有シート (AirDrop・ファイル など) で渡す
extension AppModel {
    enum ExportKind: Equatable {
        case audio(OmiExport.AudioFormat)
        case transcripts

        var title: String {
            switch self {
            case .audio: "音声"
            case .transcripts: "文字起こし"
            }
        }
    }

    /// 書き出す録音
    func exportSegments(interval: DateInterval?, includeSilent: Bool) -> [SegmentMetadata] {
        OmiExport.select(store.all(), interval: interval, includeSilent: includeSilent)
    }

    /// 書き出して zip を作る (重いので裏で行う)。進み具合は (済んだ数, 全部)
    func export(_ kind: ExportKind, interval: DateInterval?, includeSilent: Bool, label: String,
                progress: @escaping @Sendable (Int, Int) -> Void) async throws -> URL {
        let segments = exportSegments(interval: interval, includeSilent: includeSilent)
        guard !segments.isEmpty else { throw ExportError("この期間に書き出せる録音がありません") }
        let store = self.store, markers = self.markers, corrector = vocabularyCorrector
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
        // 前に書き出したものは消す (共有し終えたもの)
        try? FileManager.default.removeItem(at: root)
        let dir = root.appendingPathComponent("Omimi \(kind.title) \(label)", isDirectory: true)
        return try await Task.detached(priority: .userInitiated) {
            switch kind {
            case let .audio(format):
                _ = try OmiExport.audio(segments, store: store, format: format, to: dir, progress: progress)
            case .transcripts:
                progress(0, 1)
                _ = try OmiExport.transcripts(segments, markers: markers, corrector: corrector, to: dir)
                progress(1, 1)
            }
            let zip = try OmiExport.zip(dir)
            try? FileManager.default.removeItem(at: dir)
            return zip
        }.value
    }
}

struct ExportError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
