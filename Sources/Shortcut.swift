import Cocoa

/// "cmd+shift+a" のような文字列と CGEvent 用のキーコード / モディファイアの相互変換。
struct Shortcut: Equatable {
    var keyCode: CGKeyCode
    var flags: CGEventFlags

    static let keyCodesByName: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "escape": 53,
    ]

    static let modifiersByName: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand,
        "shift": .maskShift,
        "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl,
    ]

    /// "cmd+shift+a" を解釈する。解釈できなければ nil。
    init?(_ text: String) {
        let parts = text.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let keyName = parts.last, let code = Shortcut.keyCodesByName[keyName] else { return nil }

        var flags = CGEventFlags()
        for name in parts.dropLast() {
            guard let mod = Shortcut.modifiersByName[name] else { return nil }
            flags.insert(mod)
        }
        self.keyCode = code
        self.flags = flags
    }

    /// ⇧⌘A のような表示用の文字列。
    var symbolic: String {
        var out = ""
        if flags.contains(.maskControl) { out += "⌃" }
        if flags.contains(.maskAlternate) { out += "⌥" }
        if flags.contains(.maskShift) { out += "⇧" }
        if flags.contains(.maskCommand) { out += "⌘" }
        let name = Shortcut.keyCodesByName.first { $0.value == keyCode }?.key ?? "?"
        return out + name.uppercased()
    }

    /// HID タップに向けてキーを送出する。押しっぱなしのモディファイアが混ざらないよう
    /// down / up の両方で flags を明示する。
    func post() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
