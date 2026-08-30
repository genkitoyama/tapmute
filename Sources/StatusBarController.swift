import Cocoa

/// キーウィンドウにならないパネル。
/// キーウィンドウになると Meet / Teams のフォーカス往復を壊すので、ここは譲れない。
private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// メニューバーの常駐 UI。
///
/// アイコンは「ミュート状態」ではなく「いま検出できている相手」を表す。
/// Zoom / Meet の実際のミュート状態を確実に読む手段を持たない以上、
/// 状態を表示すると必ず嘘をつく瞬間ができるため。
final class StatusBarController: NSObject {

    /// メニューを開く直前に表示内容を作り直すためのフック。
    /// 3 秒タイマーの更新を待たずに、開いた瞬間の状態を出す。
    var onMenuWillOpen: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onDumpWindows: (() -> Void)?
    var onOpenPermissions: (() -> Void)?
    var onAbout: (() -> Void)?

    /// アイコンは「いまボタンを押すと何が起きるか」を表す。
    /// ミュート状態そのものは外部から確実に読めないので表示しない。
    private enum Symbol {
        /// 片耳のイヤホン。両耳版より輪郭が単純で、メニューバーの小ささでも斜線が潰れない。
        /// 環境に無ければ両耳版へ落とす。
        static let earbudCandidates = ["airpod.right", "earbuds", "headphones"]
        static let paused = "pause.circle"
        static let needsPermission = "exclamationmark.triangle.fill"
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusMenuItem = NSMenuItem(title: "検出中…", action: nil, keyEquivalent: "")
    private let micMenuItem = NSMenuItem(title: "マイク: -", action: nil, keyEquivalent: "")
    private let pauseMenuItem = NSMenuItem(title: "一時停止", action: nil, keyEquivalent: "")
    private var toastPanel: ToastPanel?
    private var toastWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        buildMenu()
        applyEarbuds(slashed: false, dimmed: true, tooltip: "会議は検出されていません")
    }

