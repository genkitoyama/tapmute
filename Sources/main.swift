import Cocoa

// CLI プローブ。アプリに権限を与える前に、仕組みが動くかをターミナルから確かめるためのもの。
// （ターミナル自身のアクセシビリティ / 入力監視の権限で動く）
let arguments = CommandLine.arguments

// プローブはパイプ越しに見ることが多いので、行ごとに吐き出させる
if arguments.contains("--probe-keys") || arguments.contains("--probe-windows")
    || arguments.contains("--probe-mute-markers") {
    setvbuf(stdout, nil, _IOLBF, 0)
}

if arguments.contains("--probe-windows") {
    let detector = MeetingDetector()
    let target = detector.scanSynchronously()
    print("検出結果: " + (target.map { "\($0.displayName) — \($0.matchedTitle)  (経路: \($0.source.rawValue))" } ?? "なし"))
    print("")
    print(detector.debugReport())
    exit(0)
}

if arguments.contains("--probe-mute-markers") {
    // 実機で採取した文言に対する判定の回帰チェック。
    // アプリの読みが狂ったとき、AX を掘り直す前にここで切り分けられる。
    let fixtures: [(app: String, text: String, isControl: Bool, expected: MuteState?)] = [
        ("Zoom",  "自分のオーディオをミュート解除する", true, .muted),
        ("Zoom",  "自分のオーディオをミュートする", true, .unmuted),
        ("Zoom",  "Genki, ミュートされたコンピュータ オーディオ", false, .muted),
        ("Zoom",  "Genki, ミュート解除されたコンピュータ オーディオ", false, .unmuted),
        ("Teams", "マイクのミュートを解除", true, .muted),
        ("Teams", "マイクのミュート", true, .unmuted),
        // 動画タイルの説明は状態を断定できないので、判定に使ってはいけない
        ("Teams", "自分のビデオ, ミュート解除, ビデオがオンになっています", false, nil),
        ("Meet",  "Turn on microphone", true, .muted),
        ("Meet",  "Turn off microphone", true, .unmuted),
        ("Meet",  "マイクをオンにする", true, .muted),
        ("Meet",  "マイクをオフにする", true, .unmuted),
    ]
    let hints = MuteHints.standard(searchWebArea: true)
    var failures = 0
    for fixture in fixtures {
        let actual = MuteStateReader.classify(text: fixture.text, isControl: fixture.isControl, hints: hints)
        let ok = actual == fixture.expected
        if !ok { failures += 1 }
        let describe: (MuteState?) -> String = { state in
            switch state {
            case .some(.muted): return "ミュート中"
            case .some(.unmuted): return "解除中"
            case .some(.unknown), .none: return "判定なし"
            }
        }
        print("\(ok ? "OK  " : "NG  ") [\(fixture.app)] \"\(fixture.text)\" → \(describe(actual))"
              + (ok ? "" : "（期待: \(describe(fixture.expected))）"))
    }
    print(failures == 0 ? "\n全 \(fixtures.count) 件一致" : "\n\(failures) 件が不一致")
    exit(failures == 0 ? 0 : 1)
}

if arguments.contains("--probe-keys") {
    let detector = MeetingDetector()
    let tap = MediaKeyTap()
    tap.onPlayPause = {
        let target = detector.scanSynchronously()
        let name = target.map { "\($0.displayName) — \($0.matchedTitle)" } ?? "会議なし（音楽側に素通し）"
        print("PLAY 押下 → \(name)")
        return false  // プローブでは消費しない
    }
    do {
        try tap.start()
        print("メディアキーを監視中。EarPods の中央ボタンを押してください。Ctrl+C で終了。")
        CFRunLoopRun()
    } catch {
        print("失敗: \(error.localizedDescription)")
        print("システム設定 → プライバシーとセキュリティ → 入力監視 で、このターミナルを許可してください。")
        exit(1)
    }
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
