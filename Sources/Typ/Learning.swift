import AppKit
import ApplicationServices
import Carbon

/// After Typ inserts text, keeps reading that field (every 0.7 s for 90 s) and remembers the latest version
/// of each inserted passage as the user edits it. Several insertions into the same field are tracked together,
/// so fixing an earlier sentence after dictating more still counts. When a passage disappears (sent or cleared)
/// or its watch ends, its last edited version is reported so Typ can learn from the correction.
/// Fields that can't be read (or stop being readable) fall back to reading the box with ⌘A ⌘C when Enter sends it.
@MainActor
final class EditWatcher {
    var onCorrection: ((_ inserted: String, _ edited: String) -> Void)?

    private struct Pending {
        let element: AXUIElement
        let inserted: String
        let app: String
        let pid: pid_t
        let started = Date()
        var lastEdited: String?
        var readable = false
        var misses = 0
    }
    private var pendings: [Pending] = []
    private var timer: Timer?

    private struct Blind {
        let inserted: String
        let app: String
        let pid: pid_t
        let started = Date()
    }
    private var blinds: [Blind] = []
    /// Keys typed in the app since its first unreadable insertion, and the last one.
    private var typed = 0
    private var lastCode: Int64 = -1

    var copyBeforeSend = true
    private let interval = 0.7
    private let duration = 90.0
    private let maxTracked = 6

    func watch(element: AXUIElement?, pid: pid_t, inserted: String, app: String, allowRead: Bool = true) {
        guard allowRead else { return }
        // Passages in another app can't be edited alongside this one: settle them now.
        settle(where: { $0 != pid }, reason: "switched app")
        guard inserted.count >= 2 else { return }
        // Accessibility searches can take a while; keep them off the main thread (it also serves the hotkey tap).
        Task.detached(priority: .utility) { [weak self] in
            var target = element
            if target == nil || !(AX.string(target!, kAXValueAttribute) ?? "").contains(String(inserted.prefix(30))) {
                // The app didn't report its focused field (or reported another one): find the field holding our text.
                let (found, summary) = AX.findField(pid: pid, containing: inserted)
                Log.write("learn: searched \(app) window for the field: \(found == nil ? "not found" : "found") (\(summary))")
                if found != nil { target = found }
            }
            let resolved = target
            await self?.registerField(resolved: resolved, inserted: inserted, app: app, pid: pid)
        }
    }

    private func registerField(resolved: AXUIElement?, inserted: String, app: String, pid: pid_t) {
        if let resolved {
            pendings.append(Pending(element: resolved, inserted: inserted, app: app, pid: pid))
            if pendings.count > maxTracked { finalize(pendings.removeFirst(), reason: "too many") }
            Log.write("learn: watching field in \(app) (\(pendings.count) passage(s))")
            startTimer()
        } else {
            addBlind(Blind(inserted: inserted, app: app, pid: pid))
        }
    }

    /// Called right before a new dictation starts: drops watches that ran out of time.
    func check() { expire() }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func addBlind(_ b: Blind) {
        guard copyBeforeSend else {
            Log.write("learn: not watching (no readable field) in \(b.app)")
            return
        }
        if !blinds.contains(where: { $0.pid == b.pid }) {
            typed = 0
            lastCode = -1
        }
        blinds.append(b)
        if blinds.count > maxTracked { blinds.removeFirst() }
        Log.write("learn: \(b.app) field unreadable, will read it when you press Enter (within \(Int(duration))s)")
    }

