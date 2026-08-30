import Cocoa
import ApplicationServices

enum MuteState {
    case muted
    case unmuted
    /// Could not be read. A third state exists so the UI never has to lie.
    case unknown
}

/// Reads whether a conferencing app is currently muted, through accessibility.
///
/// There are two axes, with different priority.
///
/// 1. The control itself (AXButton). A button always describes the action it will perform,
///    so a button offering "unmute" means you are muted right now.
///    Labels measured on real hardware:
///      Zoom  muted "自分のオーディオをミュート解除する" / unmuted "…をミュートする"
///      Teams muted "マイクのミュートを解除"             / unmuted "マイクのミュート"
///      Meet  muted "Turn on microphone"                 / unmuted "Turn off microphone"
///    Zoom joins the words as "ミュート解除する" while Teams inserts a particle: "ミュートを解除".
///    Substring matching therefore needs the particle form as a separate marker.
///
/// 2. Wording that describes the state (any role). A fallback for when no button is found,
///    such as when the Zoom toolbar is hidden.
///    State words like "ミュート解除された" share a stem with action words, so they must not
///    be mixed into the action list. That is why the two lists are kept separate.
///
/// When neither can be read, .unknown is returned and the UI stops showing a state.
enum MuteStateReader {

    /// Processes whose page accessibility has been enabled. Setting it once is enough.
    private static var webAccessibilityEnabled = Set<pid_t>()

    private static let controlRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton"]

    static func read(_ target: MeetingTarget) -> MuteState {
        let hints = target.profile.muteHints
        if hints.searchWebArea {
            enableWebAccessibility(for: target.app)
        }
        guard let root = rootElement(for: target) else { return .unknown }

        // Controls inside a page are deep (measured: depth 15 for Meet, depth 20 for Teams).
        // Dedicated apps are much shallower, so the limits differ to avoid pointless descent.
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
        /// The reading from state wording, used when no button was found
        var stateFallback: MuteState?
    }

    /// A non-nil return means a button settled it. nil means keep walking.
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

    /// Classifies one piece of wording. It has no side effects, so it can be verified on its own
    /// against wording captured from the real apps (`TapMute --probe-mute-markers`).
    static func classify(text: String, isControl: Bool, hints: MuteHints) -> MuteState? {
        let markers = isControl ? hints.actionMarkers : hints.stateMarkers
        for marker in markers where text.localizedCaseInsensitiveContains(marker.text) {
            return marker.state
        }
        return nil
    }

    private static func rootElement(for target: MeetingTarget) -> AXUIElement? {
        if let window = target.window { return window }
        // When the target was only found through the WindowServer, fall back to the app's main window
        let axApp = AXUIElementCreateApplication(target.app.processIdentifier)
        for key in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let value = AccessibilityHelper.attribute(axApp, key as String) {
                return (value as! AXUIElement)
            }
        }
        return nil
    }

    /// Chromium-based browsers do not build an accessibility tree for page content by default.
    /// Setting this attribute makes them build it (the mechanism screen readers rely on).
    /// It is set only while a meeting is detected, so it is not a permanent cost.
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

/// Hints for reading mute state. Wording differs per app and language, so it is held as data.
/// Matching is by substring, so ordering matters: more specific words come first.
struct MuteHints {
    /// Control wording -> the current state implied by offering that action
    let actionMarkers: [(text: String, state: MuteState)]
    /// Wording that describes the state -> the current state
    let stateMarkers: [(text: String, state: MuteState)]
    /// Whether to descend into page content (AXWebArea). When true, Chromium's AX generation is enabled too
    let searchWebArea: Bool

    /// Offering to unmute means muted right now. Offering to mute means unmuted right now.
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

    /// Only phrases that describe the state itself belong here.
    /// Ambiguous wording such as "ミュート解除" (an action) must never be added.
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
