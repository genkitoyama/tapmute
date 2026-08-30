import Cocoa
import SwiftUI

/// State of the settings window. Writing back to UserDefaults is concentrated in this class.
final class SettingsModel: ObservableObject {

    struct Row: Identifiable {
        let profile: MeetingProfile
        var enabled: Bool
        var shortcut: String
        var patternsText: String
        var id: String { profile.id }

        var shortcutIsValid: Bool { Shortcut(shortcut) != nil }
    }

    @Published var rows: [Row]
    @Published var focusDelayMs: Int { didSet { Preferences.shared.focusDelayMs = focusDelayMs } }
    @Published var showToast: Bool { didSet { Preferences.shared.showToast = showToast } }
    @Published var requireMicActive: Bool { didSet { Preferences.shared.requireMicActive = requireMicActive } }
    @Published var useWindowServerTitles: Bool { didSet { Preferences.shared.useWindowServerTitles = useWindowServerTitles } }
    @Published var switchBrowserTab: Bool { didSet { Preferences.shared.switchBrowserTab = switchBrowserTab } }
    @Published var launchAtLogin: Bool { didSet { Preferences.shared.launchAtLogin = launchAtLogin } }
    @Published var autoSwitchAudioDevice: Bool { didSet { Preferences.shared.autoSwitchAudioDevice = autoSwitchAudioDevice } }
    @Published var audioDevicePatternsText: String {
        didSet {
            Preferences.shared.audioDevicePatterns = audioDevicePatternsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    let screenRecordingGranted: Bool

    init() {
        let preferences = Preferences.shared
        rows = MeetingProfile.all.map { profile in
            let settings = preferences.settings(for: profile)
            return Row(profile: profile,
                       enabled: settings.enabled,
                       shortcut: settings.shortcut,
                       patternsText: settings.titlePatterns.joined(separator: "\n"))
        }
        focusDelayMs = preferences.focusDelayMs
        showToast = preferences.showToast
        requireMicActive = preferences.requireMicActive
        useWindowServerTitles = preferences.useWindowServerTitles
        switchBrowserTab = preferences.switchBrowserTab
        launchAtLogin = preferences.launchAtLogin
        autoSwitchAudioDevice = preferences.autoSwitchAudioDevice
        audioDevicePatternsText = preferences.audioDevicePatterns.joined(separator: ", ")
        screenRecordingGranted = PermissionManager.Permission.screenRecording.isGranted
    }

    func binding(for index: Int) -> Binding<Row> {
        Binding(
            get: { self.rows[index] },
            set: { newValue in
                self.rows[index] = newValue
                self.save(index)
            }
        )
    }

    private func save(_ index: Int) {
        let row = rows[index]
        let patterns = row.patternsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        Preferences.shared.update(
            ProfileSettings(enabled: row.enabled, titlePatterns: patterns, shortcut: row.shortcut),
            for: row.profile
        )
    }

    func reset(_ index: Int) {
        let profile = rows[index].profile
        Preferences.shared.resetProfile(profile)
        let settings = Preferences.shared.settings(for: profile)
        rows[index] = Row(profile: profile,
                          enabled: settings.enabled,
                          shortcut: settings.shortcut,
                          patternsText: settings.titlePatterns.joined(separator: "\n"))
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            general.tabItem { Text("全般") }
            apps.tabItem { Text("会議アプリ") }
        }
        .padding(12)
        .frame(width: 580, height: 480)
    }

    /// A macOS Form splits rows into a label column and a content column, pushing rows without a
    /// label to the right. Every row's look is decided here, so a VStack is used instead.
    private var general: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("ミュート時にトーストを表示", isOn: $model.showToast)
                Toggle("ログイン時に起動", isOn: $model.launchAtLogin)

                Divider()

                HStack(alignment: .firstTextBaseline) {
                    Text("前面化してからキーを送るまでの待ち時間")
                    Spacer(minLength: 12)
                    Text("\(model.focusDelayMs) ms")
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                    Stepper("", value: $model.focusDelayMs, in: 50...400, step: 10)
                        .labelsHidden()
                }
                caption("Meet / Teams の往復に使う。反応しないときは増やす。")

                Divider()

                Toggle("ブラウザのタブを切り替えて Meet を探す", isOn: $model.switchBrowserTab)
                caption("Meet が非アクティブタブにいても、タブを一瞬切り替えてミュートし、元のタブに戻す。")

                Toggle("別デスクトップの会議も検出する（画面収録を使用）", isOn: $model.useWindowServerTitles)
                caption(model.screenRecordingGranted
                        ? "有効。別 Space や最小化されたウィンドウの題名も読める。"
                        : "⚠️ 画面収録の権限がないため機能しない。会議を別デスクトップに置くと検出できない。",
                        color: model.screenRecordingGranted ? .secondary : .orange)

                Toggle("マイク使用中のときだけ会議とみなす", isOn: $model.requireMicActive)
                caption("誤検出（会議中でないのにボタンが効かない）が起きるときに有効化する。")

                Divider()

                Toggle("接続時にオーディオの入出力を自動で切り替える", isOn: $model.autoSwitchAudioDevice)
                HStack(alignment: .firstTextBaseline) {
                    Text("対象のデバイス名")
                    TextField("EarPods", text: $model.audioDevicePatternsText)
                        .disabled(!model.autoSwitchAudioDevice)
                    Spacer(minLength: 0)
                }
                caption("正規表現・カンマ区切り。挿した直後だけ切り替えるので、手で選び直した設定は上書きしない。"
                        + "macOS は出力だけ自動で切り替えて入力を内蔵マイクのまま残すことが多いので、そこを埋める。")

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var apps: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("有効", isOn: model.binding(for: index).enabled)

                            HStack(alignment: .firstTextBaseline) {
                                Text("ショートカット")
                                TextField("cmd+shift+a", text: model.binding(for: index).shortcut)
                                    .frame(width: 150)
                                if let shortcut = Shortcut(row.shortcut) {
                                    Text(shortcut.symbolic).foregroundColor(.secondary)
                                } else {
                                    Text("⚠️ 解釈できません").foregroundColor(.orange)
                                }
                                Spacer(minLength: 0)
                            }

                            caption("会議中と判定するタイトル（正規表現・1 行 1 パターン）")
                            TextEditor(text: model.binding(for: index).patternsText)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 54)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.3)))

                            HStack {
                                caption(row.profile.needsFocus
                                        ? "前面化 → キー送出 → 復帰"
                                        : "グローバルショートカットで送出（前面化しない）")
                                Spacer(minLength: 8)
                                Button("デフォルトに戻す") { model.reset(index) }
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text(row.profile.displayName).font(.headline)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func caption(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Owns exactly one settings window.
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(model: SettingsModel()))
        let window = NSWindow(contentViewController: hosting)
        window.title = "MeetMute 設定"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
