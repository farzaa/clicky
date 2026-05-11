//
//  CompanionComputerController.swift
//  leanring-buddy
//
//  Posts local mouse and keyboard events for explicit computer-control actions.
//

import AppKit
import ApplicationServices

enum CompanionMediaControlCommand: String {
    case playPause = "play_pause"
    case nextTrack = "next"
    case previousTrack = "previous"

    init?(controlTagValue: String) {
        let normalizedControlTagValue = controlTagValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")

        switch normalizedControlTagValue {
        case "play_pause", "playpause", "toggle", "toggle_playback", "pause", "play", "resume", "stop":
            self = .playPause
        case "next", "next_track", "skip", "skip_forward":
            self = .nextTrack
        case "previous", "previous_track", "prev", "back", "last", "skip_back":
            self = .previousTrack
        default:
            return nil
        }
    }

    var spokenConfirmation: String {
        switch self {
        case .playPause:
            return "done."
        case .nextTrack:
            return "skipping."
        case .previousTrack:
            return "going back."
        }
    }

    var logDescription: String {
        switch self {
        case .playPause:
            return "play/pause"
        case .nextTrack:
            return "next track"
        case .previousTrack:
            return "previous track"
        }
    }

    fileprivate var mediaKeyRawValue: Int {
        switch self {
        case .playPause:
            return 16
        case .nextTrack:
            return 17
        case .previousTrack:
            return 18
        }
    }
}

/// A keystroke described as a virtual key + modifier flags.
/// Used by the [KEY:...] action tag so Claude can press special keys
/// (Backspace, Return, Escape, arrow keys) and modifier shortcuts
/// (Cmd+A, Cmd+Shift+Z) instead of being limited to typing literal
/// characters via the [TYPE:...] tag.
struct CompanionKeystroke {
    let virtualKey: CGKeyCode
    let modifierFlags: CGEventFlags
    /// Canonical form like "cmd+a" or "backspace" for logging.
    let humanReadableDescription: String
}

enum CompanionComputerController {
    private static let mediaKeySystemDefinedSubtype: Int16 = 8
    private static let mediaKeyDownStateRawValue = 0xA
    private static let mediaKeyUpStateRawValue = 0xB

    /// Mapping from key names the model is allowed to use to macOS virtual
    /// key codes (kVK_* constants from <HIToolbox/Events.h>). Keep this list
    /// curated: every name here is part of the public surface the model is
    /// taught about in the system prompt. Do not add aliases that aren't
    /// documented in the prompt — Claude will only use what it's told about.
    private static let virtualKeyCodeByLowercaseKeyName: [String: CGKeyCode] = [
        // Letters
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35,
        "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
        "y": 16, "z": 6,
        // Digits
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
        "6": 22, "7": 26, "8": 28, "9": 25,
        // Whitespace and editing keys. macOS calls Backspace "Delete" and
        // Forward-Delete "Forward Delete"; we accept both spellings of each
        // because Claude tends to think of the big key as "backspace".
        "return": 36, "enter": 36,
        "tab": 48,
        "space": 49, "spacebar": 49,
        "backspace": 51, "delete": 51,
        "forwarddelete": 117, "fwddelete": 117, "delete-forward": 117,
        "escape": 53, "esc": 53,
        // Arrow keys
        "up": 126, "uparrow": 126,
        "down": 125, "downarrow": 125,
        "left": 123, "leftarrow": 123,
        "right": 124, "rightarrow": 124,
        // Navigation
        "home": 115,
        "end": 119,
        "pageup": 116, "pgup": 116,
        "pagedown": 121, "pgdown": 121, "pgdn": 121,
        // Function keys
        "f1": 122, "f2": 120, "f3": 99, "f4": 118,
        "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]

    private static let modifierFlagByLowercaseModifierName: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "meta": .maskCommand, "win": .maskCommand,
        "ctrl": .maskControl, "control": .maskControl,
        "shift": .maskShift,
        "alt": .maskAlternate, "opt": .maskAlternate, "option": .maskAlternate
    ]

