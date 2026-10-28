import Foundation

/// Cheap local tidy-up for short, clean utterances that don't need the LLM.
enum LocalCleanup {
    static let fillers = ["嗯", "呃", "啊", "哎", "那个", "就是", "这个", "对吧", "怎么说呢", "然后",
                          "um", "uh", "like", "you know", "I mean"]
    static let corrections = ["不对", "我是说", "改成", "算了", "不是", "重新说", "actually", "no wait", "scratch that"]

    /// Returns the text to insert without polishing, or nil when the LLM should handle it.
    static func shortcut(_ raw: String, maxChars: Int) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= maxChars else { return nil }
        let lower = t.lowercased()
        if fillers.contains(where: { lower.contains($0.lowercased()) }) { return nil }
        if corrections.contains(where: { lower.contains($0.lowercased()) }) { return nil }
        return pangu(t)
    }

    /// Inserts a space between CJK and ASCII letters/digits.
    static func pangu(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"([\p{Han}])([A-Za-z0-9])"#, with: "$1 $2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"([A-Za-z0-9])([\p{Han}])"#, with: "$1 $2", options: .regularExpression)
        return t
    }
}
