import AppKit
import SwiftUI

// MARK: - Floating recording capsule

@MainActor
final class BarModel: ObservableObject {
    enum Phase: Equatable {
        case hidden, recording, processing
        case message(String, isError: Bool)
    }

    @Published var phase: Phase = .hidden
    @Published var mode: Mode = .dictate
    @Published var handsFree = false
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 28)
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    func push(level: Float) {
        let v = min(1, CGFloat(level).squareRoot() * 3.2)
        levels.removeFirst()
        levels.append(v)
    }

    func resetLevels() { levels = Array(repeating: 0, count: levels.count) }

    /// Smoothed current loudness, 0…1.
    var loudness: CGFloat { levels.suffix(4).reduce(0, +) / 4 }
}

/// Capsule palette: one clay accent on warm near-black, matching the main window.
enum Aura {
    static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    static let body = hex(0x1A1918)
    static let clay = hex(0xD97757)
    static let clayPressed = hex(0xC6613F)
    static let cream = hex(0xFAF9F5)
    static let hairline = Color.white.opacity(0.10)
}

struct BarView: View {
    @ObservedObject var model: BarModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: model.phase == .hidden)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            capsule(t)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .fixedSize()
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.phase)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.handsFree)
        }
    }

    private func capsule(_ t: Double) -> some View {
        content(t)
            .padding(.leading, model.phase == .recording ? 4 : 14)
            .padding(.trailing, model.phase == .recording ? (model.handsFree ? 4 : 12) : 14)
            .frame(height: model.phase == .recording ? 38 : 32)
            .background(Capsule().fill(Aura.body.opacity(0.97)))
            .overlay(Capsule().strokeBorder(Aura.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }

    @ViewBuilder private func content(_ t: Double) -> some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .recording:
            HStack(spacing: 7) {
                MicOrb(mode: model.mode, level: model.loudness, t: t)
                Spectrum(level: model.loudness, t: t)
                    .frame(width: model.handsFree ? 92 : 108, height: 26)
                if model.handsFree {
                    Button { model.onCancel?() } label: { Image(systemName: "xmark") }
                        .buttonStyle(GlassCircle())
                        .help("取消（Esc）")
                    Button { model.onStop?() } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(ClayCircle())
                        .help("完成")
                } else if model.mode != .dictate {
                    Text(model.mode.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Aura.cream.opacity(0.85))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
            }
        case .processing:
            HStack(spacing: 7) {
                ThinkingDots(t: t)
                Text(model.mode == .ask ? "思考中" : model.mode == .translate ? "翻译中" : "整理中")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Aura.cream.opacity(0.85))
            }
        case .message(let text, let isError):
            HStack(spacing: 6) {
                Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isError ? Aura.clay : Theme.green)
                Text(text).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    .foregroundStyle(Aura.cream.opacity(0.92))
                    .frame(maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Clay microphone dot. A soft ripple appears only while you're actually making sound.
struct MicOrb: View {
    let mode: Mode
    let level: CGFloat
    let t: Double

    var body: some View {
        let speaking = max(0, Double(level) - 0.12) / 0.88
        ZStack {
            let p = (t * 0.9).truncatingRemainder(dividingBy: 1)
            Circle()
                .stroke(Aura.clay.opacity((1 - p) * 0.55 * speaking), lineWidth: 1.4)
                .frame(width: 28, height: 28)
                .scaleEffect(1 + p * 0.35)
            Circle()
                .fill(Aura.clay)
                .frame(width: 28, height: 28)
            Image(systemName: mode == .dictate ? "mic.fill" : mode.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 30, height: 30)
    }
}

/// Cream bars, tall in the middle, following the voice level; the centre bars light up in clay.
struct Spectrum: View {
    let level: CGFloat
    let t: Double
    private let count = 17

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            HStack(alignment: .center, spacing: 2.4) {
                ForEach(0..<count, id: \.self) { i in
                    let x = Double(i) / Double(count - 1) - 0.5
                    let envelope = exp(-x * x / 0.07) * 0.88 + 0.12
                    let wobble = 0.6 + 0.4 * sin(t * (5 + Double(i % 5)) + Double(i) * 1.7)
                    let energy = 0.14 + 0.86 * Double(level)
                    let centre = abs(x) < 0.18
                    Capsule()
                        .fill(centre ? Aura.clay : Aura.cream.opacity(0.72))
                        .frame(width: centre ? 2.4 : 2, height: max(3, h * 0.98 * envelope * energy * wobble))
                        .opacity(abs(x) > 0.42 ? 0.55 : 1)
                }
            }
            .frame(width: geo.size.width, height: h)
        }
    }
}

/// Three clay dots rising one after another while the text is prepared.
struct ThinkingDots: View {
    let t: Double
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                let phase = (sin(t * 6 - Double(i) * 0.9) + 1) / 2
                Circle().fill(Aura.clay)
                    .frame(width: 5, height: 5)
                    .opacity(0.35 + 0.65 * phase)
                    .offset(y: -2 * phase)
            }
        }
        .frame(width: 24, height: 12)
    }
}

