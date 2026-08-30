import Cocoa
import ApplicationServices
import IOKit.hid

/// Checking the permissions this app needs, and pointing at the right settings pane.
///
/// Input Monitoring is the one that gets missed. Without it CGEvent.tapCreate returns nil and
/// the app launches but does nothing, so it must be surfaced in the UI.
enum PermissionManager {

    enum Permission: String, CaseIterable {
        case accessibility
        case inputMonitoring
        case screenRecording

        var title: String {
            switch self {
            case .accessibility: return "アクセシビリティ"
            case .inputMonitoring: return "入力監視"
            case .screenRecording: return "画面収録"
            }
        }

        var reason: String {
            switch self {
            case .accessibility:
                return "会議ウィンドウの走査、ミュートのキー送出、ウィンドウの前面化に必要。"
            case .inputMonitoring:
                return "EarPods の再生ボタン（メディアキー）を受け取るために必要。"
            case .screenRecording:
                return "別デスクトップ（Space）にある会議ウィンドウの題名を読むために使う。任意だが、"
                     + "会議を別 Space に置くなら実質必須。"
            }
        }

        var isRequired: Bool { self != .screenRecording }

        var settingsURL: URL {
            let anchor: String
            switch self {
            case .accessibility: anchor = "Privacy_Accessibility"
            case .inputMonitoring: anchor = "Privacy_ListenEvent"
            case .screenRecording: anchor = "Privacy_ScreenCapture"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }

        var isGranted: Bool {
            switch self {
            case .accessibility:
                return AXIsProcessTrusted()
            case .inputMonitoring:
                return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            case .screenRecording:
                return CGPreflightScreenCaptureAccess()
            }
        }
    }

    /// Whether every required permission is present.
    static var isReady: Bool {
        Permission.allCases.filter(\.isRequired).allSatisfy(\.isGranted)
    }

    static var missingRequired: [Permission] {
        Permission.allCases.filter { $0.isRequired && !$0.isGranted }
    }

    /// Check while also showing the system dialog (for first launch).
    static func request(_ permission: Permission) {
        switch permission {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
        openSettings(permission)
    }

    static func openSettings(_ permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    /// Right after granting, a restart is sometimes needed for it to take effect.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
