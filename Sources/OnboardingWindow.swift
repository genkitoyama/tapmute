import Cocoa
import SwiftUI

/// 権限の状態を出して、System Settings への導線を置くだけの画面。
/// 権限は付与後にプロセス再起動が要ることがあるので、再起動ボタンも用意する。
final class OnboardingModel: ObservableObject {
    @Published var states: [PermissionManager.Permission: Bool] = [:]
    private var timer: Timer?

    init() {
        reload()
        // 設定アプリ側で切り替えた結果をそのまま反映したいのでポーリングする
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    deinit { timer?.invalidate() }

    func reload() {
        var next: [PermissionManager.Permission: Bool] = [:]
        for permission in PermissionManager.Permission.allCases {
            next[permission] = permission.isGranted
        }
        if next != states { states = next }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MeetMute のセットアップ").font(.title2).bold()
            Text("EarPods の中央ボタンで Zoom / Google Meet / Teams のミュートを切り替えます。")
                .foregroundColor(.secondary)

            ForEach(PermissionManager.Permission.allCases, id: \.self) { permission in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: (model.states[permission] ?? false)
                          ? "checkmark.circle.fill"
                          : (permission.isRequired ? "exclamationmark.circle.fill" : "circle"))
                        .foregroundColor((model.states[permission] ?? false)
                                         ? .green
                                         : (permission.isRequired ? .orange : .secondary))
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.title + (permission.isRequired ? "（必須）" : "（推奨）")).bold()
                        Text(permission.reason).font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("設定を開く") { PermissionManager.request(permission) }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Zoom 側の設定").bold()
                Text("設定 → キーボードショートカット →「ミュート/ミュート解除」の"
                     + "「グローバルショートカットを有効にする」を ON にしてください。"
                     + "これが OFF だと Zoom が最前面のときしか反応しません。")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("MeetMute を再起動") { PermissionManager.relaunch() }
                Spacer()
                Text("権限を付けた直後は再起動が要ることがあります")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

final class OnboardingWindowController {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: OnboardingView(model: OnboardingModel()))
        let window = NSWindow(contentViewController: hosting)
        window.title = "MeetMute"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
