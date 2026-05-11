//
//  CompanionKeyboardLayoutMap.swift
//  leanring-buddy
//
//  Reverse keyboard-layout lookup: "what (virtualKey, modifierFlags) produce
//  this character on the user's current keyboard layout?" — used by
//  `CompanionComputerController.typeText` so we emit real CGEvents on
//  whatever layout the user actually has active (US QWERTY, Dvorak, AZERTY,
//  JIS, Colemak, etc.) instead of a single hardcoded mapping.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Caches a (character → keystroke) reverse map for the user's current
/// keyboard layout. Built lazily by enumerating every (virtualKey,
/// modifierState) pair, asking `UCKeyTranslate` what character it produces,
/// and keying by that character. Rebuilds when the active input source
/// changes (cmd+space, manually picking a different layout, etc.).
final class CompanionKeyboardLayoutMap {
    static let shared = CompanionKeyboardLayoutMap()

    /// A single (virtualKey, modifierFlags) pair that produces some character
    /// on the active layout.
    private struct Entry {
        let virtualKey: CGKeyCode
        let modifierFlags: CGEventFlags
    }

    /// Serializes cache access. The map is read from the typing path
    /// (background Task) and could be invalidated from the same place;
    /// a serial queue keeps it consistent without needing @MainActor.
    private let serialQueue = DispatchQueue(
        label: "net.vibe-research.dot.companion-keyboard-layout-map"
    )
    private var cachedCharacterToKeystroke: [Character: Entry] = [:]
    private var cachedInputSourceID: String?

    private init() {}

    /// Human-readable identifier of the layout currently powering the map.
    /// Logged so we can correlate typing issues with specific layouts.
    var currentInputSourceIdentifier: String {
        return serialQueue.sync { cachedInputSourceID ?? "unknown" }
    }

    /// Returns the (virtualKey, modifierFlags) pair that produces `character`
    /// on the user's current keyboard layout, or `nil` if no single keypress
    /// produces it (emoji, IME-only characters, dead-key composed characters,
    /// many CJK code points, etc.). Caller should fall back to the Unicode
    /// payload path in those cases.
    func keystroke(producing character: Character) -> (virtualKey: CGKeyCode, modifierFlags: CGEventFlags)? {
        return serialQueue.sync {
            self.rebuildMapIfInputSourceChanged()
            guard let entry = cachedCharacterToKeystroke[character] else { return nil }
            return (entry.virtualKey, entry.modifierFlags)
        }
    }

    /// Checks whether the active keyboard layout's input-source identifier
    /// matches what we last cached. Rebuilds the map if it changed or if
    /// we've never built one before. MUST be called from `serialQueue`.
    private func rebuildMapIfInputSourceChanged() {
        guard let inputSourceUnmanaged = TISCopyCurrentKeyboardLayoutInputSource() else {
            cachedCharacterToKeystroke = [:]
            cachedInputSourceID = nil
            return
        }
        let inputSource = inputSourceUnmanaged.takeRetainedValue()

        guard let inputSourceIDPointer = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID) else {
            return
        }
        let inputSourceID = Unmanaged<CFString>
            .fromOpaque(inputSourceIDPointer)
            .takeUnretainedValue() as String

        if inputSourceID == cachedInputSourceID && !cachedCharacterToKeystroke.isEmpty {
            return
        }

        cachedInputSourceID = inputSourceID
        cachedCharacterToKeystroke = Self.buildCharacterToKeystrokeMap(forInputSource: inputSource)

        DotDebugLogger.log("keyboard.layout", "rebuilt character->keystroke map", metadata: [
            "inputSourceID": inputSourceID,
            "mappedCharacterCount": cachedCharacterToKeystroke.count
        ])
    }

    /// Enumerates every (virtualKey, modifierState) pair on the active
    /// layout, asks `UCKeyTranslate` what character it produces, and
    /// records the first keystroke for each producible character (so
    /// simpler modifier combinations win ties).
    private static func buildCharacterToKeystrokeMap(forInputSource inputSource: TISInputSource) -> [Character: Entry] {
        guard let layoutDataPointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            // Most IMEs (Japanese, Chinese, Korean) don't expose a Unicode
            // key layout — the typing path falls back to Unicode payloads
            // in that case, which the IME may or may not respect. That's
            // an inherent limitation; nothing we can do at this layer.
            return [:]
        }
        let layoutData = Unmanaged<CFData>
            .fromOpaque(layoutDataPointer)
            .takeUnretainedValue()
        guard let layoutBytes = CFDataGetBytePtr(layoutData) else { return [:] }
        let keyboardLayoutPointer = UnsafeRawPointer(layoutBytes)
            .assumingMemoryBound(to: UCKeyboardLayout.self)

        // Modifier states in increasing complexity so simpler combinations
        // win on ties (e.g. `1` should map to vk 18 + no modifier, not
        // vk 18 + shift + option even if that also produces `1` somehow).
        // The 8-bit modifier-state encoding is documented in HIToolbox:
        // bit 1 = shift, bit 3 = option. Caps lock / control / command
        // don't change which printable character a key produces on
        // standard layouts.
        let modifierStateAndEventFlagsPairs: [(modifierKeyState: UInt32, eventFlags: CGEventFlags)] = [
            (0b0000_0000, []),
            (0b0000_0010, .maskShift),
            (0b0000_1000, .maskAlternate),
            (0b0000_1010, [.maskShift, .maskAlternate])
        ]
        let keyboardType = UInt32(LMGetKbdType())

        var resultMap: [Character: Entry] = [:]
        for virtualKey in 0..<128 {
            for (modifierKeyState, eventFlags) in modifierStateAndEventFlagsPairs {
                var deadKeyState: UInt32 = 0
                var actualStringLength = 0
                var unicodeCharsBuffer = [UniChar](repeating: 0, count: 4)
                let translateStatus = UCKeyTranslate(
                    keyboardLayoutPointer,
                    UInt16(virtualKey),
                    UInt16(kUCKeyActionDown),
                    modifierKeyState,
                    keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    unicodeCharsBuffer.count,
                    &actualStringLength,
                    &unicodeCharsBuffer
                )
                guard translateStatus == noErr, actualStringLength > 0 else { continue }
                let producedString = String(
                    utf16CodeUnits: unicodeCharsBuffer,
                    count: actualStringLength
                )
                // Only accept single-character outputs. Multi-character
                // outputs (rare — e.g. some Vietnamese keys producing a
                // base+combining pair) can't be reproduced by a single
                // CGEvent keypress anyway.
                guard producedString.count == 1, let producedCharacter = producedString.first else { continue }
                if resultMap[producedCharacter] == nil {
                    resultMap[producedCharacter] = Entry(
                        virtualKey: CGKeyCode(virtualKey),
                        modifierFlags: eventFlags
                    )
                }
            }
        }

        // UCKeyTranslate emits "\r" (carriage return) for the Return key on
        // every layout — it never emits "\n". Most callers want "\n" in
        // their text strings to insert a newline, so alias it to the same
        // keystroke. The Return key is virtualKey 36 on every Mac keyboard
        // regardless of layout.
        if let returnKeyEntry = resultMap["\r"], resultMap["\n"] == nil {
            resultMap["\n"] = returnKeyEntry
        }

        return resultMap
    }
}
