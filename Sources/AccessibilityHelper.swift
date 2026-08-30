import Cocoa
import ApplicationServices

/// 見つけたウィンドウ 1 つぶん。AX 要素が取れない経路（WindowServer 由来）ではタイトルだけになる。
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

/// AX API と WindowServer の薄いラッパー。
///
/// 実機で確認した重要な性質:
///   - kAXWindowsAttribute は「現在の Space にあるウィンドウ」しか返さない。会議を別デスクトップに
///     置いていると 0 件になるため、これだけに頼ると検出が沈黙する。
///   - kAXMainWindow / kAXFocusedWindow は別 Space のアプリでもタイトルが取れる。
///   - CGWindowList は全 Space を横断できるが、タイトル取得に画面収録権限が要る。
/// この 3 経路を束ねて 1 つのリストにするのが windows(for:) の役目。
enum AccessibilityHelper {

    // MARK: - 汎用アクセサ

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

    // MARK: - ウィンドウの列挙

    static func windows(for app: NSRunningApplication, includeWindowServer: Bool) -> [WindowInfo] {
        var byTitle: [String: WindowInfo] = [:]
        var order: [String] = []

        /// 同じ題名が複数の経路から来る。AX 要素を持つものを優先して残す
        /// （前面化やタブ操作に要素が要るため）。
        func add(_ rawTitle: String, _ element: AXUIElement?, _ source: WindowInfo.Source) {
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            if let existing = byTitle[title], existing.element != nil || element == nil { return }
            if byTitle[title] == nil { order.append(title) }
            byTitle[title] = WindowInfo(title: title, element: element, source: source)
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // 1) 現在の Space にあるウィンドウ
        for window in (attribute(axApp, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] {
            if bool(window, kAXMinimizedAttribute as String) == true { continue }
            add(title(window), window, .axWindowList)
        }

        // 2) 別 Space にいても取れるメイン / フォーカスウィンドウ
        for key in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            guard let value = attribute(axApp, key as String) else { continue }
            let window = value as! AXUIElement
            if bool(window, kAXMinimizedAttribute as String) == true { continue }
            add(title(window), window, .axMainWindow)
        }

        // 3) 全 Space を横断できるが AX 要素は伴わない
        if includeWindowServer {
            for title in windowServerTitles(pid: app.processIdentifier) {
                add(title, nil, .windowServer)
            }
        }

        return order.compactMap { byTitle[$0] }
    }

    /// CGWindowList から、そのプロセスが持つウィンドウ名を拾う。
    /// 画面収録権限がない場合は名前が空で返るため、結果は自然に空になる。
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

    /// 画面収録権限があるか（= 他プロセスのウィンドウ名が読めるか）を実測する。
    /// API で直接聞けないので、自分以外のウィンドウ名が 1 つでも取れるかで判定する。
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

    // MARK: - タブの探索

    /// ウィンドウの中から、タイトルが patterns に一致し AXPress を持つ要素（＝タブ）を探す。
    ///
    /// Chrome 系は AXTabGroup > AXRadioButton、Dia は AXUnknown + AXPress と構造が違うので、
    /// ロールではなく「押せること」と「タイトルが一致すること」で拾う。
    /// AXWebArea 以下はページ本体なので降りない（DOM 全走査を避ける）。
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

    // MARK: - 操作

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
