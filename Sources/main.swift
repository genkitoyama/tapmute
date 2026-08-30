import Cocoa

// CLI プローブ。アプリに権限を与える前に、仕組みが動くかをターミナルから確かめるためのもの。
// （ターミナル自身のアクセシビリティ / 入力監視の権限で動く）
let arguments = CommandLine.arguments

// プローブはパイプ越しに見ることが多いので、行ごとに吐き出させる
if arguments.contains("--probe-keys") || arguments.contains("--probe-windows") {
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
