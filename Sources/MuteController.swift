import Cocoa
import ApplicationServices

/// 検出した相手にミュートのショートカットを届ける。
///
/// Zoom はグローバルショートカットが効くのでキーを送るだけ。
/// Meet / Teams は前面化 → キー送出 → 復帰の往復が要る。往復の途中で 2 回目の
/// キーが来ると状態が壊れるので、処理中フラグで弾く。
final class MuteController {

    enum Result {
        case sent(MeetingTarget)
        case busy
    }

    private(set) var isBusy = false

    func toggle(_ target: MeetingTarget, completion: @escaping (Result) -> Void) {
        guard !isBusy else {
            completion(.busy)
            return
        }
        let shortcut = Preferences.shared.shortcut(for: target.profile)

        guard target.profile.needsFocus else {
            shortcut.post()
            completion(.sent(target))
            return
        }
        focusAndSend(target, shortcut: shortcut, completion: completion)
    }

    /// 前面化してキーを送り、元のアプリ（とタブ）に戻す。
    private func focusAndSend(_ target: MeetingTarget, shortcut: Shortcut, completion: @escaping (Result) -> Void) {
        isBusy = true

        let previousApp = NSWorkspace.shared.frontmostApplication
        let delay = Preferences.shared.focusDelay

        // タブを切り替えるなら、戻すために「いま表示しているタブ」の題名を控える
        var previousTabTitle: String?
        if let tab = target.tab, let window = target.window {
            let currentTitle = AccessibilityHelper.title(window)
            if !currentTitle.isEmpty && currentTitle != AccessibilityHelper.title(tab) {
                previousTabTitle = currentTitle
            }
            AccessibilityHelper.press(tab)
        }

        if let window = target.window {
            AccessibilityHelper.raise(window)
        }
        AccessibilityHelper.activate(target.app)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            shortcut.post()

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.restore(target: target, previousTabTitle: previousTabTitle, previousApp: previousApp)
                self.isBusy = false
                completion(.sent(target))
            }
        }
    }

    private func restore(target: MeetingTarget, previousTabTitle: String?, previousApp: NSRunningApplication?) {
        if let title = previousTabTitle, let window = target.window {
            let pattern = "^" + NSRegularExpression.escapedPattern(for: title) + "$"
            if let tab = AccessibilityHelper.findPressableTab(in: window, matching: [pattern]) {
                AccessibilityHelper.press(tab)
            }
        }

        guard let previousApp,
              !previousApp.isTerminated,
              previousApp.processIdentifier != target.app.processIdentifier
        else { return }
        AccessibilityHelper.activate(previousApp)
    }
}