    /// Parses a key spec like "cmd+a", "backspace", or "cmd+shift+z" into
    /// a CompanionKeystroke. Returns nil if the spec is empty, unknown, or
    /// names more than one non-modifier key.
    ///
    /// Accepts "+", "-", and whitespace as separators because Claude's output
    /// varies. Names are case-insensitive.
    static func parseKeystroke(fromKeySpec rawKeySpec: String) -> CompanionKeystroke? {
        let normalizedKeySpec = rawKeySpec
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedKeySpec.isEmpty else { return nil }

        let separatorCharacterSet = CharacterSet(charactersIn: "+- \t")
        let tokens = normalizedKeySpec
            .components(separatedBy: separatorCharacterSet)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        var combinedModifierFlags: CGEventFlags = []
        var resolvedVirtualKey: CGKeyCode?
        var resolvedKeyName: String?

        for token in tokens {
            if let modifierFlag = modifierFlagByLowercaseModifierName[token] {
                combinedModifierFlags.insert(modifierFlag)
                continue
            }

            if let virtualKey = virtualKeyCodeByLowercaseKeyName[token] {
                // Reject specs that name more than one non-modifier key.
                // E.g. "a+b" is ambiguous and almost certainly a model mistake.
                guard resolvedVirtualKey == nil else { return nil }
                resolvedVirtualKey = virtualKey
                resolvedKeyName = token
                continue
            }

            return nil
        }

        guard let virtualKey = resolvedVirtualKey, let keyName = resolvedKeyName else {
            return nil
        }

        let humanReadableDescription = canonicalKeystrokeDescription(
            modifierFlags: combinedModifierFlags,
            keyName: keyName
        )

        return CompanionKeystroke(
            virtualKey: virtualKey,
            modifierFlags: combinedModifierFlags,
            humanReadableDescription: humanReadableDescription
        )
    }

    private static func canonicalKeystrokeDescription(
        modifierFlags: CGEventFlags,
        keyName: String
    ) -> String {
        var modifierTokens: [String] = []
        if modifierFlags.contains(.maskControl) { modifierTokens.append("ctrl") }
        if modifierFlags.contains(.maskAlternate) { modifierTokens.append("opt") }
        if modifierFlags.contains(.maskShift) { modifierTokens.append("shift") }
        if modifierFlags.contains(.maskCommand) { modifierTokens.append("cmd") }
        return (modifierTokens + [keyName]).joined(separator: "+")
    }

    /// Posts a real keyboard event with virtualKey set, so receiving apps see
    /// it as a genuine keypress (unlike typeText which uses Unicode payloads
    /// that can't represent special keys or modifier shortcuts).
    static func pressKeystroke(_ keystroke: CompanionKeystroke) {
        DotDebugLogger.log("computer.controller", "key requested", metadata: [
            "keystroke": keystroke.humanReadableDescription,
            "virtualKey": Int(keystroke.virtualKey),
            "modifierFlagsRaw": keystroke.modifierFlags.rawValue
        ])
        let eventSource = CGEventSource(stateID: .combinedSessionState)

        let keyDownEvent = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: keystroke.virtualKey,
            keyDown: true
        )
        keyDownEvent?.flags = keystroke.modifierFlags
        keyDownEvent?.post(tap: .cghidEventTap)

