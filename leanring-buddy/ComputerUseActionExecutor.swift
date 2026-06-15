//
//  ComputerUseActionExecutor.swift
//  leanring-buddy
//
//  Low-level macOS input synthesis for takeover mode — moves the cursor,
//  clicks, types, scrolls, and presses key combos via CoreGraphics Quartz
//  Event Services. Needs only the Accessibility grant the app already holds
//  (App Sandbox is off). Every synthesized event is stamped with a sentinel
//  so the kill-switch tap can tell the app's own events from the user's.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

@MainActor
final class ComputerUseActionExecutor {
    /// Stamped into every synthesized event (kCGEventSourceUserData), so the
    /// kill-switch tap ignores our own events. "CLKY".
    private static let eventSentinel: Int64 = 0x434C_4B59

    /// Synthesizing input needs the Accessibility TCC grant (distinct from the
    /// Screen Recording grant the app already uses for screenshots).
    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    // MARK: - Coordinate conversion

    /// Converts an AppKit global point (bottom-left origin, Y-up — what the
    /// rest of the app and the pointing pipeline use) to the Quartz global
    /// point CGEvent expects (top-left origin, Y-down). The flip is ALWAYS
    /// against the primary display height, even for points on a secondary
    /// monitor — this is the #1 takeover bug if you get it wrong.
    private func quartzPoint(fromAppKitGlobal appKitPoint: CGPoint) -> CGPoint {
        let primaryDisplayHeight = NSScreen.screens.first?.frame.height ?? appKitPoint.y
        return CGPoint(x: appKitPoint.x, y: primaryDisplayHeight - appKitPoint.y)
    }

    private func eventSource() -> CGEventSource? {
        CGEventSource(stateID: .combinedSessionState)
    }

    private func stamp(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventSentinel)
    }

    // MARK: - Cursor

    /// Teleports the visible cursor without posting a move event. Used in
    /// dry-run to show where clicky *would* act — harmless (no click, no app
    /// notification).
    func moveCursorVisible(toAppKitGlobal appKitPoint: CGPoint) {
        CGWarpMouseCursorPosition(quartzPoint(fromAppKitGlobal: appKitPoint))
    }

    // MARK: - Click

    func click(atAppKitGlobal appKitPoint: CGPoint) {
        let point = quartzPoint(fromAppKitGlobal: appKitPoint)
        // Warp first so hover state is consistent before the click lands.
        CGWarpMouseCursorPosition(point)
        guard let down = CGEvent(mouseEventSource: eventSource(), mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: eventSource(), mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return }
        stamp(down); stamp(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Type

    /// Types arbitrary text via Unicode injection (emoji/non-ASCII safe).
    /// Used only for literal text entry — shortcuts go through `pressKey` so
    /// they honor the keyboard layout.
    func typeText(_ text: String) {
        for character in text {
            let utf16Scalars = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: eventSource(), virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: eventSource(), virtualKey: 0, keyDown: false) else { continue }
            utf16Scalars.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: utf16Scalars.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: utf16Scalars.count, unicodeString: buffer.baseAddress)
            }
            stamp(down); stamp(up)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Key combo

    /// Presses a combo like "return", "esc", "cmd+s", "cmd+shift+t".
    /// Returns false if the combo's main key isn't recognized.
    @discardableResult
    func pressKey(combo: String) -> Bool {
        var flags: CGEventFlags = []
        var mainKeyCode: CGKeyCode?

        for rawToken in combo.lowercased().split(separator: "+") {
            let token = rawToken.trimmingCharacters(in: .whitespaces)
            switch token {
            case "cmd", "command": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            default: mainKeyCode = Self.virtualKeyCode(for: token)
            }
        }

        guard let keyCode = mainKeyCode,
              let down = CGEvent(keyboardEventSource: eventSource(), virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource(), virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.flags = flags; up.flags = flags
        stamp(down); stamp(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Scroll

    func scroll(atAppKitGlobal appKitPoint: CGPoint, direction: TakeoverScrollDirection, amount: Int) {
        CGWarpMouseCursorPosition(quartzPoint(fromAppKitGlobal: appKitPoint))
        // wheel1 = vertical (positive scrolls up), wheel2 = horizontal.
        let lineDelta = Int32(amount * 3)
        var wheel1: Int32 = 0
        var wheel2: Int32 = 0
        switch direction {
        case .up: wheel1 = lineDelta
        case .down: wheel1 = -lineDelta
        case .left: wheel2 = lineDelta
        case .right: wheel2 = -lineDelta
        }
        guard let event = CGEvent(scrollWheelEvent2Source: eventSource(), units: .line, wheelCount: 2,
                                  wheel1: wheel1, wheel2: wheel2, wheel3: 0) else { return }
        stamp(event)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Kill switch

    private var killSwitchTap: CFMachPort?
    private var killSwitchRunLoopSource: CFRunLoopSource?
    private var onKillSwitch: (() -> Void)?

    /// Starts a global listen-only tap that fires `onKill` when the user
    /// presses ESC. Ignores the app's own synthesized events via the
    /// sentinel, so driving the cursor never trips it. Returns false if the
    /// tap can't be created — the caller must refuse to run without a kill
    /// switch rather than drive input blind.
    @discardableResult
    func startKillSwitchMonitor(onKill: @escaping () -> Void) -> Bool {
        stopKillSwitchMonitor()
        self.onKillSwitch = onKill

        let eventMask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let executor = Unmanaged<ComputerUseActionExecutor>.fromOpaque(userInfo).takeUnretainedValue()
            executor.handleKillSwitchEvent(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Takeover: failed to create kill-switch tap")
            return false
        }
        self.killSwitchTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.killSwitchRunLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stopKillSwitchMonitor() {
        if let killSwitchTap { CGEvent.tapEnable(tap: killSwitchTap, enable: false) }
        if let killSwitchRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), killSwitchRunLoopSource, .commonModes)
        }
        killSwitchTap = nil
        killSwitchRunLoopSource = nil
        onKillSwitch = nil
    }

    private nonisolated func handleKillSwitchEvent(type: CGEventType, event: CGEvent) {
        // The tap can be disabled by the system; re-enable it so the kill
        // switch can't silently die mid-takeover.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let killSwitchTap = MainActor.assumeIsolated({ self.killSwitchTap }) {
                CGEvent.tapEnable(tap: killSwitchTap, enable: true)
            }
            return
        }
        // Ignore our own synthesized events.
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventSentinel { return }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown && keyCode == UInt16(kVK_Escape) {
            Task { @MainActor in self.onKillSwitch?() }
        }
    }

    // MARK: - Keycodes

    private static func virtualKeyCode(for token: String) -> CGKeyCode? {
        switch token {
        case "return", "enter": return CGKeyCode(kVK_Return)
        case "esc", "escape": return CGKeyCode(kVK_Escape)
        case "tab": return CGKeyCode(kVK_Tab)
        case "space": return CGKeyCode(kVK_Space)
        case "delete", "backspace": return CGKeyCode(kVK_Delete)
        default:
            if token.count == 1, let scalar = token.unicodeScalars.first {
                return ansiKeyCode(for: Character(scalar))
            }
            return nil
        }
    }

    /// ANSI virtual keycodes for a-z and 0-9 (kVK_ANSI_* values are not
    /// sequential, so they're mapped explicitly).
    private static func ansiKeyCode(for character: Character) -> CGKeyCode? {
        let map: [Character: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
            "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ]
        guard let code = map[character] else { return nil }
        return CGKeyCode(code)
    }
}
