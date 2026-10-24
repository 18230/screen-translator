import AppKit
import Carbon

@main
struct ShortcutTests {
    static func main() {
        for (code, name) in ShortcutKey.functionNames {
            precondition(ShortcutKey.label(keyCode: code, flags: [], characters: nil) == name)
            precondition(ShortcutKey.label(keyCode: code, flags: [.function], characters: "\u{F705}") == name)
        }
        precondition(ShortcutKey.label(keyCode: UInt16(kVK_F2), flags: [], characters: nil) == "F2")
        precondition(ShortcutKey.carbonModifiers([.function]) == 0)
        precondition(ShortcutKey.carbonModifiers([.function, .command, .shift]) == UInt32(cmdKey | shiftKey))
        precondition(ShortcutKey.label(keyCode: UInt16(kVK_ANSI_T), flags: [], characters: "t") == nil)
        precondition(ShortcutKey.label(keyCode: UInt16(kVK_ANSI_T), flags: [.shift], characters: "T") == nil)
        precondition(ShortcutKey.label(keyCode: UInt16(kVK_ANSI_T), flags: [.command], characters: "t") == "T")
        precondition(ShortcutKey.label(keyCode: UInt16(kVK_Space), flags: [], characters: " ") == nil)
        precondition(ShortcutKey.label(keyCode: UInt16(kVK_Space), flags: [.control], characters: " ") == "Space")
        precondition(ShortcutKey.label(keyCode: UInt16(kVK_ANSI_A), flags: [.command], characters: nil) == nil)
        print("49 shortcut checks passed: F1–F20, Fn normalization, modifiers, ordinary-key safeguards.")
    }
}
