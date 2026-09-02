import Cocoa
import ApplicationServices

/// One window that was found. Sources without an AX element (the WindowServer) carry only a title.
struct WindowInfo {
    enum Source: String {
        case axWindowList   // kAXWindows。現在の Space にあるウィンドウしか返らない
        case axMainWindow   // kAXMainWindow / kAXFocusedWindow。別 Space でも取れる
        case windowServer   // CGWindowList。全 Space を横断できるが画面収録権限が要る
    }

    let title: String
    let element: AXUIElement?
    let source: Source
}

/// Thin wrappers over the accessibility API and the WindowServer.
///
/// Properties measured on real hardware:
///   - kAXWindowsAttribute only returns windows on the current Space. With the meeting on
///     another desktop it returns nothing, so relying on it alone makes detection go silent.
///   - kAXMainWindow / kAXFocusedWindow still return a title for apps on another Space.
///   - CGWindowList spans every Space, but reading titles requires Screen Recording.
/// Combining those three into one list is what windows(for:) is for.
enum AccessibilityHelper {

    // MARK: - Generic accessors

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        attribute(element, name) as? Bool
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func title(_ element: AXUIElement) -> String {
        string(element, kAXTitleAttribute as String) ?? ""
    }

    // MARK: - Enumerating windows

    static func windows(for app: NSRunningApplication, includeWindowServer: Bool) -> [WindowInfo] {
        var byTitle: [String: WindowInfo] = [:]
        var order: [String] = []

        /// The same title arrives from several sources. Keep the one carrying an AX element,
        /// since focusing and tab switching need it.
        func add(_ rawTitle: String, _ element: AXUIElement?, _ source: WindowInfo.Source) {
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            if let existing = byTitle[title], existing.element != nil || element == nil { return }
            if byTitle[title] == nil { order.append(title) }
            byTitle[title] = WindowInfo(title: title, element: element, source: source)
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // 1) Windows on the current Space
        for window in (attribute(axApp, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] {
            if bool(window, kAXMinimizedAttribute as String) == true { continue }
            add(title(window), window, .axWindowList)
        }

        // 2) Main / focused window, readable even on another Space
        for key in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            guard let value = attribute(axApp, key as String) else { continue }
            let window = value as! AXUIElement
            if bool(window, kAXMinimizedAttribute as String) == true { continue }
            add(title(window), window, .axMainWindow)
        }

        // 3) Spans every Space, but carries no AX element
        if includeWindowServer {
            for title in windowServerTitles(pid: app.processIdentifier) {
                add(title, nil, .windowServer)
            }
        }

        return order.compactMap { byTitle[$0] }
    }

    /// Collect the window names owned by a process from CGWindowList.
    /// Without Screen Recording the names come back empty, so the result is naturally empty.
    static func windowServerTitles(pid: pid_t) -> [String] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let name = entry[kCGWindowName as String] as? String,
                  !name.isEmpty
            else { return nil }
            return name
        }
    }

    /// Measure whether Screen Recording is granted (= other processes' window names are readable).
    /// There is no API to ask directly, so check whether any name outside this process can be read.
    static func canReadWindowServerTitles() -> Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  let name = entry[kCGWindowName as String] as? String
            else { return false }
            return !name.isEmpty
        }
    }

    // MARK: - Finding tabs

    /// Find an element inside a window whose title matches patterns and that supports AXPress (a tab).
    ///
    /// Chrome exposes AXTabGroup > AXRadioButton while Dia uses AXUnknown with AXPress, so the
    /// structures differ. Match on "is pressable" and "the title matches" rather than on role.
    /// Do not descend into AXWebArea: that is page content, and walking the whole DOM is wasteful.
    static func findPressableTab(in window: AXUIElement, matching patterns: [String]) -> AXUIElement? {
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 12, visited < 600 else { return nil }
            visited += 1

            let role = string(element, kAXRoleAttribute as String) ?? ""
            if role == "AXWebArea" { return nil }

            if depth > 0 {
                let label = title(element)
                if TitleMatcher.matches(title: label, patterns: patterns),
                   actions(element).contains(kAXPressAction as String) {
                    return element
                }
            }

            for child in children(element) {
                if let hit = walk(child, depth: depth + 1) { return hit }
            }
            return nil
        }
        return walk(window, depth: 0)
    }

    /// Whether the window contains an element whose title or description matches.
    /// Used for apps whose window title says nothing about being in a call (Slack huddles).
    static func containsElement(in window: AXUIElement,
                                matching patterns: [String],
                                maxDepth: Int = 30,
                                budget: Int = 3000) -> Bool {
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) -> Bool {
            guard depth < maxDepth, visited < budget else { return false }
            visited += 1

            let text = title(element) + " " + (string(element, kAXDescriptionAttribute as String) ?? "")
            if TitleMatcher.matches(title: text, patterns: patterns) { return true }

            for child in children(element) where walk(child, depth: depth + 1) { return true }
            return false
        }
        return walk(window, depth: 0)
    }

    /// Processes whose page accessibility has been enabled. Setting it once is enough.
    private static var webAccessibilityEnabled = Set<pid_t>()

    /// Chromium and Electron apps do not build an accessibility tree for their content by
    /// default. Setting this attribute makes them build it (the mechanism screen readers rely
    /// on). It is set only when a meeting is being looked for, so it is not a permanent cost.
    static func enableWebAccessibility(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !webAccessibilityEnabled.contains(pid) else { return }
        let axApp = AXUIElementCreateApplication(pid)
        for key in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            AXUIElementSetAttributeValue(axApp, key as CFString, kCFBooleanTrue)
        }
        webAccessibilityEnabled.insert(pid)
    }

    // MARK: - Actions

    static func press(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    static func raise(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    static func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