    private func buildMenu() {
        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        micMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(micMenuItem)
        menu.addItem(.separator())

        pauseMenuItem.target = self
        pauseMenuItem.action = #selector(togglePause)
        menu.addItem(pauseMenuItem)

        menu.addItem(item("設定…", #selector(openSettings), key: ","))
        menu.addItem(item("ウィンドウ一覧をログ出力", #selector(dumpWindows)))
        menu.addItem(item("権限を確認…", #selector(openPermissions)))
        menu.addItem(.separator())
        menu.addItem(item("MeetMute について", #selector(about)))
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.delegate = self
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    @objc private func togglePause() { onTogglePause?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func dumpWindows() { onDumpWindows?() }
    @objc private func openPermissions() { onOpenPermissions?() }
    @objc private func about() { onAbout?() }

    // MARK: - 表示の更新

    func update(target: MeetingTarget?, muteState: MuteState, micActive: Bool, paused: Bool, permissionsOK: Bool) {
        pauseMenuItem.title = paused ? "再開" : "一時停止"
        micMenuItem.title = "マイク: \(micActive ? "使用中" : "停止中")"

        if !permissionsOK {
            statusMenuItem.title = "権限が不足しています"
            apply(symbol: Symbol.needsPermission, tooltip: "MeetMute: 権限が不足しています")
            return
        }
        if paused {
            statusMenuItem.title = "一時停止中"
            apply(symbol: Symbol.paused, tooltip: "MeetMute: 一時停止中")
            return
        }
        guard let target else {
            statusMenuItem.title = "会議は検出されていません"
            applyEarbuds(slashed: false, dimmed: true,
                         tooltip: "MeetMute: 会議なし（押すと音楽の再生/停止）")
            return
        }

        switch muteState {
        case .muted:
            statusMenuItem.title = "\(target.displayName): ミュート中 — \(target.matchedTitle)"
            applyEarbuds(slashed: true, dimmed: false,
                         tooltip: "MeetMute: \(target.displayName) ミュート中（押すと解除）")
        case .unmuted:
            statusMenuItem.title = "\(target.displayName): ミュート解除中 — \(target.matchedTitle)"
            applyEarbuds(slashed: false, dimmed: false,
                         tooltip: "MeetMute: \(target.displayName) ミュート解除中（押すとミュート）")
        case .unknown:
            // 状態が読めないときは状態を表示しない。読めないものを表示すると嘘になる。
            statusMenuItem.title = "\(target.displayName): 検出中（状態不明） — \(target.matchedTitle)"
            applyEarbuds(slashed: false, dimmed: false,
                         tooltip: "MeetMute: \(target.displayName) を検出中（ミュート状態は読めていません）")
        }
    }

    private func applyEarbuds(slashed: Bool, dimmed: Bool, tooltip: String) {
        guard let button = statusItem.button else { return }
        button.image = StatusBarController.earbudsImage(slashed: slashed)
        button.toolTip = tooltip
        button.appearsDisabled = dimmed
    }

    /// SF Symbols に earbuds の斜線版がないので合成する。
    /// SF Symbols 自身の slash と同じく、線の周囲を一度くり抜いてから線を引くことで、
    /// 元の形に重なっても斜線が読み取れるようにする。
    private static var iconCache: [Bool: NSImage] = [:]

    private static func earbudsImage(slashed: Bool) -> NSImage? {
        if let cached = iconCache[slashed] { return cached }

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        guard let base = Symbol.earbudCandidates
                .lazy
                .compactMap({ NSImage(systemSymbolName: $0, accessibilityDescription: nil) })
                .first?
                .withSymbolConfiguration(config) else { return nil }
        guard slashed else {
            base.isTemplate = true
            iconCache[false] = base
            return base
        }

        let size = base.size
        let image = NSImage(size: size)
        image.lockFocus()
        base.draw(in: CGRect(origin: .zero, size: size))

        let inset: CGFloat = 1.0
        let line = NSBezierPath()
        line.move(to: CGPoint(x: inset, y: inset))
        line.line(to: CGPoint(x: size.width - inset, y: size.height - inset))
        line.lineCapStyle = .round
        NSColor.black.setStroke()

        NSGraphicsContext.current?.compositingOperation = .destinationOut
        line.lineWidth = 3.4
        line.stroke()

        NSGraphicsContext.current?.compositingOperation = .sourceOver
        line.lineWidth = 1.6
        line.stroke()

        image.unlockFocus()
        image.isTemplate = true
        iconCache[true] = image
        return image
    }

    private func apply(symbol: String, tooltip: String, dimmed: Bool = false) {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        image?.isTemplate = true
        button.image = image
        button.toolTip = tooltip
        // 待機中は薄く。同じ形のまま濃淡だけで状態が分かる。
        button.appearsDisabled = dimmed
    }

    // MARK: - トースト

    func showToast(_ text: String) {
        guard Preferences.shared.showToast else { return }
        toastWorkItem?.cancel()

        let panel = toastPanel ?? makeToastPanel()
        toastPanel = panel

        guard let label = panel.contentView?.subviews.compactMap({ $0 as? NSTextField }).first else { return }
        label.stringValue = text
        label.sizeToFit()

        let width = max(140, label.frame.width + 40)
        let height: CGFloat = 44
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrame(NSRect(x: frame.midX - width / 2,
                                  y: frame.minY + 120,
                                  width: width,
                                  height: height), display: false)
        }
        label.frame = NSRect(x: 0, y: (height - label.frame.height) / 2, width: width, height: label.frame.height)

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let dismiss = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel?.animator().alphaValue = 0
            } completionHandler: {
                panel?.orderOut(nil)
            }
        }
        toastWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: dismiss)
    }

    private func makeToastPanel() -> ToastPanel {
        let panel = ToastPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 44),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered,
                               defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(effect)

        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        panel.contentView?.addSubview(label)

        return panel
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        onMenuWillOpen?()
    }
}
