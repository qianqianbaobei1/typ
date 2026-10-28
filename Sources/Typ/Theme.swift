import AppKit
import SwiftUI

/// Warm, paper-like palette in the spirit of Anthropic's brand (clay accent, warm neutrals), light and dark.
enum Theme {
    private static func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(dark) : hex(light)
        })
    }

    // Surfaces, from the window base up to cards.
    static let sidebar = dynamic(0xF0EEE6, 0x1F1E1D)
    static let canvas = dynamic(0xFAF9F5, 0x262624)
    static let card = dynamic(0xFFFFFF, 0x30302E)
    static let cardHover = dynamic(0xF5F4EF, 0x393937)
    static let border = dynamic(0xE8E6DC, 0x3E3E3A)

    // Text.
    static let text = dynamic(0x141413, 0xFAF9F5)
    static let text2 = dynamic(0x5E5D59, 0xBFBDB6)
    static let text3 = dynamic(0x8F8D86, 0x8F8D86)

    // Accents.
    static let clay = Color(nsColor: hex(0xD97757))
    static let clayStrong = Color(nsColor: hex(0xC6613F))
    static let clayTint = dynamic(0xF8E9E2, 0x4A3329)
    static let blue = Color(nsColor: hex(0x6A9BCC))
    static let green = Color(nsColor: hex(0x788C5D))
    static let ink = Color(nsColor: hex(0x141413))
    static let paper = Color(nsColor: hex(0xFAF9F5))

    static func accent(for mode: Mode) -> Color {
        switch mode {
        case .dictate: return clay
        case .translate: return blue
        case .ask: return green
        }
    }

    // Typography: serif display for headings, system sans for UI.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - Components

struct CardBackground: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.03), radius: 2, y: 1)
    }
}

extension View {
    func typCard(padding: CGFloat = 16) -> some View { modifier(CardBackground(padding: padding)) }
}

struct ClayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(configuration.isPressed ? Theme.clayStrong : Theme.clay))
    }
}

struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(configuration.isPressed ? Theme.border : Theme.cardHover))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
    }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border))
            .shadow(color: Theme.border, radius: 0, y: 1.5)
    }
}

struct PageHeader: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.display(28)).foregroundStyle(Theme.text)
            if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.text2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Typ's mark: displays the official Typeless mark (logo.png) if present, or fallback.
struct TypMark: View {
    var size: CGFloat = 28

    var body: some View {
        if let img = Self.iconImage {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            fallback
        }
    }

    private static let iconImage: NSImage? = {
        if let url = Bundle.main.url(forResource: "logo", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let url = Bundle.main.url(forResource: "mushroom", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return nil
    }()

    private var fallback: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.clay)
            .frame(width: size, height: size)
            .overlay(
                HStack(spacing: size * 0.08) {
                    ForEach([0.34, 0.6, 0.42], id: \.self) { h in
                        Capsule().fill(Theme.paper).frame(width: size * 0.1, height: size * h)
                    }
                }
            )
    }
}

/// Hero illustration for the home page: a warm sun with sound ripples, gently breathing.
struct VoiceIllustration: View {
    @StateObject private var phase = Box(false)

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .strokeBorder(Theme.clay.opacity(0.22 - Double(i) * 0.06), lineWidth: 1.5)
                    .frame(width: 92 + CGFloat(i) * 34, height: 92 + CGFloat(i) * 34)
                    .scaleEffect(phase.value ? 1.04 : 0.97)
                    .animation(.easeInOut(duration: 2.4).repeatForever().delay(Double(i) * 0.25), value: phase.value)
            }
            Circle()
                .fill(RadialGradient(colors: [Theme.clay.opacity(0.95), Theme.clayStrong], center: .topLeading,
                                     startRadius: 4, endRadius: 70))
                .frame(width: 76, height: 76)
                .shadow(color: Theme.clay.opacity(0.35), radius: 14, y: 6)
            HStack(spacing: 4) {
                ForEach(Array([0.32, 0.6, 0.85, 0.5, 0.28].enumerated()), id: \.offset) { i, h in
                    Capsule().fill(Theme.paper)
                        .frame(width: 4, height: 34 * h * (phase.value ? 1 : 0.7))
                        .animation(.easeInOut(duration: 0.9).repeatForever().delay(Double(i) * 0.12), value: phase.value)
                }
            }
        }
        .frame(width: 170, height: 170)
        .onAppear { phase.value = true }
    }
}
