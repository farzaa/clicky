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

enum CompanionComputerController {
    private static let mediaKeySystemDefinedSubtype: Int16 = 8
    private static let mediaKeyDownStateRawValue = 0xA
    private static let mediaKeyUpStateRawValue = 0xB

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
