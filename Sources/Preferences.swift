import Cocoa
import ServiceManagement

/// アプリごとの可変設定。検出パターンは環境差が大きいのでユーザーが直せるようにする。
struct ProfileSettings: Codable, Equatable {
    var enabled: Bool
    var titlePatterns: [String]
    var shortcut: String
}

/// UserDefaults に載る設定一式。全体で 1 インスタンス。
final class Preferences {
    static let shared = Preferences()

    static let didChangeNotification = Notification.Name("MeetMutePreferencesDidChange")

    private let defaults = UserDefaults.standard

    private enum Key {
        static let profiles = "profiles"
        static let focusDelayMs = "focusDelayMs"
        static let priorityOrder = "priorityOrder"
        static let showToast = "showToast"
        static let requireMicActive = "requireMicActive"
        static let useWindowServerTitles = "useWindowServerTitles"
        static let switchBrowserTab = "switchBrowserTab"
        static let paused = "paused"
    }

    private init() {
        defaults.register(defaults: [
            Key.focusDelayMs: 120,
            Key.priorityOrder: ["zoom", "meet", "teams"],
            Key.showToast: true,
            Key.requireMicActive: false,
            Key.useWindowServerTitles: true,
            Key.switchBrowserTab: true,
            Key.paused: false,
        ])
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Preferences.didChangeNotification, object: nil)
    }

    // MARK: - アプリごとの設定

    private var storedProfiles: [String: ProfileSettings] {
        get {
            guard let data = defaults.data(forKey: Key.profiles),
                  let decoded = try? JSONDecoder().decode([String: ProfileSettings].self, from: data)
            else { return [:] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.profiles)
            notifyChange()
        }
    }

    func settings(for profile: MeetingProfile) -> ProfileSettings {
        storedProfiles[profile.id] ?? ProfileSettings(
            enabled: true,
            titlePatterns: profile.defaultTitlePatterns,
            shortcut: profile.defaultShortcut
        )
    }

    func update(_ settings: ProfileSettings, for profile: MeetingProfile) {
        var all = storedProfiles
        all[profile.id] = settings
        storedProfiles = all
    }

    func resetProfile(_ profile: MeetingProfile) {
        var all = storedProfiles
        all.removeValue(forKey: profile.id)
        storedProfiles = all
    }

    func shortcut(for profile: MeetingProfile) -> Shortcut {
        Shortcut(settings(for: profile).shortcut)
            ?? Shortcut(profile.defaultShortcut)!
    }

    /// priorityOrder の順に並べた、有効なプロファイル。
    var activeProfiles: [MeetingProfile] {
        let order = priorityOrder
        return MeetingProfile.all
            .filter { settings(for: $0).enabled }
            .sorted { lhs, rhs in
                let l = order.firstIndex(of: lhs.id) ?? order.count
                let r = order.firstIndex(of: rhs.id) ?? order.count
                return l < r
            }
    }

    // MARK: - 全体設定

    var priorityOrder: [String] {
        get { defaults.stringArray(forKey: Key.priorityOrder) ?? ["zoom", "meet", "teams"] }
        set { defaults.set(newValue, forKey: Key.priorityOrder); notifyChange() }
    }

    /// 前面化してからキーを送るまでの待ち時間。マシンの負荷で足りなくなるので可変。
    var focusDelayMs: Int {
        get { min(400, max(50, defaults.integer(forKey: Key.focusDelayMs))) }
        set { defaults.set(min(400, max(50, newValue)), forKey: Key.focusDelayMs); notifyChange() }
    }

    var focusDelay: TimeInterval { Double(focusDelayMs) / 1000.0 }

    var showToast: Bool {
        get { defaults.bool(forKey: Key.showToast) }
        set { defaults.set(newValue, forKey: Key.showToast); notifyChange() }
    }

    /// true にすると「マイクが使用中」のときだけ会議中と判定する。誤検出が多い環境向け。
    var requireMicActive: Bool {
        get { defaults.bool(forKey: Key.requireMicActive) }
        set { defaults.set(newValue, forKey: Key.requireMicActive); notifyChange() }
    }

    /// 別 Space / 最小化されたウィンドウを拾うため CGWindowList のタイトルも使う（画面収録権限が要る）。
    var useWindowServerTitles: Bool {
        get { defaults.bool(forKey: Key.useWindowServerTitles) }
        set { defaults.set(newValue, forKey: Key.useWindowServerTitles); notifyChange() }
    }

    /// ブラウザで Meet が非アクティブタブにいるとき、タブを切り替えてからキーを送る。
    var switchBrowserTab: Bool {
        get { defaults.bool(forKey: Key.switchBrowserTab) }
        set { defaults.set(newValue, forKey: Key.switchBrowserTab); notifyChange() }
    }

    var paused: Bool {
        get { defaults.bool(forKey: Key.paused) }
        set { defaults.set(newValue, forKey: Key.paused); notifyChange() }
    }

    // MARK: - ログイン時に起動

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("MeetMute: ログイン項目の更新に失敗: \(error)")
            }
            notifyChange()
        }
    }
}
