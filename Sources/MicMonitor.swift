import Foundation

/// Checks whether an input device is held by someone (= a call is probably in progress).
/// Conferencing apps keep the input stream open even while muted, so "mic running" is a hint
/// about being in a call, not about mute state.
enum MicMonitor {
    static func isInputActive() -> Bool {
        AudioDevices.all()
            .filter(\.hasInput)
            .contains { AudioDevices.isRunningSomewhere($0.id) }
    }
}
