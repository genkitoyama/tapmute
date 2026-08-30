import Cocoa
import ApplicationServices

/// 「いまミュート操作を送るべき相手」。
struct MeetingTarget {
    let profile: MeetingProfile
    let app: NSRunningApplication
    /// 前面化に使うウィンドウ。WindowServer 経由でしか見つからなかった場合は nil。
    let window: AXUIElement?
    /// ブラウザで、対象が非アクティブタブだった場合に押すタブ要素。
    let tab: AXUIElement?
    let matchedTitle: String
    let source: WindowInfo.Source

    var displayName: String { profile.displayName }
}

/// 会議の検出。
///
/// 検出そのものは AX 走査を含んで数十 ms かかることがあるため、イベントタップの
/// コールバックからは絶対に同期実行しない。3 秒ごとのタイマーとワークスペース通知で
/// バックグラウンドに走らせ、タップ側は current を読むだけにする。
final class MeetingDetector {

    private(set) var current: MeetingTarget?
    private(set) var muteState: MuteState = .unknown
    private(set) var micActive = false
    private(set) var lastScanDate = Date.distantPast

    /// 検出結果またはミュート状態が変わったときに呼ばれる（メインスレッド）。
    var onChange: ((MeetingTarget?) -> Void)?

    private let queue = DispatchQueue(label: "com.meetmute.detector", qos: .userInitiated)
    private var timer: Timer?
    private var scanning = false
    private var windowServerTitlesAvailable = false

    // MARK: - ライフサイクル

    func start() {
        windowServerTitlesAvailable = AccessibilityHelper.canReadWindowServerTitles()

        let center = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            center.addObserver(self, selector: #selector(workspaceChanged), name: name, object: nil)
        }

        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func workspaceChanged() {
        refresh()
    }

    /// 画面収録権限は後から付与されうるので、権限確認のたびに取り直す。
    func refreshCapabilities() {
        windowServerTitlesAvailable = AccessibilityHelper.canReadWindowServerTitles()
    }

    var canReadWindowServerTitles: Bool { windowServerTitlesAvailable }

    // MARK: - 走査

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let useWindowServer = Preferences.shared.useWindowServerTitles && windowServerTitlesAvailable

        queue.async { [weak self] in
            guard let self else { return }
            let mic = MicMonitor.isInputActive()
            let target = Preferences.shared.paused ? nil : self.scan(useWindowServer: useWindowServer, micActive: mic)
            let state = target.map { MuteStateReader.read($0) } ?? .unknown

            DispatchQueue.main.async {
                self.scanning = false
                self.lastScanDate = Date()
                self.micActive = mic
                let changed = !MeetingDetector.isSame(self.current, target) || self.muteState != state
                self.current = target
                self.muteState = state
                if changed { self.onChange?(target) }
            }
        }
    }

    private func scan(useWindowServer: Bool, micActive: Bool) -> MeetingTarget? {
        if Preferences.shared.requireMicActive && !micActive { return nil }

        let running = NSWorkspace.shared.runningApplications
        for profile in Preferences.shared.activeProfiles {
            let patterns = Preferences.shared.settings(for: profile).titlePatterns
            guard !patterns.isEmpty else { continue }

            for app in running where matches(app: app, profile: profile) {
                let windows = AccessibilityHelper.windows(for: app, includeWindowServer: useWindowServer)

                // 1) ウィンドウタイトル（＝ブラウザならアクティブタブ）で一致するか
                if let hit = windows.first(where: { TitleMatcher.matches(title: $0.title, patterns: patterns) }) {
                    return MeetingTarget(profile: profile, app: app, window: hit.element,
                                         tab: nil, matchedTitle: hit.title, source: hit.source)
                }

                // 2) ブラウザなら、非アクティブタブも探す（AX が見えている Space に限る）
                if profile.isBrowser, Preferences.shared.switchBrowserTab {
                    for info in windows {
                        guard let element = info.element, info.source == .axWindowList else { continue }
                        if let tab = AccessibilityHelper.findPressableTab(in: element, matching: patterns) {
                            return MeetingTarget(profile: profile, app: app, window: element,
                                                 tab: tab, matchedTitle: AccessibilityHelper.title(tab),
                                                 source: info.source)
                        }
                    }
                }
            }
        }
        return nil
    }

    private func matches(app: NSRunningApplication, profile: MeetingProfile) -> Bool {
        guard let bundleID = app.bundleIdentifier, !app.isTerminated else { return false }
        if profile.bundleIDs.contains(bundleID) { return true }
        return profile.bundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    private static func isSame(_ lhs: MeetingTarget?, _ rhs: MeetingTarget?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?):
            return l.profile.id == r.profile.id
                && l.app.processIdentifier == r.app.processIdentifier
                && l.matchedTitle == r.matchedTitle
        default: return false
        }
    }

    // MARK: - デバッグ

    /// CLI プローブ用。ランループなしでその場で 1 回だけ走査する。
    @discardableResult
    func scanSynchronously() -> MeetingTarget? {
        refreshCapabilities()
        let useWindowServer = Preferences.shared.useWindowServerTitles && windowServerTitlesAvailable
        let target = scan(useWindowServer: useWindowServer, micActive: MicMonitor.isInputActive())
        current = target
        return target
    }

    /// 検出がうまくいかないときに、ユーザーが自分でタイトルを確認するための一覧。
    func debugReport() -> String {
        var lines: [String] = []
        lines.append("MeetMute ウィンドウ一覧  \(Date())")
        lines.append("画面収録によるタイトル取得: \(windowServerTitlesAvailable ? "利用可" : "利用不可")")
        lines.append("マイク使用中: \(MicMonitor.isInputActive())")
        lines.append("")

        let useWindowServer = windowServerTitlesAvailable
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, app.activationPolicy == .regular else { continue }
            let windows = AccessibilityHelper.windows(for: app, includeWindowServer: useWindowServer)
            guard !windows.isEmpty else { continue }

            let profile = MeetingProfile.all.first { matches(app: app, profile: $0) }
            let mark = profile.map { " [対象: \($0.displayName)]" } ?? ""
            lines.append("\(app.localizedName ?? "-")  \(bundleID)\(mark)")
            for window in windows {
                var flags = "(\(window.source.rawValue))"
                if let profile {
                    let patterns = Preferences.shared.settings(for: profile).titlePatterns
                    if TitleMatcher.matches(title: window.title, patterns: patterns) { flags += " ★一致" }
                }
                lines.append("    \(window.title)  \(flags)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
