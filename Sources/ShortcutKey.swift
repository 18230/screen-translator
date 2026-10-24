import AppKit
import Carbon

enum ShortcutKey {
    static let functionNames: [UInt16: String] = {
        let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return Dictionary(uniqueKeysWithValues: codes.enumerated().map { (UInt16($0.element), "F\($0.offset + 1)") })
    }()

    static func label(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> String? {
        // Function keys have private-use Unicode characters (or no characters).
        // Identify them by physical key code before checking ordinary text input.
        if let function = functionNames[keyCode] { return function }
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        let special: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        if let name = special[keyCode] { return name }
        guard let characters, !characters.isEmpty else { return nil }
        let label = characters.uppercased()
        guard label.unicodeScalars.allSatisfy({
            $0.properties.generalCategory != .control && $0.properties.generalCategory != .privateUse
        }) else { return nil }
        return label
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        // Fn/.function is not a Carbon modifier; Fn+F2 should register as F2.
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
