import Cocoa

/// EarPods の中央ボタン（= メディアキーの再生/一時停止）を横取りする。
///
/// メディアキーは OS 全体で共有される資源なので、常時奪うと音楽の操作ができなくなる。
/// onPlayPause が true を返したときだけイベントを消費し、false なら下流にそのまま流す。
final class MediaKeyTap {

    enum Failure: Error, LocalizedError {
        case tapCreationFailed

        var errorDescription: String? {
            "イベントタップを作成できませんでした。「入力監視」の権限を確認してください。"
        }
    }

    /// true を返すとイベントを消費、false で下流（音楽アプリ）に流す。
    var onPlayPause: (() -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// キーダウンを消費したら、対になるキーアップも消費する。
    /// ダウンだけ消してアップを流すと下流のアプリが状態不整合を起こす。
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

        // .listenOnly ではイベントを消費できず、ミュートと同時に音楽が再生されてしまう。
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

    /// タップは処理が遅いと OS に無効化される。放置すると数日で沈黙するので必ず復帰させる。
    private func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("MeetMute: イベントタップが無効化されたため再有効化しました")
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
            // ダウンを消費していたらアップも対で消費する
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

/// C 関数ポインタなのでキャプチャできない。refcon 経由でインスタンスに戻す。
private let mediaKeyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}