    private func poll() {
        expire()
        var keep: [Pending] = []
        for var p in pendings {
            guard let value = AX.string(p.element, kAXValueAttribute) else {
                // Some apps drop out of Accessibility now and then; give it a few tries before falling back.
                p.misses += 1
                if p.misses < 4 { keep.append(p); continue }
                if let edited = p.lastEdited, edited != p.inserted {
                    finalize(p, reason: "field stopped answering")
                } else {
                    Log.write("learn: \(p.app) field stopped answering, switching to read-on-Enter")
                    addBlind(Blind(inserted: p.inserted, app: p.app, pid: p.pid))
                }
                continue
            }
            p.misses = 0
            p.readable = true
            if value.contains(p.inserted) {
                p.lastEdited = nil // untouched (or edits undone)
                keep.append(p)
            } else if let edited = Self.locate(p.inserted, in: value), Self.similarity(p.inserted, edited) >= 0.6 {
                if edited != p.lastEdited { Log.write("learn: edit seen in \(p.app): \(edited.prefix(80))") }
                p.lastEdited = edited
                keep.append(p)
            } else {
                finalize(p, reason: "passage no longer in field (sent or cleared)")
            }
        }
        pendings = keep
        if pendings.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func expire() {
        let now = Date()
        for p in pendings where now.timeIntervalSince(p.started) > duration { finalize(p, reason: "timeout") }
        pendings.removeAll { now.timeIntervalSince($0.started) > duration }
        let stale = blinds.filter { now.timeIntervalSince($0.started) > duration }
        for b in stale { Log.write("learn: \(b.app) watch ended (timeout)") }
        blinds.removeAll { now.timeIntervalSince($0.started) > duration }
    }

    private func settle(where matches: (pid_t) -> Bool, reason: String) {
        for p in pendings where matches(p.pid) { finalize(p, reason: reason) }
        pendings.removeAll { matches($0.pid) }
        blinds.removeAll { matches($0.pid) }
    }

    private func finalize(_ p: Pending, reason: String) {
        if let edited = p.lastEdited, edited != p.inserted {
            let mod = Self.analysisModification(original: p.inserted, current: edited)
            if mod.isLargeModify {
                Log.write("learn: skipped large modification in \(p.app) (+\(mod.addedCount), -\(mod.removedCount), changed \(mod.changedCount))")
                return
            }
            Log.write("learn: correction captured (\(reason)) in \(p.app) (diff: +\(mod.addedCount) -\(mod.removedCount)): \"\(p.inserted.prefix(60))\" -> \"\(edited.prefix(60))\"")
            onCorrection?(p.inserted, edited)
        } else if !p.readable {
            Log.write("learn: \(p.app) field not readable via Accessibility, can't learn there")
        } else {
            Log.write("learn: no correction (\(reason)) in \(p.app)")
        }
    }

    // MARK: Read on Enter

    private static let letterKeys: Set<Int64> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 31, 32, 34, 35, 37, 38, 40, 45, 46]

    private static var inputMethodActive: Bool {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return type == (kTISTypeKeyboardInputMode as String)
    }

    /// Called for every real key press. Returns true when the Enter press is taken over to read the box first.
    func intercept(_ code: Int64, _ flags: CGEventFlags) -> Bool {
        let isEnter = code == 36 || code == 76
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Readable fields: take one last look right before Enter sends, so a quick fix-and-send isn't missed.
        if isEnter, pendings.contains(where: { $0.pid == front }) { poll() }

        guard let front, blinds.contains(where: { $0.pid == front }) else { return false }
        expire()
        guard blinds.contains(where: { $0.pid == front }) else { return false }
        guard isEnter else {
            typed += 1
            lastCode = code
            return false
        }
        // Shift/⌘/⌥/⌃+Enter usually means "new line" — leave it alone.
        if !flags.intersection([.maskShift, .maskCommand, .maskAlternate, .maskControl]).isEmpty { return false }
        let app = blinds.first { $0.pid == front }?.app ?? "?"
        guard typed > 0 else {
            blinds.removeAll { $0.pid == front }
            Log.write("learn: sent without edits in \(app)")
            return false
        }
        // Enter right after a letter with a Chinese/Japanese input method usually commits the typed letters
        // rather than sending. Let it through and keep waiting for the Enter that actually sends.
        if Self.letterKeys.contains(lastCode) && Self.inputMethodActive {
            lastCode = code
            Log.write("learn: Enter in \(app) likely committed input-method text, waiting for the sending Enter")
            return false
        }
        let group = blinds.filter { $0.pid == front }
        blinds.removeAll { $0.pid == front }
        typed = 0
        lastCode = -1
        Task { @MainActor in
            let copied = await TextInserter.copyAllInFocusedField()
            TextInserter.postKey(36, flags: []) // send the message
            self.learnFromCopy(copied, group: group)
        }
        return true
    }

