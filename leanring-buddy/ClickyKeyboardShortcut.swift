//
//  ClickyKeyboardShortcut.swift
//  leanring-buddy
//
//  Persisted keyboard shortcut model for Clicky's typed command popup.
//

import AppKit
import Foundation

struct ClickyKeyboardShortcut: Codable, Equatable {
    static let textInputUserDefaultsKey = "textInputKeyboardShortcut"
    static let defaultTextInputShortcut = ClickyKeyboardShortcut(
        keyCode: 49,
        modifierFlags: [.option, .command],
        keyDisplayText: "Space"
    )
    private static let supportedModifierFlags: NSEvent.ModifierFlags = [
        .control,
        .option,
        .shift,
        .command,
        .function
    ]

    let keyCode: UInt16
    let modifierFlagsRawValue: UInt
    let keyDisplayText: String

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
            .intersection(.deviceIndependentFlagsMask)
            .intersection(Self.supportedModifierFlags)
    }

    var displayText: String {
        let modifierDisplayText = Self.displayText(for: modifierFlags)
        guard !modifierDisplayText.isEmpty else { return keyDisplayText }
        return modifierDisplayText + keyDisplayText
    }

    var validationErrorMessage: String? {
        if keyDisplayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Choose a key with at least one modifier."
        }

        if modifierFlags.isEmpty {
            return "Add at least one modifier."
        }

        if modifierFlags.contains(.control) && modifierFlags.contains(.option) {
            return "Control+Option is reserved for voice."
        }

        return nil
    }

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, keyDisplayText: String) {
        self.keyCode = keyCode
        self.modifierFlagsRawValue = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(Self.supportedModifierFlags)
            .rawValue
        self.keyDisplayText = keyDisplayText
    }

    static func persistedTextInputShortcut() -> ClickyKeyboardShortcut {
        guard let data = UserDefaults.standard.data(forKey: textInputUserDefaultsKey),
              let shortcut = try? JSONDecoder().decode(ClickyKeyboardShortcut.self, from: data),
              shortcut.validationErrorMessage == nil else {
            return defaultTextInputShortcut
        }

        return shortcut
    }

    func persistAsTextInputShortcut() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.textInputUserDefaultsKey)
    }

    func matches(keyCode eventKeyCode: UInt16, modifierFlags eventModifierFlags: NSEvent.ModifierFlags) -> Bool {
        eventKeyCode == keyCode
            && eventModifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .isSuperset(of: modifierFlags)
    }

    static func shortcut(from event: NSEvent) -> ClickyKeyboardShortcut? {
        guard event.type == .keyDown else { return nil }

        let keyDisplayText = keyDisplayText(for: event)
        guard !keyDisplayText.isEmpty else { return nil }

        return ClickyKeyboardShortcut(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            keyDisplayText: keyDisplayText
        )
    }

    static func shortcut(
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64
    ) -> ClickyKeyboardShortcut? {
        guard let keyDisplayText = keyDisplayText(forKeyCode: keyCode),
              !keyDisplayText.isEmpty else {
            return nil
        }

        return ClickyKeyboardShortcut(
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
                .intersection(.deviceIndependentFlagsMask),
            keyDisplayText: keyDisplayText
        )
    }

    private static func displayText(for modifierFlags: NSEvent.ModifierFlags) -> String {
        var displayText = ""

        if modifierFlags.contains(.control) {
            displayText += "⌃"
        }
        if modifierFlags.contains(.option) {
            displayText += "⌥"
        }
        if modifierFlags.contains(.shift) {
            displayText += "⇧"
        }
        if modifierFlags.contains(.command) {
            displayText += "⌘"
        }
        if modifierFlags.contains(.function) {
            displayText += "fn "
        }

        return displayText
    }

    private static func keyDisplayText(for event: NSEvent) -> String {
        if let specialKey = keyDisplayText(forKeyCode: event.keyCode), !specialKey.isEmpty {
            return specialKey
        }

        if let charactersIgnoringModifiers = event.charactersIgnoringModifiers,
           let firstCharacter = charactersIgnoringModifiers.first {
            return String(firstCharacter).uppercased()
        }

        return ""
    }

    private static func keyDisplayText(forKeyCode keyCode: UInt16) -> String? {
        switch keyCode {
        case 36:
            return "Return"
        case 48:
            return "Tab"
        case 49:
            return "Space"
        case 51:
            return "Delete"
        case 53:
            return "Esc"
        case 76:
            return "Enter"
        case 123:
            return "←"
        case 124:
            return "→"
        case 125:
            return "↓"
        case 126:
            return "↑"
        default:
            return nil
        }
    }
}
