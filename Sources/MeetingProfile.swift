import Cocoa

/// 会議アプリ 1 種類ぶんの「見つけ方」と「ミュートの叩き方」。
/// Zoom / Meet / Teams の違いはすべてこの構造体の値の違いに落とす。
struct MeetingProfile {
    enum Host {
        /// 専用アプリ。バンドル ID を直接照合する。
        case nativeApp
        /// ブラウザ上のサービス。ウィンドウタイトル or タブタイトルで照合する。
        case browser
    }

    let id: String
    let displayName: String
    let host: Host
    /// 完全一致で探すバンドル ID
    let bundleIDs: [String]
    /// 前方一致で探すバンドル ID（Chrome / Edge の PWA はハッシュ付きで決め打ちできない）
    let bundleIDPrefixes: [String]
    /// 会議中と判定するウィンドウ / タブタイトルの正規表現（ユーザーが設定で編集できる）
    let defaultTitlePatterns: [String]
    /// ミュートのショートカット
    let defaultShortcut: String
    /// true ならキー送出の前に対象ウィンドウを前面化する必要がある
    let needsFocus: Bool
    /// 現在のミュート状態を AX から読むための手がかり
    let muteHints: MuteHints

    var isBrowser: Bool { host == .browser }

    static let all: [MeetingProfile] = [zoom, meet, teams]

    static func profile(id: String) -> MeetingProfile? { all.first { $0.id == id } }

    /// Zoom はグローバルショートカットが効くので、前面化せずにキーを送るだけでよい。
    /// （Zoom 設定 → キーボードショートカット → 「グローバルショートカットを有効にする」が前提）
    static let zoom = MeetingProfile(
        id: "zoom",
        displayName: "Zoom",
        host: .nativeApp,
        bundleIDs: ["us.zoom.xos"],
        bundleIDPrefixes: [],
        // 非会議時のウィンドウは "Zoom Workplace" / "Zoomクライアントヘルスチェック" なので誤爆しない
        defaultTitlePatterns: ["Meeting", "ミーティング"],
        defaultShortcut: "cmd+shift+a",
        needsFocus: false,
        // ミュート中 : AXTabGroup desc="… ミュートされた …" / AXButton desc="… ミュート解除する"
        // 解除中     : AXTabGroup desc="… ミュート解除された …" / AXButton desc="… ミュートする"
        muteHints: MuteHints(markers: MuteHints.standard, searchWebArea: false)
    )

    /// Meet はブラウザのタブ。PWA（com.google.Chrome.app.<hash>）と素のタブの両方を見る。
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
        // 通話中のタブは "Meet – abc-defg-hij"。"Google Meet ヘルプ" のような
        // 単に Meet を含むだけのページを拾わないよう、先頭一致にしている。
        defaultTitlePatterns: ["^Meet\\s*[-–—]", "^Meet$"],
        defaultShortcut: "cmd+d",
        needsFocus: true,
        // Meet はページ内のボタン。ミュート中は「マイクをオンにする」を提案してくる
        muteHints: MuteHints(
            markers: [
                ("マイクをオンにする", .muted),
                ("turn on microphone", .muted),
                ("マイクをオフにする", .unmuted),
                ("turn off microphone", .unmuted),
            ] + MuteHints.standard,
            searchWebArea: true
        )
    )

    /// 新 Teams（com.microsoft.teams2）。グローバルショートカットがないため前面化が要る。
    static let teams = MeetingProfile(
        id: "teams",
        displayName: "Microsoft Teams",
        host: .nativeApp,
        bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
        bundleIDPrefixes: [],
        defaultTitlePatterns: ["Meeting", "会議", "ミーティング"],
        defaultShortcut: "cmd+shift+m",
        needsFocus: true,
        muteHints: MuteHints(markers: MuteHints.standard, searchWebArea: false)
    )
}

/// 正規表現のコンパイル結果を使い回すためのキャッシュ。
/// detect() はキー押下のたびに走るので、毎回 NSRegularExpression を作らない。
enum TitleMatcher {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func matches(title: String, patterns: [String]) -> Bool {
        guard !title.isEmpty else { return false }
        for pattern in patterns where !pattern.isEmpty {
            guard let regex = regex(for: pattern) else {
                // 正規表現として壊れている場合はただの部分一致として扱う
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
