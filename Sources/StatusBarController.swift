import Cocoa

/// A panel that never becomes the key window.
/// Becoming key would break the Meet / Teams focus round trip, so this is non-negotiable.
private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The menu bar UI.
///
/// The icon shows the current mute state, read through accessibility. When it cannot be read,
/// the plain shape is shown and the menu says the state is unknown, because displaying a
/// state that cannot be verified would be a lie.
final class StatusBarController: NSObject {

    /// Hook to rebuild what is shown right before the menu opens.
    /// Shows the state at that moment instead of waiting for the 3 second timer.
    var onMenuWillOpen: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onDumpWindows: (() -> Void)?
    var onOpenPermissions: (() -> Void)?
    var onAbout: (() -> Void)?

    /// Symbols used in the menu bar. The earbud shape is the app's identity; a slash means muted
    /// and a dimmed version means no meeting is detected.
    private enum Symbol {
        /// A single earbud. Its outline is simpler than the pair, so the slash stays legible at menu bar size.
        /// Falls back to the pair when the symbol is unavailable.
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

    // MARK: - Updating what is shown

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
            // Do not show a state that could not be read. Showing it anyway would be a lie.
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

    /// SF Symbols has no slashed variant of the earbud, so it is composed here.
    /// Like the slash in SF Symbols itself, a gap is punched around the line before the line is
    /// drawn, so the slash stays readable on top of the shape.
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
        // Dim while idle. The same shape carries the state through contrast alone.
        button.appearsDisabled = dimmed
    }

    // MARK: - Toast

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
