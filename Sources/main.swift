import Cocoa

// CLI probes. They exist to check the mechanism from a terminal before granting the app anything.
// (They run with the terminal's own Accessibility / Input Monitoring permissions.)
let arguments = CommandLine.arguments

// Probe output is usually read through a pipe, so flush it line by line
if arguments.contains("--probe-keys") || arguments.contains("--probe-windows")
    || arguments.contains("--probe-mute-markers") || arguments.contains("--probe-audio") {
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
    // Regression check for the classifier against wording captured from the real apps.
    // When a reading goes wrong, this narrows it down before digging through accessibility again.
    let fixtures: [(app: String, text: String, isControl: Bool, expected: MuteState?)] = [
        ("Zoom",  "自分のオーディオをミュート解除する", true, .muted),
        ("Zoom",  "自分のオーディオをミュートする", true, .unmuted),
        ("Zoom",  "参加者名, ミュートされたコンピュータ オーディオ", false, .muted),
        ("Zoom",  "参加者名, ミュート解除されたコンピュータ オーディオ", false, .unmuted),
        ("Teams", "マイクのミュートを解除", true, .muted),
        ("Teams", "マイクのミュート", true, .unmuted),
        // A video tile description cannot settle the state, so it must not decide the reading
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

if arguments.contains("--probe-audio") {
    // Shows which audio devices the auto-switch would react to.
    // Run it with the headset plugged in to check the name patterns.
    let patterns = Preferences.shared.audioDevicePatterns
    print("Auto-switch: \(Preferences.shared.autoSwitchAudioDevice ? "on" : "off")")
    print("Patterns: \(patterns.joined(separator: ", "))")
    print("")
    let current = (
        input: AudioDevices.defaultDevice(.input),
        output: AudioDevices.defaultDevice(.output)
    )
    for device in AudioDevices.all() {
        var marks: [String] = []
        if device.id == current.input { marks.append("default input") }
        if device.id == current.output { marks.append("default output") }
        if TitleMatcher.matches(title: device.name, patterns: patterns) { marks.append("MATCHES") }
        print("\(device.name)  in=\(device.inputChannels) out=\(device.outputChannels)"
              + (marks.isEmpty ? "" : "  [\(marks.joined(separator: ", "))]"))
    }
    exit(0)
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
