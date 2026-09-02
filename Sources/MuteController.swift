import Cocoa
import ApplicationServices

/// Delivers the mute shortcut to the detected target.
///
/// Zoom honours a global shortcut, so the key is simply sent.
/// Meet / Teams need a round trip: focus -> key -> restore. A second key press during the
/// round trip would corrupt the state, so it is rejected with a busy flag.
final class MuteController {

    enum Result {
        case sent(MeetingTarget)
        case busy
        /// The control to press could not be found. Nothing was sent.
        case controlNotFound
    }

    private(set) var isBusy = false

    func toggle(_ target: MeetingTarget, completion: @escaping (Result) -> Void) {
        guard !isBusy else {
            completion(.busy)
            return
        }
        switch target.profile.activation {
        case .pressControl:
            press(target, completion: completion)
        case .globalShortcut:
            Preferences.shared.shortcut(for: target.profile)?.post()
            completion(.sent(target))
        case .focusThenShortcut:
            guard let shortcut = Preferences.shared.shortcut(for: target.profile) else {
                completion(.controlNotFound)
                return
            }
            focusAndSend(target, shortcut: shortcut, completion: completion)
        }
    }

    /// Press the mute control directly. Nothing is focused and no Space is switched, which is
    /// why this is preferred whenever the control exposes AXPress.
    /// The search costs ~0.2s, so it happens off the main thread.
    private func press(_ target: MeetingTarget, completion: @escaping (Result) -> Void) {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let control = MuteStateReader.read(target).control
            DispatchQueue.main.async {
                defer { self.isBusy = false }
                guard let control else {
                    completion(.controlNotFound)
                    return
                }
                AccessibilityHelper.press(control)
                completion(.sent(target))
            }
        }
    }

    /// Bring the target forward, send the key, and return to the previous app (and tab).
    private func focusAndSend(_ target: MeetingTarget, shortcut: Shortcut, completion: @escaping (Result) -> Void) {
        isBusy = true

        let previousApp = NSWorkspace.shared.frontmostApplication
        let delay = Preferences.shared.focusDelay

        // When a tab switch is needed, remember the currently shown tab so it can be restored
        var previousTabTitle: String?
        if let tab = target.tab, let window = target.window {
            let currentTitle = AccessibilityHelper.title(window)
            if !currentTitle.isEmpty && currentTitle != AccessibilityHelper.title(tab) {
                previousTabTitle = currentTitle
            }
            AccessibilityHelper.press(tab)
        }

        if let window = target.window {
            AccessibilityHelper.raise(window)
        }
        AccessibilityHelper.activate(target.app)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            shortcut.post()

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.restore(target: target, previousTabTitle: previousTabTitle, previousApp: previousApp)
                self.isBusy = false
                completion(.sent(target))
            }
        }
    }

    private func restore(target: MeetingTarget, previousTabTitle: String?, previousApp: NSRunningApplication?) {
        if let title = previousTabTitle, let window = target.window {
            let pattern = "^" + NSRegularExpression.escapedPattern(for: title) + "$"
            if let tab = AccessibilityHelper.findPressableTab(in: window, matching: [pattern]) {
                AccessibilityHelper.press(tab)
            }
        }

        guard let previousApp,
              !previousApp.isTerminated,
              previousApp.processIdentifier != target.app.processIdentifier
        else { return }
        AccessibilityHelper.activate(previousApp)
    }
}
