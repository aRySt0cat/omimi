import Foundation
import OmiKit

/// 用語集: 文字起こしのヒント・表示の補正・AI への添付に使う (iPhone に保存する)
extension AppModel {
    static var vocabularyURL: URL { URL.applicationSupportDirectory.appendingPathComponent("vocabulary.json") }

    static func loadVocabulary() -> [VocabularyEntry] {
        guard let data = try? Data(contentsOf: vocabularyURL) else { return [] }
        return (try? JSONDecoder.omi.decode([VocabularyEntry].self, from: data)) ?? []
    }

    var vocabularyCorrector: VocabularyCorrector { VocabularyCorrector(vocabulary) }

    private func storeVocabulary(_ entries: [VocabularyEntry]) {
        vocabulary = entries.sorted { $0.term.localizedStandardCompare($1.term) == .orderedAscending }
        if let data = try? JSONEncoder.omi.encode(vocabulary) {
            try? data.write(to: Self.vocabularyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        // iPhone の文字起こしにヒントとして渡す
        Prefs.defaults.set(vocabulary.map(\.term), forKey: "vocabularyTerms")
    }

    /// 追加 (id なし) または変更
    func saveVocabulary(id: Int?, _ input: VocabularyInput) throws {
        let term = input.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { throw VocabularyError("正しい表記を入れてください") }
        if vocabulary.contains(where: { $0.id != id && $0.term == term }) { throw VocabularyError("「\(term)」はもう登録してあります") }
        var entries = vocabulary
        let entry = VocabularyEntry(id: id ?? ((entries.map(\.id).max() ?? 0) + 1), term: term, reading: input.reading,
                                    aliases: input.aliases.filter { $0 != term }, note: input.note)
        if let i = entries.firstIndex(where: { $0.id == id }) { entries[i] = entry } else { entries.append(entry) }
        storeVocabulary(entries)
    }

    func deleteVocabulary(id: Int) {
        storeVocabulary(vocabulary.filter { $0.id != id })
    }
}

struct VocabularyError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