struct GlassCircle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Aura.cream.opacity(0.8))
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0.09)))
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
    }
}

struct ClayCircle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(configuration.isPressed ? Aura.clayPressed : Aura.clay))
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
    }
}

@MainActor
final class FloatingBar {
    let model = BarModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 70),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: BarView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
    }

    private func present() {
        hideWork?.cancel()
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 300, height: 60)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.minY + 8, width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    func showRecording(mode: Mode) {
        model.mode = mode
        model.resetLevels()
        model.phase = .recording
        present()
    }

    func refresh() {
        guard model.phase != .hidden else { return }
        present()
    }

    func showProcessing() {
        model.phase = .processing
        present()
    }

    func flash(_ text: String, isError: Bool = false, seconds: Double = 2.5) {
        model.phase = .message(text, isError: isError)
        present()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        model.phase = .hidden
        model.handsFree = false

        panel.orderOut(nil)
    }
}

// MARK: - Answer card (Ask anything)

struct AnswerView: View {
    let question: String
    let answer: String
    let onInsert: () -> Void
    let onClose: () -> Void
    @StateObject private var copied = Box(false)

    private var detectedLinks: [(title: String, url: URL)] {
        var links: [(title: String, url: URL)] = []
        let ns = answer as NSString
        let mdRegex = try? NSRegularExpression(pattern: #"(?:\[([^\]]+)\]\((https?://[^\s\)]+)\))"#, options: [])
        let matches = mdRegex?.matches(in: answer, range: NSRange(location: 0, length: ns.length)) ?? []
        for m in matches {
            let t = ns.substring(with: m.range(at: 1))
            let u = ns.substring(with: m.range(at: 2))
            if let url = URL(string: u) { links.append((t, url)) }
        }
        if links.isEmpty {
            let urlDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let rawMatches = urlDetector?.matches(in: answer, range: NSRange(location: 0, length: ns.length)) ?? []
            for m in rawMatches {
                if let url = m.url {
                    let host = url.host ?? url.absoluteString
                    links.append((host, url))
                }
            }
        }
        var seen = Set<String>()
        return links.filter { seen.insert($0.url.absoluteString).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TypMark(size: 22)
                Text("随便问 · 智能回答").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text3)
                        .frame(width: 22, height: 22).background(Circle().fill(Theme.cardHover))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("关闭（Esc）")
            }
            Text(question)
                .font(Theme.display(16))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            ScrollView {
                Text((try? AttributedString(markdown: answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(answer))
                    .font(.system(size: 13.5))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !detectedLinks.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("参考来源").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(detectedLinks, id: \.url) { item in
                                Button {
                                    NSWorkspace.shared.open(item.url)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "link").font(.system(size: 10))
                                        Text(item.title).lineLimit(1).font(.system(size: 11))
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Theme.cardHover))
                                    .foregroundStyle(Theme.clay)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text("\(answer.count) 字符").font(.system(size: 11)).foregroundStyle(Theme.text3)
                Spacer()
                Button(copied.value ? "已复制" : "复制") {
                    TextInserter.copyToClipboard(answer)
                    copied.value = true
                }
                .buttonStyle(SoftButtonStyle())
                .keyboardShortcut("c", modifiers: .command)
                .help("复制（⌘C）")

                Button("插入到光标处", action: onInsert)
                    .buttonStyle(ClayButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .help("插入（Return）")
            }
        }
        .padding(18)
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 520, minHeight: 200, maxHeight: 520)
        .background(Theme.canvas)
    }
}

@MainActor
final class AnswerPanel {
    private var panel: NSPanel?

    func show(question: String, answer: String) {
        close()
        // Dynamically scale window height based on answer content density
        let linesEstimate = answer.components(separatedBy: .newlines).count + (answer.count / 30)
        let dynamicHeight = min(500.0, max(240.0, 160.0 + CGFloat(linesEstimate) * 16.0))
        let width: CGFloat = 460.0

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: dynamicHeight),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: AnswerView(
            question: question, answer: answer,
            onInsert: { [weak self] in
                self?.close()
                Task { await TextInserter.paste(answer) }
            },
            onClose: { [weak self] in self?.close() }
        ))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vf.midX - width / 2, y: min(vf.maxY - dynamicHeight - 60, max(vf.minY + 60, vf.midY - dynamicHeight / 2))))
        }
        p.orderFrontRegardless()
        panel = p
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

/// View-local mutable state. Stands in for @State, whose macro plugin is not shipped with the Command Line Tools.
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}
