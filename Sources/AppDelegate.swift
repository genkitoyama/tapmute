import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let detector = MeetingDetector()
    private let muteController = MuteController()
    private let mediaKeyTap = MediaKeyTap()
    private let nowPlayingShield = NowPlayingShield()
    private var statusBar: StatusBarController!
    private let settingsWindow = SettingsWindowController()
    private let onboardingWindow = OnboardingWindowController()

    private var tapRetryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusBar = StatusBarController()
        statusBar.onMenuWillOpen = { [weak self] in self?.updateStatus() }
        statusBar.onTogglePause = { [weak self] in self?.togglePause() }
        statusBar.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        statusBar.onDumpWindows = { [weak self] in self?.dumpWindows() }
        statusBar.onOpenPermissions = { [weak self] in self?.onboardingWindow.show() }
        statusBar.onAbout = { [weak self] in self?.showAbout() }

        nowPlayingShield.isTapHandlingKeys = { [weak self] in self?.mediaKeyTap.isRunning ?? false }
        nowPlayingShield.onCommandFallback = { [weak self] in self?.performMute() }

        detector.onChange = { [weak self] target in
            self?.updateShield(for: target)
            self?.updateStatus()
        }
        detector.start()

        mediaKeyTap.onPlayPause = { [weak self] in self?.handlePlayPause() ?? false }
        startTap()

        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: Preferences.didChangeNotification, object: nil)

        // スリープ復帰でタップが死ぬことがあるので、起こし直す
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        updateStatus()

        if !PermissionManager.isReady {
            onboardingWindow.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mediaKeyTap.stop()
        nowPlayingShield.deactivate()
        detector.stop()
    }

    /// 会議中だけ Now Playing の座を奪う。メディアキーが Music ではなくこちらに配送され、
    /// 「ミュートしたのに音楽が再生される」が起きなくなる。
    private func updateShield(for target: MeetingTarget?) {
        if target != nil && !Preferences.shared.paused {
            nowPlayingShield.activate()
        } else {
            nowPlayingShield.deactivate()
        }
    }

    // MARK: - メディアキー

    /// true を返すとイベントを消費する。イベントタップのコールバックから同期で呼ばれるため、
    /// ここでは重い処理をしない。検出はタイマーで更新済みのキャッシュを読むだけ。
    private func handlePlayPause() -> Bool {
        guard !Preferences.shared.paused else { return false }

        guard detector.current != nil else {
            detector.refresh()  // 会議が始まった直後の取りこぼしを次回で拾う
            return false
        }
        performMute()
        return true
    }

    /// 検出済みの相手にミュートを送る。キー経路（タップ）と Now Playing 経路の共通処理。
    private func performMute() {
        guard let target = detector.current, !muteController.isBusy else { return }
        statusBar.showToast("\(target.displayName)  ミュート切替")
        muteController.toggle(target) { [weak self] _ in
            // 切り替え直後にアイコンへ反映したいので、定期スキャンを待たずに読み直す
            for delay in [0.35, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.detector.refresh() }
            }
        }
    }

    private func startTap() {
        do {
            try mediaKeyTap.start()
            tapRetryTimer?.invalidate()
            tapRetryTimer = nil
        } catch {
            NSLog("MeetMute: \(error.localizedDescription)")
            scheduleTapRetry()
        }
        updateStatus()
    }

    /// 入力監視を後から許可された場合に自力で立ち上がれるようにする。
    private func scheduleTapRetry() {
        guard tapRetryTimer == nil else { return }
        tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, !self.mediaKeyTap.isRunning else { return }
            self.startTap()
        }
    }

    @objc private func systemDidWake() {
        if !mediaKeyTap.isRunning {
            mediaKeyTap.stop()
            startTap()
        }
        detector.refreshCapabilities()
        detector.refresh()
    }

    // MARK: - メニュー操作

    private func togglePause() {
        Preferences.shared.paused.toggle()
        if Preferences.shared.paused { nowPlayingShield.deactivate() }
        detector.refresh()
        updateStatus()
    }

    @objc private func preferencesChanged() {
        detector.refreshCapabilities()
        detector.refresh()
        updateStatus()
    }

    private func updateStatus() {
        let permissionsOK = PermissionManager.isReady && mediaKeyTap.isRunning
        statusBar.update(target: detector.current,
                         muteState: detector.muteState,
                         micActive: detector.micActive,
                         paused: Preferences.shared.paused,
                         permissionsOK: permissionsOK)
    }

    /// 検出がうまくいかないときの調査用。実際のウィンドウ題名が分かれば、
    /// ユーザーが設定のパターンを自分で直せる。
    private func dumpWindows() {
        let report = detector.debugReport()
        NSLog("%@", report)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetmute-windows-\(Int(Date().timeIntervalSince1970)).txt")
        try? report.write(to: url, atomically: true, encoding: .utf8)

        let alert = NSAlert()
        alert.messageText = "ウィンドウ一覧をクリップボードにコピーしました"
        alert.informativeText = "会議中に実行して、実際の題名を確認してください。\n\(url.path)"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "ファイルを開く")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "MeetMute"
        alert.informativeText = """
            EarPods の中央ボタンで Zoom / Google Meet / Microsoft Teams のミュートを切り替えます。
            会議が検出されていないときは、ボタンは通常どおり音楽の再生/停止として働きます。
            """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
