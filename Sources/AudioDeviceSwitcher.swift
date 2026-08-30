import Foundation
import CoreAudio

/// Makes a named device the system input and output as soon as it is plugged in.
///
/// macOS usually switches the *output* to a newly connected USB headset on its own, but leaves
/// the *input* on the built-in microphone. That mismatch is the thing worth automating.
///
/// Only devices that were not present a moment ago are acted on. Reacting to every change of the
/// device list would fight the user whenever they pick a device by hand.
final class AudioDeviceSwitcher {

    /// Called on the main thread with the device name after a switch.
    var onSwitched: ((String) -> Void)?

    private let queue = DispatchQueue(label: "io.github.genkitoyama.meetmute.audio")
    private var listener: AudioObjectPropertyListenerBlock?
    private var knownUIDs = Set<String>()

    var isRunning: Bool { listener != nil }

    func start() {
        guard listener == nil else { return }
        // Take a snapshot without switching: devices already connected at launch are not "new".
        knownUIDs = Set(AudioDevices.all().map(\.uid))
        listener = AudioDevices.observeDeviceList(on: queue) { [weak self] in
            self?.deviceListChanged()
        }
    }

    func stop() {
        if let listener {
            AudioDevices.removeDeviceListObserver(listener, on: queue)
        }
        listener = nil
        knownUIDs.removeAll()
    }

    private func deviceListChanged() {
        let devices = AudioDevices.all()
        let current = Set(devices.map(\.uid))
        let appeared = devices.filter { !knownUIDs.contains($0.uid) }
        knownUIDs = current

        guard Preferences.shared.autoSwitchAudioDevice else { return }
        let patterns = Preferences.shared.audioDevicePatterns
        guard !patterns.isEmpty else { return }

        guard let target = appeared.first(where: { TitleMatcher.matches(title: $0.name, patterns: patterns) })
        else { return }

        // A freshly registered device is not always ready to become the default straight away.
        queue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.makeDefault(target)
        }
    }

    private func makeDefault(_ device: AudioDevices.Device) {
        var switched = false
        if device.hasInput {
            switched = AudioDevices.setDefault(device.id, role: .input) || switched
        }
        if device.hasOutput {
            switched = AudioDevices.setDefault(device.id, role: .output) || switched
            AudioDevices.setDefault(device.id, role: .systemOutput)
        }
        guard switched else {
            NSLog("MeetMute: could not switch audio to \(device.name)")
            return
        }
        DispatchQueue.main.async { self.onSwitched?(device.name) }
    }
}
