import Cocoa
import AVFoundation
import MediaPlayer

/// Takes over the "Now Playing" role, but only while a meeting is detected.
///
/// Measured on real hardware: a media key cannot be suppressed with a CGEventTap.
/// Music launches even when the event is consumed at cgSessionEventTap or cghidEventTap,
/// because now-playing delivery (mediaremoted) lives outside the CG event pipeline.
///
/// The only thing that works is becoming, from the system's point of view, the app that is
/// currently playing. Play/pause commands are then delivered here instead of to Music.
/// Taking the role requires actually producing audio, so a silent loop is played.
///
/// Holding it only during meetings is essential: holding it always would break music control.
final class NowPlayingShield {

    /// Hook used to perform the mute as a fallback when the tap is not running.
    var onCommandFallback: (() -> Void)?
    /// Whether the tap is handling keys. When true, commands are merely absorbed.
    var isTapHandlingKeys: () -> Bool = { true }

    private(set) var isActive = false
    private var player: AVAudioPlayer?
    private var registeredCommands: [(MPRemoteCommand, Any)] = []
    private var reassertTimer: Timer?
    private var startedAt = Date()

    func activate() {
        guard !isActive else { return }
        guard startSilentPlayback() else {
            NSLog("TapMute: 無音再生を開始できず、Now Playing を取得できませんでした")
            return
        }
        registerCommands()
        startedAt = Date()
        publishNowPlaying()

        // Another app that starts playing takes the role away from us. A browser tab with a
        // media session (a YouTube tab, say) will otherwise receive the key and start playing.
        // Re-publishing keeps this app looking like the current player.
        reassertTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.publishNowPlaying(restartPlayback: true)
        }
        isActive = true
    }

    /// Re-take the role right after a key press, so the next press is more likely to land here.
    func reassert() {
        guard isActive else { return }
        publishNowPlaying(restartPlayback: true)
    }

    /// A now playing entry with a duration and a moving elapsed time. Without those the system
    /// treats the claim as weaker than a real player's.
    private func publishNowPlaying(restartPlayback: Bool = false) {
        // Republishing the metadata is not enough: the system hands the role to whichever app
        // most recently *started* playing. A browser tab that starts a video therefore takes it
        // from us. Making a real paused -> playing transition is what puts this app back on top.
        if restartPlayback, let player {
            player.pause()
            MPNowPlayingInfoCenter.default().playbackState = .paused
            player.currentTime = 0
            player.play()
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "会議中（TapMute）",
            MPMediaItemPropertyArtist: "EarPods のボタンでミュート",
            MPMediaItemPropertyPlaybackDuration: 60 * 60 * 24.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    func deactivate() {
        guard isActive else { return }
        reassertTimer?.invalidate()
        reassertTimer = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        unregisterCommands()
        player?.stop()
        player = nil
        isActive = false
    }

    // MARK: - Remote commands

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
        // Next / previous (double and triple press on EarPods) are not this app's business.
        // Holding those would break skipping tracks, so they are disabled explicitly.
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

    /// Normally the event tap performs the mute, so this only absorbs the command (a shield that
    /// keeps it away from Music). It mutes itself only when the tap is not running.
    private func handleCommand() {
        guard !isTapHandlingKeys() else { return }
        onCommandFallback?()
    }

    // MARK: - Silent playback

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
            NSLog("TapMute: 無音再生の生成に失敗: \(error)")
            return false
        }
    }

    /// One second of silent WAV, so no external file is needed.
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
