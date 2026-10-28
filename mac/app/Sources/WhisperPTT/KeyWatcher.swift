import CoreGraphics
import Foundation

/// Hears the trigger key in every app through a listen-only event tap, which macOS allows
/// once the app has Input Monitoring (or Accessibility). Pressing any other key while the
/// trigger is held reports .otherKey, so Option still types accents and symbols.
final class KeyWatcher {
    enum Event { case down, up, otherKey }

    /// Marks the events this app posts itself (its Cmd+V), so they never count as typing.
    static let ownEvents: Int64 = 0x5750_5454
    /// The left/right bits of every modifier in CGEventFlags.
    private static let modifierBits: UInt64 = 0x207F

    var onEvent: (Event) -> Void = { _ in }
    private(set) var isDown = false
    var isRunning: Bool { tap != nil }

    private let key: TriggerKey
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var flags: UInt64 = 0

    init(key: TriggerKey) {
        self.key = key
    }

    /// False while macOS does not allow it yet; call again once it does.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue | 1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, watcher in
                Unmanaged<KeyWatcher>.fromOpaque(watcher!).takeUnretainedValue().handle(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isDown = false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let now = event.flags.rawValue
            defer { flags = now }
            if event.getIntegerValueField(.keyboardEventKeycode) == key.keyCode {
                let down = now & key.flag != 0
                if down != isDown {
                    isDown = down
                    onEvent(down ? .down : .up)
                }
            } else if isDown, now & ~flags & Self.modifierBits != 0 {
                onEvent(.otherKey)          // another modifier went down
            }
        case .keyDown:
            if isDown, event.getIntegerValueField(.eventSourceUserData) != Self.ownEvents {
                onEvent(.otherKey)
            }
        default:
            break
        }
    }
}
