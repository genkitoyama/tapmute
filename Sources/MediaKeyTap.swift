import Cocoa

/// Intercepts the EarPods center button (the play/pause media key).
///
/// The media key is a system-wide resource: taking it permanently would break music control.
/// The event is consumed only when onPlayPause returns true; otherwise it is passed downstream.
final class MediaKeyTap {

    enum Failure: Error, LocalizedError {
        case tapCreationFailed

        var errorDescription: String? {
            "イベントタップを作成できませんでした。「入力監視」の権限を確認してください。"
        }
    }

    /// Return true to consume the event, false to pass it downstream to the music app.
    var onPlayPause: (() -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Once a key down is consumed, the matching key up must be consumed too.
    /// Dropping only the down leaves downstream apps in an inconsistent state.
    private var swallowingUp = false

    private static let systemDefinedEventType: UInt32 = 14  // NX_SYSDEFINED
    private static let auxControlButtonsSubtype = 8         // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    private static let playKeyCode: Int32 = 16              // NX_KEYTYPE_PLAY

    var isRunning: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func start() throws {
        guard tap == nil else { return }

        let mask = CGEventMask(1 << MediaKeyTap.systemDefinedEventType)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // .listenOnly cannot consume events, which would mute and start the music at the same time.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: refcon
        ) else {
            throw Failure.tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        swallowingUp = false
    }

    /// The OS disables the tap when the callback is slow. Without re-enabling it the app goes silent after a few days.
    private func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("TapMute: イベントタップが無効化されたため再有効化しました")
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenable()
            return passThrough
        }

        guard type.rawValue == MediaKeyTap.systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == MediaKeyTap.auxControlButtonsSubtype
        else { return passThrough }

        let data1 = nsEvent.data1
        let keyCode = Int32((data1 & 0xFFFF_0000) >> 16)
        guard keyCode == MediaKeyTap.playKeyCode else { return passThrough }

        let keyFlags = data1 & 0x0000_FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0x1) == 1

        if !isDown {
            // Consume the up as a pair when the down was consumed
            let swallow = swallowingUp
            swallowingUp = false
            return swallow ? nil : passThrough
        }

        if isRepeat {
            return swallowingUp ? nil : passThrough
        }

        let handled = onPlayPause?() ?? false
        swallowingUp = handled
        return handled ? nil : passThrough
    }
}

/// A C function pointer cannot capture context, so the instance is recovered through refcon.
private let mediaKeyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}
