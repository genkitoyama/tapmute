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
        /// The meeting window never came to the front, so the shortcut was withheld.
        case notFocused
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

        bringForward(target)

        waitUntilFocused(target, attempts: 3, delay: delay) { focused in
            // A shortcut sent to the wrong window does real damage (⌘D bookmarks the page in
            // another browser window), so nothing is sent unless the meeting is in front.
            guard focused else {
                self.restore(target: target, previousTabTitle: previousTabTitle, previousApp: previousApp)
                self.isBusy = false
                completion(.notFocused)
                return
            }
            shortcut.post()

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.restore(target: target, previousTabTitle: previousTabTitle, previousApp: previousApp)
                self.isBusy = false
                completion(.sent(target))
            }
        }
    }

    /// Activate first, then raise. In the other order the app comes up with its previous key
    /// window on top, which with two browser windows is the wrong one.
    private func bringForward(_ target: MeetingTarget) {
        AccessibilityHelper.activate(target.app)
        if let window = target.window {
            AccessibilityHelper.raise(window, in: target.app)
        }
    }

    /// Wait for the app to be frontmost with the meeting window focused, raising it again
    /// between attempts.
    private func waitUntilFocused(_ target: MeetingTarget, attempts: Int, delay: TimeInterval,
                                  completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if self.isFocused(target) {
                completion(true)
            } else if attempts > 1 {
                self.bringForward(target)
                self.waitUntilFocused(target, attempts: attempts - 1, delay: delay, completion: completion)
            } else {
                completion(false)
            }
        }
    }

    private func isFocused(_ target: MeetingTarget) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app.processIdentifier
        else { return false }
        let patterns = Preferences.shared.settings(for: target.profile).titlePatterns
        return TitleMatcher.matches(title: AccessibilityHelper.focusedWindowTitle(of: target.app),
                                    patterns: patterns)
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
