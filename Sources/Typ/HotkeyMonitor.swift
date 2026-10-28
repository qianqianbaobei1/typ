import AppKit
import CoreGraphics

/// Global listener for modifier chords (incl. fn) and key presses, via a CGEventTap.
/// An active tap needs only the Accessibility permission (a listen-only tap would need Input Monitoring).
/// Every event is passed through unchanged.
final class HotkeyMonitor {
    var onPressedChange: ((Set<Int64>) -> Void)?
    var onKeyDown: ((Int64) -> Void)?
    /// Asked for every real (non-synthetic) key press; returning true swallows the event.
    var interceptKeyDown: ((Int64, CGEventFlags) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var pressed = Set<Int64>()

    /// Device-dependent modifier flag bits, so left and right keys can be told apart.
    static let masks: [Int64: UInt64] = [
        56: 0x2, 60: 0x4,          // shift L/R
        59: 0x1, 62: 0x2000,       // control L/R
        58: 0x20, 61: 0x40,        // option L/R
        55: 0x8, 54: 0x10,         // command L/R
        63: 0x800000,              // fn
    ]

    /// Virtual keycodes for mouse buttons (aligning with official Typeless libKeyboardHelper MouseButton2, 3, 4)
    static let mouseButton2: Int64 = 0x1002 // Middle button (滚轮中键)
    static let mouseButton3: Int64 = 0x1003 // Side Back button (侧后退键)
    static let mouseButton4: Int64 = 0x1004 // Side Forward button (侧前进键)

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon,
               Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event) {
                return nil // swallowed
            }
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    /// Returns true when the event should be swallowed.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let raw = event.flags.rawValue
            var p = pressed
            if let m = Self.masks[code] {
                if raw & m != 0 { p.insert(code) } else { p.remove(code) }
            }
            p = p.filter { raw & (Self.masks[$0] ?? 0) != 0 }
            if p != pressed {
                pressed = p
                onPressedChange?(p)
            }
        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == TextInserter.marker { return false }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
               interceptKeyDown?(code, event.flags) == true {
                return true
            }
            onKeyDown?(code)
        case .otherMouseDown:
            let btn = event.getIntegerValueField(.mouseEventButtonNumber)
            let code: Int64? = switch btn {
            case 2: Self.mouseButton2
            case 3: Self.mouseButton3
            case 4: Self.mouseButton4
            default: nil
            }
            if let code {
                var p = pressed
                p.insert(code)
                if p != pressed {
                    pressed = p
                    onPressedChange?(p)
                }
                onKeyDown?(code)
            }
        case .otherMouseUp:
            let btn = event.getIntegerValueField(.mouseEventButtonNumber)
            let code: Int64? = switch btn {
            case 2: Self.mouseButton2
            case 3: Self.mouseButton3
            case 4: Self.mouseButton4
            default: nil
            }
            if let code {
                var p = pressed
                p.remove(code)
                if p != pressed {
                    pressed = p
                    onPressedChange?(p)
                }
            }
        default:
            break
        }
        return false
    }
}