    private func learnFromCopy(_ copied: String?, group: [Blind]) {
        let app = group.first?.app ?? "?"
        guard let copied, !copied.isEmpty else {
            Log.write("learn: couldn't read \(app) input box")
            return
        }
        for b in group {
            if copied.contains(b.inserted) {
                Log.write("learn: no correction in \(app) (read before send): \(b.inserted.prefix(40))")
                continue
            }
            guard let edited = Self.locate(b.inserted, in: copied), edited != b.inserted,
                  Self.similarity(b.inserted, edited) >= 0.6 else {
                Log.write("learn: \(app) text changed too much to compare: \(b.inserted.prefix(40))")
                continue
            }
            let mod = Self.analysisModification(original: b.inserted, current: edited)
            if mod.isLargeModify {
                Log.write("learn: skipped large modification in \(app) (+\(mod.addedCount), -\(mod.removedCount))")
                continue
            }
            Log.write("learn: correction captured (read before send) in \(app) (diff: +\(mod.addedCount) -\(mod.removedCount)): \"\(b.inserted.prefix(60))\" -> \"\(edited.prefix(60))\"")
            onCorrection?(b.inserted, edited)
        }
    }

    /// Finds the region of `value` that most likely is the (edited) inserted text.
    /// Anchors on the passage's start and end; if one of them was edited, falls back to the other alone.
    static func locate(_ inserted: String, in value: String) -> String? {
        let n = inserted.count
        guard n >= 4 else { return nil }
        let k = min(8, max(2, n / 4))
        let head = String(inserted.prefix(k)), tail = String(inserted.suffix(k))
        let chars = Array(value)
        var candidates: [String] = []

        func ranges(of needle: String) -> [Range<String.Index>] {
            var out: [Range<String.Index>] = []
            var search = value.startIndex..<value.endIndex
            while let r = value.range(of: needle, range: search) {
                out.append(r)
                search = r.upperBound..<value.endIndex
            }
            return out
        }
        let heads = ranges(of: head), tails = ranges(of: tail)
        for h in heads {
            if let t = tails.first(where: { $0.lowerBound >= h.upperBound }) {
                candidates.append(String(value[h.lowerBound..<t.upperBound]))
            }
        }
        if candidates.isEmpty {
            // One edge was edited: try windows of about the original length from the other edge.
            let spread = max(3, n / 5)
            for h in heads {
                let s = value.distance(from: value.startIndex, to: h.lowerBound)
                for len in max(1, n - spread)...(n + spread) where s + len <= chars.count {
                    candidates.append(String(chars[s..<(s + len)]))
                }
            }
            for t in tails {
                let e = value.distance(from: value.startIndex, to: t.upperBound)
                for len in max(1, n - spread)...(n + spread) where e - len >= 0 {
                    candidates.append(String(chars[(e - len)..<e]))
                }
            }
        }
        return candidates
            .filter { Double($0.count) >= Double(n) * 0.5 && Double($0.count) <= Double(n) * 1.6 }
            .max { similarity(inserted, $0) < similarity(inserted, $1) }
    }

    /// 1 − normalized edit distance over characters.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        if x.count * y.count > 4_000_000 { return 0 }
        var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// Character-level diff metrics aligning with official Typeless analysisModification algorithm.
    struct ModificationResult {
        let isLargeModify: Bool
        let addedCount: Int
        let removedCount: Int
        let changedCount: Int
    }

    /// Analyses the diff between original text and user edited text.
    /// Filters out large modifications (e.g. user select-all replaced or cleared the whole box).
    static func analysisModification(original: String, current: String) -> ModificationResult {
        let origChars = Array(original.prefix(1000))
        let currChars = Array(current.prefix(1000))
        guard !origChars.isEmpty else {
            return ModificationResult(isLargeModify: false, addedCount: currChars.count, removedCount: 0, changedCount: currChars.count)
        }
        if currChars.isEmpty {
            return ModificationResult(isLargeModify: true, addedCount: 0, removedCount: origChars.count, changedCount: origChars.count)
        }

        // Longest Common Subsequence (LCS) to compute precise character-level additions and deletions
        let m = origChars.count, n = currChars.count
        var dp = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            var prevDiag = 0
            for j in 1...n {
                let temp = dp[j]
                if origChars[i - 1] == currChars[j - 1] {
                    dp[j] = prevDiag + 1
                } else {
                    dp[j] = max(dp[j], dp[j - 1])
                }
                prevDiag = temp
            }
        }
        let lcs = dp[n]
        let removed = m - lcs
        let added = n - lcs
        let changed = added + removed

