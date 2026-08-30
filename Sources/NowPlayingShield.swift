import Cocoa
import AVFoundation
import MediaPlayer

/// 会議中だけ「再生中アプリ（Now Playing）」の座を奪う。
///
/// 実機検証の結論: メディアキーは CGEventTap では抑制できない。
/// cgSessionEventTap / cghidEventTap のどちらで消費しても Music は起動する。
/// now playing の配送（mediaremoted）が CG イベントパイプラインの外にあるため。
///
/// 唯一効くのは、OS から見た「いま再生しているアプリ」を自分にすること。
/// そうすると再生/一時停止コマンドは Music ではなくこのアプリに届く。
/// 座を奪うには実際に音を鳴らしている必要があるので、無音のループを流す。
///
/// 会議中だけ有効にするのが肝。常時奪うと音楽の操作ができなくなる。
final class NowPlayingShield {

    /// タップが動いていないときの保険としてミュートを実行するためのフック。
    var onCommandFallback: (() -> Void)?
    /// タップ側が処理できているか。true のときコマンドは握り潰すだけにする。
    var isTapHandlingKeys: () -> Bool = { true }

    private(set) var isActive = false
    private var player: AVAudioPlayer?
    private var registeredCommands: [(MPRemoteCommand, Any)] = []

    func activate() {
        guard !isActive else { return }
        guard startSilentPlayback() else {
            NSLog("MeetMute: 無音再生を開始できず、Now Playing を取得できませんでした")
            return
        }
        registerCommands()

        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "会議中（MeetMute）",
            MPMediaItemPropertyArtist: "EarPods のボタンでミュート",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        MPNowPlayingInfoCenter.default().playbackState = .playing
        isActive = true
    }

    func deactivate() {
        guard isActive else { return }
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        unregisterCommands()
        player?.stop()
        player = nil
        isActive = false
    }

    // MARK: - リモートコマンド

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        let commands: [MPRemoteCommand] = [
            center.togglePlayPauseCommand,
            center.playCommand,
            center.pauseCommand,
        ]
        for command in commands {
            command.isEnabled = true
            let token = command.addTarget { [weak self] _ in
                self?.handleCommand()
                return .success
            }
            registeredCommands.append((command, token))
        }
        // 次へ/前へ（EarPods の 2 回押し/3 回押し）はこのアプリの担当外。
        // 奪ったままにすると曲送りができなくなるので明示的に無効化する。
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private func unregisterCommands() {
        for (command, token) in registeredCommands {
            command.removeTarget(token)
            command.isEnabled = false
        }
        registeredCommands.removeAll()
    }

    /// 通常はイベントタップ側がミュートを実行するので、ここは受け取るだけ（＝Music に行かせない盾）。
    /// 入力監視が切れているなど、タップが動いていないときだけ自分でミュートする。
    private func handleCommand() {
        guard !isTapHandlingKeys() else { return }
        onCommandFallback?()
    }

    // MARK: - 無音再生

    private func startSilentPlayback() -> Bool {
        do {
            let player = try AVAudioPlayer(data: NowPlayingShield.silentWAV())
            player.numberOfLoops = -1
            player.volume = 1.0   // 中身が無音なので音は出ない
            player.prepareToPlay()
            guard player.play() else { return false }
            self.player = player
            return true
        } catch {
            NSLog("MeetMute: 無音再生の生成に失敗: \(error)")
            return false
        }
    }

    /// 1 秒ぶんの無音 WAV。外部ファイルを持たずに済ませる。
    private static func silentWAV(seconds: Double = 1.0, sampleRate: Int = 44_100) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let bytesPerFrame = channels * bitsPerSample / 8
        let dataSize = Int(Double(sampleRate) * seconds) * bytesPerFrame

        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        ascii("RIFF"); u32(UInt32(36 + dataSize)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * bytesPerFrame))
        u16(UInt16(bytesPerFrame)); u16(UInt16(bitsPerSample))
        ascii("data"); u32(UInt32(dataSize))
        data.append(Data(count: dataSize))
        return data
    }
}
