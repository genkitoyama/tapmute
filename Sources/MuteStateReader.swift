import Cocoa
import ApplicationServices

enum MuteState {
    case muted
    case unmuted
    /// 読めなかった。嘘を表示しないための第三の状態。
    case unknown
}

/// 会議アプリの「いまミュートされているか」を AX から読む。
///
/// 読み方は、ミュート操作のコントロールが何を提案しているかを見る方式。
/// Zoom なら会議中のツールバーに
///   ミュート中   → desc="自分のオーディオをミュート解除する"
///   ミュート解除中 → desc="自分のオーディオをミュートする"
/// が出る。「解除」を提案している＝いまミュート中、と読む。
///
/// 読めなければ .unknown を返し、UI 側は状態表示をやめる。
/// 確実に読めないものを表示すると必ず嘘をつく瞬間ができるため。
enum MuteStateReader {

    static func read(_ target: MeetingTarget) -> MuteState {
        guard let root = rootElement(for: target) else { return .unknown }
        let hints = target.profile.muteHints
        let budget = target.profile.isBrowser ? 3500 : 1200
        var visited = 0
        return search(root, hints: hints, depth: 0, visited: &visited, budget: budget)
    }

    private static func rootElement(for target: MeetingTarget) -> AXUIElement? {
        if let window = target.window { return window }
        // WindowServer 経由でしか見つからなかった場合は、アプリのメインウィンドウで代用する
        let axApp = AXUIElementCreateApplication(target.app.processIdentifier)
        for key in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let value = AccessibilityHelper.attribute(axApp, key as String) {
                return (value as! AXUIElement)
            }
        }
        return nil
    }

    private static func search(_ element: AXUIElement,
                               hints: MuteHints,
                               depth: Int,
                               visited: inout Int,
                               budget: Int) -> MuteState {
        guard depth < 14, visited < budget else { return .unknown }
        visited += 1

        let role = AccessibilityHelper.string(element, kAXRoleAttribute as String) ?? ""
        // ブラウザはページ本体まで降りないとミュートボタンに届かないが、
        // 専用アプリでページ相当の階層に降りる必要はない
        if role == "AXWebArea" && !hints.searchWebArea { return .unknown }

        let title = AccessibilityHelper.string(element, kAXTitleAttribute as String) ?? ""
        let description = AccessibilityHelper.string(element, kAXDescriptionAttribute as String) ?? ""
        let text = title + " " + description

        // 順序付きで照合する。先に当たったものを採用するので、より限定的な語を先に置く
        // （"ミュート解除された"＝解除済み を "ミュート解除"＝解除を提案 より先に見る）。
        for marker in hints.markers where text.localizedCaseInsensitiveContains(marker.text) {
            return marker.state
        }

        for child in AccessibilityHelper.children(element) {
            let state = search(child, hints: hints, depth: depth + 1, visited: &visited, budget: budget)
            if state != .unknown { return state }
        }
        return .unknown
    }
}

/// ミュート状態を読むための手がかり。アプリと言語で文言が違うので値として持つ。
///
/// 判定は「状態を述べている語」と「操作を提案している語」の区別が肝。
///   "ミュート解除された" → いま解除中（状態）
///   "ミュート解除する"   → 解除を提案 ＝ いまミュート中（操作）
/// 部分一致で照合するため、限定的な語を先に置く順序が意味を持つ。
struct MuteHints {
    let markers: [(text: String, state: MuteState)]
    /// ページ本体（AXWebArea）まで降りるか
    let searchWebArea: Bool

    /// 日本語 / 英語で共通に効く既定の並び。
    static let standard: [(text: String, state: MuteState)] = [
        ("ミュート解除された", .unmuted),
        ("ミュート解除中", .unmuted),
        ("unmuted", .unmuted),
        ("ミュート解除", .muted),
        ("unmute", .muted),
        ("ミュートされた", .muted),
        ("ミュート中", .muted),
        ("muted", .muted),
        ("ミュート", .unmuted),
        ("mute", .unmuted),
    ]
}