        // Large modification threshold matching official Typeless:
        // 1. Current text less than 20% of original
        // 2. Removed text greater than 50% of original
        // 3. Changed text greater than 200% of original
        let isLarge = Double(n) < Double(m) * 0.2
            || Double(removed) > Double(m) * 0.5
            || changed > m * 2

        return ModificationResult(isLargeModify: isLarge, addedCount: added, removedCount: removed, changedCount: changed)
    }
}

struct EditExample: Codable, Hashable {
    var before: String
    var after: String
}

/// Personal writing style learned from the user's dictations and corrections.
@MainActor
final class StyleProfile: ObservableObject {
    private struct Stored: Codable {
        var profile: String
        var examples: [EditExample]
        var sinceUpdate: Int
        var updatedAt: Date?
        var totalDictations: Int?
        var totalModifications: Int?
    }

    @Published private(set) var profile = ""
    @Published private(set) var examples: [EditExample] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var updating = false
    @Published private(set) var totalDictations: Int = 0
    @Published private(set) var totalModifications: Int = 0
    private var sinceUpdate = 0
    private let url = Paths.support.appendingPathComponent("style.json")

    /// Dictation adoption rate (1 - corrections / total), aligned with Typeless telemetry metrics.
    var adoptionRate: Double {
        guard totalDictations > 0 else { return 1.0 }
        let retained = max(0, totalDictations - totalModifications)
        return Double(retained) / Double(totalDictations)
    }

    /// New dictations needed before the profile is refreshed.
    let refreshEvery = 15

    init() {
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            profile = s.profile
            examples = s.examples
            sinceUpdate = s.sinceUpdate
            updatedAt = s.updatedAt
            totalDictations = s.totalDictations ?? 0
            totalModifications = s.totalModifications ?? 0
        }
    }

    private func save() {
        let s = Stored(profile: profile, examples: examples, sinceUpdate: sinceUpdate, updatedAt: updatedAt,
                       totalDictations: totalDictations, totalModifications: totalModifications)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }

    func addExample(before: String, after: String) {
        totalModifications += 1
        examples.removeAll { $0.before == before }
        examples.insert(EditExample(before: String(before.prefix(400)), after: String(after.prefix(400))), at: 0)
        if examples.count > 8 { examples.removeLast(examples.count - 8) }
        save()
    }

    func reset() {
        profile = ""
        examples = []
        sinceUpdate = 0
        totalDictations = 0
        totalModifications = 0
        updatedAt = nil
        save()
    }

    /// Counts a dictation and refreshes the profile once enough new material exists.
    func didDictate(history: [HistoryItem], llm: LLMClient?) {
        totalDictations += 1
        sinceUpdate += 1
        save()
        if sinceUpdate >= refreshEvery || (profile.isEmpty && history.count >= 10) {
            Task { await refresh(history: history, llm: llm) }
        }
    }

    func refresh(history: [HistoryItem], llm: LLMClient?) async {
        guard let llm, !updating else { return }
        let samples = history.filter { $0.error == nil && $0.mode != .ask && !$0.text.isEmpty }.prefix(40)
        guard samples.count >= 5 else { return }
        updating = true
        defer { updating = false }
        let corpus = samples.enumerated().map { "[\($0.offset + 1)] (\($0.element.appName)) \($0.element.text.prefix(300))" }.joined(separator: "\n")
        let edits = examples.prefix(6).map { "- Typ wrote: \($0.before)\n  User changed it to: \($0.after)" }.joined(separator: "\n")
        do {
            let result = try await llm.chat(system: Prompts.styleProfile, user: """
                <recent_texts>
                \(corpus)
                </recent_texts>
                <user_corrections>
                \(edits.isEmpty ? "(none)" : edits)
                </user_corrections>
                """, temperature: 0.2)
            profile = Prompts.tidy(result)
            sinceUpdate = 0
            updatedAt = Date()
            save()
        } catch {
            NSLog("Typ: style profile refresh failed: \(error)")
        }
    }
}
