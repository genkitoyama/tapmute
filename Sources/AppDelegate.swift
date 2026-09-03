import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let detector = MeetingDetector()
    private let muteController = MuteController()
    private let mediaKeyTap = MediaKeyTap()
    private let nowPlayingShield = NowPlayingShield()
    private let audioSwitcher = AudioDeviceSwitcher()
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

        audioSwitcher.onSwitched = { [weak self] name in
            self?.statusBar.showToast("\(name) に切り替えました")
        }
        audioSwitcher.start()

        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: Preferences.didChangeNotification, object: nil)

        // The tap can die across sleep, so wake it back up
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
        audioSwitcher.stop()
        detector.stop()
    }

    /// Hold the Now Playing role only while a meeting is detected, so the media key is delivered
    /// here instead of to Music. This is what stops "it muted, but the music started too".
    private func updateShield(for target: MeetingTarget?) {
        if target != nil && !Preferences.shared.paused {
            nowPlayingShield.activate()
        } else {
            nowPlayingShield.deactivate()
        }
    }

    // MARK: - Media key

    /// Return true to consume the event. Called synchronously from the event tap callback, so it
    /// must stay cheap: detection only reads the cache that the timer keeps up to date.
    private func handlePlayPause() -> Bool {
        guard !Preferences.shared.paused else { return false }

        guard detector.current != nil else {
            detector.refresh()  // 会議が始まった直後の取りこぼしを次回で拾う
            return false
        }
        performMute()
        return true
    }

    /// Send the mute to the detected target. Shared by the key path (tap) and the Now Playing path.
    private func performMute() {
        guard let target = detector.current, !muteController.isBusy else { return }
        statusBar.showToast("\(target.displayName)  ミュート切替")
        muteController.toggle(target) { [weak self] _ in
            // Reflect the change in the icon without waiting for the periodic scan
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
            NSLog("TapMute: \(error.localizedDescription)")
            scheduleTapRetry()
        }
        updateStatus()
    }

    /// Lets the app come up on its own when Input Monitoring is granted later.
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

    // MARK: - Menu actions

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

    /// For investigating detection failures. Knowing the real window titles lets the user
    /// fix the patterns in Settings themselves.
    private func dumpWindows() {
        let report = detector.debugReport()
        NSLog("%@", report)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapmute-windows-\(Int(Date().timeIntervalSince1970)).txt")
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
        alert.messageText = "TapMute"
        alert.informativeText = """
            EarPods の中央ボタンで Zoom / Google Meet / Microsoft Teams / Slack ハドルの
            ミュートを切り替えます。
            会議が検出されていないときは、ボタンは通常どおり音楽の再生/停止として働きます。
            """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
