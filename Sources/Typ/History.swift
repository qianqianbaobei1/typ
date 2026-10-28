import Foundation

struct HistoryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var mode: Mode
    var raw: String
    var text: String
    var appName: String
    var duration: Double
    var error: String?
    /// Per-stage latency after the key was released, e.g. "识别 0.4s · 润色 0.9s · 共 1.4s".
    var timing: String?
    /// Host webpage URL or domain where the text was inserted
    var url: String?
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [HistoryItem] = []
    private let limit = 3000

    init() {
        if let data = try? Data(contentsOf: Paths.history) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            items = (try? dec.decode([HistoryItem].self, from: data)) ?? []
        }
    }

    func add(_ item: HistoryItem, retentionDays: Int = 0) {
        items.insert(item, at: 0)
        if retentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(retentionDays * 86400))
            items.removeAll { $0.date < cutoff }
        }
        if items.count > limit { items.removeLast(items.count - limit) }
        save()
    }

    /// Automatically prunes records older than specified retention days (aligns with Typeless deleteByDuration).
    func prune(retentionDays: Int) {
        guard retentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays * 86400))
        let before = items.count
        items.removeAll { $0.date < cutoff }
        if items.count != before {
            save()
            Log.write("history: pruned \(before - items.count) items older than \(retentionDays) days")
        }
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(items) { try? data.write(to: Paths.history, options: .atomic) }
    }

    // MARK: - Stats

    /// CJK characters count as one word each; other scripts are split on whitespace.
    static func wordCount(_ s: String) -> Int {
        var count = 0
        var inWord = false
        for ch in s.unicodeScalars {
            if (0x4E00...0x9FFF).contains(ch.value) || (0x3040...0x30FF).contains(ch.value) || (0xAC00...0xD7AF).contains(ch.value) {
                count += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(ch) {
                if !inWord { count += 1; inWord = true }
            } else {
                inWord = false
            }
        }
        return count
    }

    var successful: [HistoryItem] { items.filter { $0.error == nil } }
    var totalWords: Int { successful.reduce(0) { $0 + Self.wordCount($1.text) } }
    var totalSeconds: Double { successful.reduce(0) { $0 + $1.duration } }
    var wordsPerMinute: Int { totalSeconds > 5 ? Int(Double(totalWords) / (totalSeconds / 60)) : 0 }
    /// Compared with standard typing speed baseline of 45 words per minute (aligns with official Typeless analytics).
    var minutesSaved: Int { max(0, Int(Double(totalWords) / 45.0 - totalSeconds / 60.0)) }
}
