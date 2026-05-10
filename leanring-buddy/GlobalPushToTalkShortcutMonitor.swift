//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?

    /// Whether the listen-only CGEvent tap is currently alive. We use this as
    /// the source of truth for "do we have Input Monitoring permission?",
    /// because `CGPreflightListenEventAccess()` is known to return a stale
    /// `false` even after the user grants permission in System Settings — but
    /// `CGEvent.tapCreate` itself only succeeds when permission is real.
    var isEventTapActive: Bool { globalEventTap != nil }
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            DotDebugLogger.log("shortcut.tap", "failed to create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            DotDebugLogger.log("shortcut.tap", "failed to create run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
        DotDebugLogger.log("shortcut.tap", "started")
    }

    func stop() {
        let hadGlobalEventTap = globalEventTap != nil
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }

        if hadGlobalEventTap {
            DotDebugLogger.log("shortcut.tap", "stopped")
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            DotDebugLogger.log("shortcut.tap", "tap disabled; re-enabling", metadata: [
                "eventType": eventType.rawValue
            ])
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        logRawShortcutEventIfRelevant(
            eventType: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            shortcutTransition: shortcutTransition
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }

    private func logRawShortcutEventIfRelevant(
        eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        shortcutTransition: BuddyPushToTalkShortcut.ShortcutTransition
    ) {
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        let includesRelevantModifier = modifierFlags.contains(.control)
            || modifierFlags.contains(.option)
            || modifierFlags.contains(.shift)
            || modifierFlags.contains(.function)
        let shouldLog = shortcutTransition != .none
            || isShortcutCurrentlyPressed
            || (eventType == .flagsChanged && includesRelevantModifier)

        guard shouldLog else { return }

        DotDebugLogger.log("shortcut.raw", "event", metadata: [
            "eventType": Self.logDescription(for: eventType),
            "keyCode": keyCode,
            "flagsRaw": modifierFlagsRawValue,
            "control": modifierFlags.contains(.control),
            "option": modifierFlags.contains(.option),
            "shift": modifierFlags.contains(.shift),
            "command": modifierFlags.contains(.command),
            "function": modifierFlags.contains(.function),
            "wasPressed": isShortcutCurrentlyPressed,
            "transition": String(describing: shortcutTransition)
        ])
    }

    private static func logDescription(for eventType: CGEventType) -> String {
        switch eventType {
        case .flagsChanged:
            return "flagsChanged"
        case .keyDown:
            return "keyDown"
        case .keyUp:
            return "keyUp"
        case .tapDisabledByTimeout:
            return "tapDisabledByTimeout"
        case .tapDisabledByUserInput:
            return "tapDisabledByUserInput"
        default:
            return "type\(eventType.rawValue)"
        }
    }
}