        let keyUpEvent = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: keystroke.virtualKey,
            keyDown: false
        )
        keyUpEvent?.flags = keystroke.modifierFlags
        keyUpEvent?.post(tap: .cghidEventTap)

        DotDebugLogger.log("computer.controller", "key posted", metadata: [
            "keystroke": keystroke.humanReadableDescription
        ])
    }

    /// Direction the user wants to slide through macOS Spaces, in
    /// viewport-content terms. "next" moves to the desktop on the right.
    enum SpaceSwitchDirection: String {
        case next
        case previous
    }

    /// Switches to the macOS Space adjacent to the current one using the
    /// private CGS API via `MacSpaceController`. Returns a description of
    /// what happened so the agent loop can surface it in its tool_result.
    ///
    /// Why not just post ctrl+→ via CGEvent: macOS Sequoia+ silently
    /// filters CGEvents targeting the Mission Control / Spaces system
    /// shortcuts, even from processes with full Accessibility permission.
    /// The OS reports the event posted successfully but nothing happens.
    /// `CGSManagedDisplaySetCurrentSpace` is the same primitive used by
    /// Yabai, Spectacle, Magnet — it bypasses the synthetic-event filter
    /// because it talks to WindowServer directly rather than synthesising
    /// a keystroke.
    @discardableResult
    static func switchSpace(direction: SpaceSwitchDirection) -> MacSpaceController.SwitchResult {
        DotDebugLogger.log("computer.controller", "switch space requested", metadata: [
            "direction": direction.rawValue,
            "via": "CGSManagedDisplaySetCurrentSpace"
        ])
        let macDirection: MacSpaceSwitchDirection
        switch direction {
        case .next:     macDirection = .next
        case .previous: macDirection = .previous
        }
        let result = MacSpaceController.switchToAdjacentSpace(direction: macDirection)
        DotDebugLogger.log("computer.controller", "switch space completed", metadata: [
            "direction": direction.rawValue,
            "didSwitch": result.didSwitch,
            "resultDescription": result.resultDescription,
            "previousSpaceID": result.previousSpaceID ?? 0,
            "newSpaceID": result.newSpaceID ?? 0
        ])
        return result
    }

    /// Brings up macOS Mission Control so every Space + window thumbnail is
    /// on screen. Useful when Claude needs the user to pick a Space, or
    /// when the next agent step wants to click a specific thumbnail. Posts
    /// the default ctrl+↑ shortcut.
    static func showMissionControl() {
        DotDebugLogger.log("computer.controller", "mission control requested")
        guard let keystroke = parseKeystroke(fromKeySpec: "ctrl+up") else {
            DotDebugLogger.log("computer.controller", "mission control skipped — keystroke parse failed")
            return
        }
        pressKeystroke(keystroke)
    }

    static func click(atAppKitScreenLocation appKitScreenLocation: CGPoint) {
        let eventLocation = quartzEventLocation(forAppKitScreenLocation: appKitScreenLocation)
        DotDebugLogger.log("computer.controller", "click requested", metadata: [
            "appKitX": Int(appKitScreenLocation.x),
            "appKitY": Int(appKitScreenLocation.y),
            "quartzX": Int(eventLocation.x),
            "quartzY": Int(eventLocation.y),
            "accessibilityTrusted": AXIsProcessTrusted()
        ])

        if AXIsProcessTrusted(),
           performAccessibilityPress(atQuartzEventLocation: eventLocation) {
            print("🖱️ Computer control: performed AXPress without moving the hardware cursor.")
            DotDebugLogger.log("computer.controller", "click completed with AXPress", metadata: [
                "quartzX": Int(eventLocation.x),
                "quartzY": Int(eventLocation.y)
            ])
            return
        }

        postCoordinateClickPreservingHardwareCursor(atQuartzEventLocation: eventLocation)
        print("🖱️ Computer control: posted coordinate click without leaving the hardware cursor at the target.")
        DotDebugLogger.log("computer.controller", "click completed with coordinate events", metadata: [
            "quartzX": Int(eventLocation.x),
            "quartzY": Int(eventLocation.y)
        ])
    }

    private static func performAccessibilityPress(atQuartzEventLocation eventLocation: CGPoint) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var targetElement: AXUIElement?
        let copyResult = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(eventLocation.x),
            Float(eventLocation.y),
            &targetElement
        )

        guard copyResult == .success, let targetElement else {
            return false
        }

        return performPressOnElementOrAncestor(targetElement)
    }

    private static func performPressOnElementOrAncestor(_ targetElement: AXUIElement) -> Bool {
        // Don't try AXPress when the click landed on a text-input element.
        // Text fields/areas/search fields/combo boxes don't support kAXPress,
        // so the ancestor walker below would press a button-like wrapper
        // (a toolbar item, a container) instead of focusing the field —
        // leaving the user's next type_text call to hit the wrong place
        // and play the macOS funk sound. Coordinate clicks reliably focus
        // text inputs, so let the caller fall through to that path.
        if elementHasTextInputRole(targetElement) {
            return false
        }

        var currentElement: AXUIElement? = targetElement

        for _ in 0..<5 {
            guard let element = currentElement else { return false }

            if elementSupportsPressAction(element),
               AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                return true
            }

            var parentElementValue: CFTypeRef?
            let parentResult = AXUIElementCopyAttributeValue(
                element,
                kAXParentAttribute as CFString,
                &parentElementValue
            )

            guard parentResult == .success,
                  let parentElement = parentElementValue else {
                return false
            }

            currentElement = (parentElement as! AXUIElement)
        }

        return false
    }

    private static func elementSupportsPressAction(_ element: AXUIElement) -> Bool {
        var actionNamesValue: CFArray?
        let copyResult = AXUIElementCopyActionNames(element, &actionNamesValue)
        guard copyResult == .success,
              let actionNames = actionNamesValue as? [String] else {
            return false
        }

        return actionNames.contains(kAXPressAction as String)
    }

    private static func elementHasTextInputRole(_ element: AXUIElement) -> Bool {
        var roleAttributeValue: CFTypeRef?
        let copyRoleResult = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleAttributeValue
        )
        guard copyRoleResult == .success,
              let roleString = roleAttributeValue as? String else {
            return false
        }

        let textInputAccessibilityRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            // macOS doesn't expose AXSearchField as a public constant,
            // so use the literal that VoiceOver and accessibility tools
            // observe for NSSearchField and similar controls.
            "AXSearchField"
        ]
        if textInputAccessibilityRoles.contains(roleString) {
            return true
        }

        // Some AXTextField wrappers (notably NSSearchField) report
        // role = AXTextField with subrole = AXSearchField — both already
        // covered above — but other controls expose themselves only via
        // subrole. Check the subrole as well so we don't miss them.
        var subroleAttributeValue: CFTypeRef?
        let copySubroleResult = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleAttributeValue
        )
        guard copySubroleResult == .success,
              let subroleString = subroleAttributeValue as? String else {
            return false
        }

        let textInputAccessibilitySubroles: Set<String> = [
            "AXSearchField",
            "AXSecureTextField"
        ]
        return textInputAccessibilitySubroles.contains(subroleString)
    }

    private static func postCoordinateClickPreservingHardwareCursor(atQuartzEventLocation eventLocation: CGPoint) {
        let originalMouseLocation = quartzEventLocation(forAppKitScreenLocation: NSEvent.mouseLocation)
        let eventSource = CGEventSource(stateID: .combinedSessionState)

        let mouseDownEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: eventLocation,
            mouseButton: .left
        )
        let mouseUpEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: eventLocation,
            mouseButton: .left
        )

        mouseDownEvent?.post(tap: .cghidEventTap)
        mouseUpEvent?.post(tap: .cghidEventTap)
        CGWarpMouseCursorPosition(originalMouseLocation)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    }

    /// Posts a CGEvent scroll wheel event at the current hardware cursor
    /// location. Signs are chosen so the apparent on-screen direction matches
    /// the user's mental model: `direction: .down` reveals content below the
    /// fold, `direction: .right` pans right, etc. macOS "natural scrolling"
    /// settings handle the inversion transparently — we always pass the
    /// "classic" sign and let the system apply the user's preference.
    static func scrollWheel(direction: AgentScrollDirection, magnitude: Int32) {
        let lineCount: Int32 = max(1, magnitude)
        // CGEventCreateScrollWheelEvent2 (pixel/line units): positive wheel1
        // scrolls content DOWN (page reveals what was above); negative scrolls
        // up. Same idea for wheel2 / horizontal axis: positive scrolls right.
        // Wait — actually historical convention: positive wheel1 = wheel turns
        // toward user = page scrolls UP. Apple reversed our intuition once.
        // Empirically, posting wheel1 = -N moves a webpage down by N lines on
        // a machine with default settings, so:
        let verticalDelta: Int32
        let horizontalDelta: Int32
        switch direction {
        case .up:
            verticalDelta = lineCount      // wheel up → content goes up → reveal above
            horizontalDelta = 0
        case .down:
            verticalDelta = -lineCount     // wheel down → content goes down → reveal below
            horizontalDelta = 0
        case .left:
            verticalDelta = 0
            horizontalDelta = lineCount    // pan left → reveal what was to the left
        case .right:
            verticalDelta = 0
            horizontalDelta = -lineCount   // pan right → reveal what was to the right
        }

        let eventSource = CGEventSource(stateID: .combinedSessionState)
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .line,
            wheelCount: 2,
            wheel1: verticalDelta,
            wheel2: horizontalDelta,
            wheel3: 0
        ) else {
            DotDebugLogger.log("computer.controller", "scroll skipped — could not construct event", metadata: [
                "direction": direction.rawValue,
                "magnitude": Int(lineCount)
            ])
            return
        }
        scrollEvent.post(tap: .cghidEventTap)
        DotDebugLogger.log("computer.controller", "scroll posted", metadata: [
            "direction": direction.rawValue,
            "verticalDelta": Int(verticalDelta),
            "horizontalDelta": Int(horizontalDelta),
            "magnitude": Int(lineCount)
        ])
    }

    static func pressMediaControl(_ mediaControlCommand: CompanionMediaControlCommand) {
        DotDebugLogger.log("computer.controller", "media key requested", metadata: [
            "command": mediaControlCommand.rawValue
        ])
        postMediaKey(
            mediaKeyRawValue: mediaControlCommand.mediaKeyRawValue,
            keyStateRawValue: mediaKeyDownStateRawValue
        )
        postMediaKey(
            mediaKeyRawValue: mediaControlCommand.mediaKeyRawValue,
            keyStateRawValue: mediaKeyUpStateRawValue
        )
        print("🎛️ Computer control: pressed \(mediaControlCommand.logDescription) media key.")
        DotDebugLogger.log("computer.controller", "media key posted", metadata: [
            "command": mediaControlCommand.rawValue,
            "mediaKeyRawValue": mediaControlCommand.mediaKeyRawValue
        ])
    }

    private static func postMediaKey(mediaKeyRawValue: Int, keyStateRawValue: Int) {
        let mediaKeyEventData = (mediaKeyRawValue << 16) | (keyStateRawValue << 8)
        let mediaKeyModifierFlags = NSEvent.ModifierFlags(rawValue: UInt(keyStateRawValue << 8))

        // The system-defined media-key payload mirrors Apple keyboard events.
        // Swift does not consistently expose the ev_keymap.h constants, so the
        // raw values are kept in one place instead of scattered through callers.
        let mediaKeyEvent = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: mediaKeyModifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: mediaKeySystemDefinedSubtype,
            data1: mediaKeyEventData,
            data2: -1
        )

        mediaKeyEvent?.cgEvent?.post(tap: .cghidEventTap)
    }

    static func typeText(_ text: String) {
        DotDebugLogger.log("computer.controller", "typing requested", metadata: [
            "characterCount": text.count
        ])
        let eventSource = CGEventSource(stateID: .combinedSessionState)

        for character in text {
            postUnicodeKeyboardEvent(
                String(character),
                keyDown: true,
                eventSource: eventSource
            )
            postUnicodeKeyboardEvent(
                String(character),
                keyDown: false,
                eventSource: eventSource
            )
        }
        DotDebugLogger.log("computer.controller", "typing completed", metadata: [
            "characterCount": text.count
        ])
    }

    private static func postUnicodeKeyboardEvent(
        _ text: String,
        keyDown: Bool,
        eventSource: CGEventSource?
    ) {
        var utf16Characters: [UniChar] = Array(text.utf16)
        guard !utf16Characters.isEmpty else { return }

        let keyboardEvent = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: 0,
            keyDown: keyDown
        )
        keyboardEvent?.keyboardSetUnicodeString(
            stringLength: utf16Characters.count,
            unicodeString: &utf16Characters
        )
        keyboardEvent?.post(tap: .cghidEventTap)
    }

    /// Result of a request to launch or activate a native macOS application.
    /// `didOpen` is true when NSWorkspace successfully resolved + activated
    /// (or launched) the app. `resolvedApplicationName` is the name macOS
    /// reported back; useful for spoken confirmations and logs.
    struct OpenApplicationResult {
        let didOpen: Bool
        let resolvedApplicationName: String
        let errorDescription: String?
    }

    /// Opens a URL via NSWorkspace, which routes it to the user's default
    /// browser (or any app registered for that scheme) and handles activation,
    /// new-tab creation, and focus. Reliable regardless of which app is
    /// currently frontmost — replaces the cmd+L → type → return sequence,
    /// which silently failed when focus wasn't on a browser and triggered
    /// the macOS "funk" beep.
    @discardableResult
    static func openURL(rawURLString: String) -> Bool {
        let normalizedURLString = normalizeURLString(rawURLString)
        DotDebugLogger.log("computer.controller", "open url requested", metadata: [
            "rawURLString": rawURLString,
            "normalizedURLString": normalizedURLString
        ])
        guard let resolvedURL = URL(string: normalizedURLString) else {
            DotDebugLogger.log("computer.controller", "open url failed — could not construct URL", metadata: [
                "rawURLString": rawURLString,
                "normalizedURLString": normalizedURLString
            ])
            return false
        }
        let didOpenURL = NSWorkspace.shared.open(resolvedURL)
        DotDebugLogger.log("computer.controller", "open url completed", metadata: [
            "rawURLString": rawURLString,
            "normalizedURLString": normalizedURLString,
            "didOpen": didOpenURL
        ])
        return didOpenURL
    }

    /// Bare hosts like "google.com" or "drive.google.com" need a scheme
    /// prepended before NSWorkspace.shared.open will route them to a
    /// browser. Anything that already has a recognised scheme is left alone.
    private static func normalizeURLString(_ rawURLString: String) -> String {
        let trimmedURLString = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercaseURLString = trimmedURLString.lowercased()
        let knownURLSchemePrefixes = [
            "http://",
            "https://",
            "file://",
            "mailto:",
            "tel:",
            "ftp://",
            "ftps://"
        ]
        if knownURLSchemePrefixes.contains(where: { lowercaseURLString.hasPrefix($0) }) {
            return trimmedURLString
        }
        return "https://\(trimmedURLString)"
    }

    /// Launches or activates a native macOS application by display name
    /// ("Spotify", "Visual Studio Code") or bundle identifier
    /// ("com.spotify.client"). Uses NSWorkspace's modern openApplication
    /// path so macOS handles activation, focus, and Spaces routing — far
    /// more reliable than clicking a Dock icon or driving Spotlight via
    /// keystrokes.
    static func openApplication(nameOrBundleIdentifier rawNameOrBundleIdentifier: String) async -> OpenApplicationResult {
        let trimmedNameOrBundleIdentifier = rawNameOrBundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNameOrBundleIdentifier.isEmpty else {
            return OpenApplicationResult(
                didOpen: false,
                resolvedApplicationName: rawNameOrBundleIdentifier,
                errorDescription: "empty application name"
            )
        }

        DotDebugLogger.log("computer.controller", "open application requested", metadata: [
            "rawNameOrBundleIdentifier": rawNameOrBundleIdentifier
        ])

        guard let resolvedApplicationURL = resolveApplicationURL(
            forNameOrBundleIdentifier: trimmedNameOrBundleIdentifier
        ) else {
            DotDebugLogger.log("computer.controller", "open application failed — could not resolve URL", metadata: [
                "rawNameOrBundleIdentifier": rawNameOrBundleIdentifier
            ])
            return OpenApplicationResult(
                didOpen: false,
                resolvedApplicationName: trimmedNameOrBundleIdentifier,
                errorDescription: "couldn't find an app named \"\(trimmedNameOrBundleIdentifier)\""
            )
        }

        let openApplicationConfiguration = NSWorkspace.OpenConfiguration()
        openApplicationConfiguration.activates = true

        return await withCheckedContinuation { openApplicationContinuation in
            NSWorkspace.shared.openApplication(
                at: resolvedApplicationURL,
                configuration: openApplicationConfiguration
            ) { runningApplication, openApplicationError in
                if let openApplicationError {
                    DotDebugLogger.log("computer.controller", "open application failed", metadata: [
                        "rawNameOrBundleIdentifier": rawNameOrBundleIdentifier,
                        "applicationURL": resolvedApplicationURL.path,
                        "error": openApplicationError.localizedDescription
                    ])
                    openApplicationContinuation.resume(returning: OpenApplicationResult(
                        didOpen: false,
                        resolvedApplicationName: trimmedNameOrBundleIdentifier,
                        errorDescription: openApplicationError.localizedDescription
                    ))
                    return
                }

                let resolvedApplicationDisplayName = runningApplication?.localizedName
                    ?? trimmedNameOrBundleIdentifier
                DotDebugLogger.log("computer.controller", "open application completed", metadata: [
                    "rawNameOrBundleIdentifier": rawNameOrBundleIdentifier,
                    "applicationURL": resolvedApplicationURL.path,
                    "resolvedDisplayName": resolvedApplicationDisplayName
                ])
                openApplicationContinuation.resume(returning: OpenApplicationResult(
                    didOpen: true,
                    resolvedApplicationName: resolvedApplicationDisplayName,
                    errorDescription: nil
                ))
            }
        }
    }

    /// Tries bundle-identifier lookup first (e.g. "com.spotify.client"), then
    /// falls back to NSWorkspace's name-based lookup. The name-based path is
    /// `fullPath(forApplication:)` — technically deprecated, but the cleanest
    /// API for resolving "Visual Studio Code" / "VS Code" / "Notion" etc.
    /// across the standard /Applications and ~/Applications directories.
    private static func resolveApplicationURL(forNameOrBundleIdentifier nameOrBundleIdentifier: String) -> URL? {
        if nameOrBundleIdentifier.contains("."),
           let bundleIDApplicationURL = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: nameOrBundleIdentifier
           ) {
            return bundleIDApplicationURL
        }

        if let displayNameApplicationPath = NSWorkspace.shared.fullPath(
            forApplication: nameOrBundleIdentifier
        ) {
            return URL(fileURLWithPath: displayNameApplicationPath)
        }

        return nil
    }

    private static func quartzEventLocation(forAppKitScreenLocation appKitScreenLocation: CGPoint) -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitScreenLocation) })
                ?? NSScreen.main else {
            return appKitScreenLocation
        }

        let displayBounds = CGDisplayBounds(screen.displayID)
        let localX = appKitScreenLocation.x - screen.frame.minX
        let localYFromTop = screen.frame.maxY - appKitScreenLocation.y

        return CGPoint(
            x: displayBounds.minX + localX,
            y: displayBounds.minY + localYFromTop
        )
    }
}
