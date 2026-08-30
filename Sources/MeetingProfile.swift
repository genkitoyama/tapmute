import Cocoa

/// How to find one kind of conferencing app, and how to hit its mute.
/// Every difference between Zoom / Meet / Teams is reduced to values in this struct.
struct MeetingProfile {
    enum Host {
        /// A dedicated app, matched by bundle identifier.
        case nativeApp
        /// A service inside a browser, matched by window or tab title.
        case browser
    }

    let id: String
    let displayName: String
    let host: Host
    /// Bundle identifiers matched exactly
    let bundleIDs: [String]
    /// Bundle identifier prefixes (Chrome / Edge PWAs carry a hash and cannot be hardcoded)
    let bundleIDPrefixes: [String]
    /// Regexes for window / tab titles that mean a meeting is running (editable in Settings)
    let defaultTitlePatterns: [String]
    /// The mute shortcut
    let defaultShortcut: String
    /// true when the target window must be brought forward before the key is sent
    let needsFocus: Bool
    /// Hints for reading the current mute state through accessibility
    let muteHints: MuteHints

    var isBrowser: Bool { host == .browser }

    static let all: [MeetingProfile] = [zoom, meet, teams]

    static func profile(id: String) -> MeetingProfile? { all.first { $0.id == id } }

    /// Zoom honours a global shortcut, so the key can be sent without focusing anything.
    /// (Requires Zoom -> Settings -> Keyboard Shortcuts -> "Enable Global Shortcut".)
    static let zoom = MeetingProfile(
        id: "zoom",
        displayName: "Zoom",
        host: .nativeApp,
        bundleIDs: ["us.zoom.xos"],
        bundleIDPrefixes: [],
        // Outside a meeting the windows are "Zoom Workplace" / "Zoom client health check", so no false positives
        defaultTitlePatterns: ["Meeting", "ミーティング"],
        defaultShortcut: "cmd+shift+a",
        needsFocus: false,
        muteHints: MuteHints.standard(searchWebArea: false)
    )

    /// Meet is a browser tab. Both the PWA (com.google.Chrome.app.<hash>) and a plain tab are checked.
    static let meet = MeetingProfile(
        id: "meet",
        displayName: "Google Meet",
        host: .browser,
        bundleIDs: [
            "com.google.Chrome",
            "com.google.Chrome.beta",
            "company.thebrowser.dia",     // Dia
            "company.thebrowser.Browser", // Arc
            "com.microsoft.edgemac",
            "com.brave.Browser",
        ],
        bundleIDPrefixes: ["com.google.Chrome.app.", "com.microsoft.edgemac.app."],
        // A tab in a call reads "Meet - abc-defg-hij". Anchor at the start so pages that merely
        // contain the word, such as a Google Meet help article, are not picked up.
        defaultTitlePatterns: ["^Meet\\s*[-–—]", "^Meet$"],
        defaultShortcut: "cmd+d",
        needsFocus: true,
        // Meet's control lives inside the page; unreachable unless Chromium's AX generation is enabled
        muteHints: MuteHints.standard(searchWebArea: true)
    )

    /// New Teams (com.microsoft.teams2). It has no global shortcut, so focusing is required.
    static let teams = MeetingProfile(
        id: "teams",
        displayName: "Microsoft Teams",
        host: .nativeApp,
        bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
        bundleIDPrefixes: [],
        defaultTitlePatterns: ["Meeting", "会議", "ミーティング"],
        defaultShortcut: "cmd+shift+m",
        needsFocus: true,
        // New Teams is a web shell. Its button sits around depth 20
        muteHints: MuteHints.standard(searchWebArea: true)
    )
}

/// Cache of compiled regexes.
/// detect() runs on every key press, so NSRegularExpression is not rebuilt each time.
enum TitleMatcher {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func matches(title: String, patterns: [String]) -> Bool {
        guard !title.isEmpty else { return false }
        for pattern in patterns where !pattern.isEmpty {
            guard let regex = regex(for: pattern) else {
                // Treat a pattern that fails to compile as a plain substring match
                if title.localizedCaseInsensitiveContains(pattern) { return true }
                continue
            }
            let range = NSRange(title.startIndex..., in: title)
            if regex.firstMatch(in: title, options: [], range: range) != nil { return true }
        }
        return false
    }

    private static func regex(for pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[pattern] { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        cache[pattern] = regex
        return regex
    }
}
