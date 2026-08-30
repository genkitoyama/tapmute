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
/// 判定の軸は 2 つあり、優先順位が違う。
///
/// 1. 操作ボタン（AXButton）。ボタンは常に「次にする操作」を述べるので、
///    「ミュートを解除」を提案していれば、いまはミュート中と確実に分かる。
///    実機の文言:
///      Zoom  ミュート中「自分のオーディオをミュート解除する」/ 解除中「…をミュートする」
///      Teams ミュート中「マイクのミュートを解除」        / 解除中「マイクのミュート」
///      Meet  ミュート中「Turn on microphone」            / 解除中「Turn off microphone」
///    Zoom は「ミュート解除する」と繋がるが Teams は「ミュートを解除」と助詞が入る。
///    部分一致で拾うため、助詞入りの形も別の語として持つ必要がある。
///
/// 2. 状態を述べている文言（ボタン以外も含む）。ボタンが見つからないときの保険。
///    Zoom のツールバーが隠れている場合などに効く。
///    「ミュート解除された」のように状態を述べる語は、操作を述べる語と語幹を共有するので、
///    操作側の判定に混ぜてはいけない。だから別のリストに分けている。
///
/// どちらでも読めなければ .unknown を返し、UI 側は状態表示をやめる。
enum MuteStateReader {

    /// ページ内容の AX を有効化済みのプロセス。1 度立てれば足りるので覚えておく。
    private static var webAccessibilityEnabled = Set<pid_t>()

    private static let controlRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton"]

    static func read(_ target: MeetingTarget) -> MuteState {
        let hints = target.profile.muteHints
        if hints.searchWebArea {
            enableWebAccessibility(for: target.app)
        }
        guard let root = rootElement(for: target) else { return .unknown }

        // ページ内のボタンは深い（Meet の実測で depth 15、Teams で depth 20）。
        // 専用アプリはもっと浅いので、無駄に潜らないよう上限を分ける。
        var context = SearchContext(
            hints: hints,
            maxDepth: hints.searchWebArea ? 30 : 16,
            budget: hints.searchWebArea ? 4000 : 1500
        )
        if let state = search(root, depth: 0, context: &context) { return state }
        return context.stateFallback ?? .unknown
    }

    private struct SearchContext {
        let hints: MuteHints
        let maxDepth: Int
        let budget: Int
        var visited = 0
        /// ボタンが見つからなかったときに使う、状態文言からの読み
        var stateFallback: MuteState?
    }

    /// 戻り値が非 nil なら「ボタンから確定できた」。nil なら走査を続ける。
    private static func search(_ element: AXUIElement, depth: Int, context: inout SearchContext) -> MuteState? {
        guard depth < context.maxDepth, context.visited < context.budget else { return nil }
        context.visited += 1

        let role = AccessibilityHelper.string(element, kAXRoleAttribute as String) ?? ""
        if role == "AXWebArea" && !context.hints.searchWebArea { return nil }

        let title = AccessibilityHelper.string(element, kAXTitleAttribute as String) ?? ""
        let description = AccessibilityHelper.string(element, kAXDescriptionAttribute as String) ?? ""
        let text = title + " " + description

        if controlRoles.contains(role) {
            if let state = classify(text: text, isControl: true, hints: context.hints) { return state }
        } else if context.stateFallback == nil {
            context.stateFallback = classify(text: text, isControl: false, hints: context.hints)
        }

        for child in AccessibilityHelper.children(element) {
            if let state = search(child, depth: depth + 1, context: &context) { return state }
        }
        return nil
    }

    /// 文言 1 つぶんの判定。副作用がないので、実機で採取した文言に対して単体で検証できる
    /// （`MeetMute --probe-mute-markers`）。
    static func classify(text: String, isControl: Bool, hints: MuteHints) -> MuteState? {
        let markers = isControl ? hints.actionMarkers : hints.stateMarkers
        for marker in markers where text.localizedCaseInsensitiveContains(marker.text) {
            return marker.state
        }
        return nil
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

    /// Chromium 系はページ内容の AX ツリーを既定では作らない。
    /// この属性を立てると作るようになる（スクリーンリーダーが使うのと同じ仕組み）。
    /// 会議を検出しているときだけ立てるので、常時のコストにはしない。
    private static func enableWebAccessibility(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !webAccessibilityEnabled.contains(pid) else { return }
        let axApp = AXUIElementCreateApplication(pid)
        for key in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            AXUIElementSetAttributeValue(axApp, key as CFString, kCFBooleanTrue)
        }
        webAccessibilityEnabled.insert(pid)
    }
}

/// ミュート状態を読むための手がかり。アプリと言語で文言が違うので値として持つ。
/// 部分一致で照合するため、限定的な語を先に置く順序が意味を持つ。
struct MuteHints {
    /// 操作ボタンの文言 → その操作を提案しているときの現在状態
    let actionMarkers: [(text: String, state: MuteState)]
    /// 状態を述べている文言 → 現在状態
    let stateMarkers: [(text: String, state: MuteState)]
    /// ページ本体（AXWebArea）まで降りるか。true のときは Chromium 側の AX 生成も有効化する
    let searchWebArea: Bool

    /// 「解除」を提案している＝いまミュート中。「ミュート」を提案している＝いま解除中。
    static let standardActions: [(text: String, state: MuteState)] = [
        ("ミュートを解除", .muted),
        ("ミュート解除", .muted),
        ("unmute", .muted),
        ("マイクをオンにする", .muted),
        ("turn on microphone", .muted),
        ("マイクをオフにする", .unmuted),
        ("turn off microphone", .unmuted),
        ("ミュート", .unmuted),
        ("mute", .unmuted),
    ]

    /// 状態そのものを述べている言い回しだけを入れる。
    /// 「ミュート解除」（操作）のような両義的な語はここに入れてはいけない。
    static let standardStates: [(text: String, state: MuteState)] = [
        ("ミュート解除された", .unmuted),
        ("ミュート解除中", .unmuted),
        ("unmuted", .unmuted),
        ("ミュートされた", .muted),
        ("ミュート中", .muted),
        ("muted", .muted),
    ]

    static func standard(searchWebArea: Bool) -> MuteHints {
        MuteHints(actionMarkers: standardActions,
                  stateMarkers: standardStates,
                  searchWebArea: searchWebArea)
    }
}
