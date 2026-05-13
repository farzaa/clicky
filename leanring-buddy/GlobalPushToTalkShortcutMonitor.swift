//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a CGEvent tap so modifier-only shortcuts like ctrl + option
//  behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    /// Fires once each time the user taps the text-command shortcut
    /// (`cmd + shift + space`). The handler treats it as a toggle: tap
    /// shows the floating text panel; tap again hides it. This sits on
    /// the same listen-only CGEvent tap as push-to-talk so we don't pay
    /// for two separate kernel taps.
    ///
    /// Chosen for left-hand ergonomics (cmd pinky, shift pinky, space
    /// thumb), mirroring Spotlight's `cmd + space` pattern. Disjoint
    /// modifier set from PTT (`ctrl + option`) so the two can't shadow
    /// each other. Not a default macOS shortcut.
    let textCommandToggleRequestPublisher = PassthroughSubject<Void, Never>()

    struct GlobalKeyDownEvent {
        let keyCode: UInt16
        let modifierFlagsRawValue: UInt64
    }

    struct GlobalScrollWheelEvent {
        let verticalDeltaInLines: Int64
        let verticalDeltaInPoints: Int64
        let horizontalDeltaInLines: Int64
        let horizontalDeltaInPoints: Int64
        let modifierFlagsRawValue: UInt64
    }

    /// Raw key-down stream from the same event tap used for push-to-talk.
    /// Consumers still decide whether a key matters.
    let globalKeyDownPublisher = PassthroughSubject<GlobalKeyDownEvent, Never>()

    /// Synchronous key-down handler for shortcuts that must prevent the
    /// frontmost app from also seeing the keypress. Return true to consume.
    var globalKeyDownEventHandler: ((GlobalKeyDownEvent) -> Bool)?

    /// Synchronous scroll handler for overlay UI that must prevent the
    /// frontmost app from also scrolling. Return true to consume.
    var globalScrollWheelEventHandler: ((GlobalScrollWheelEvent) -> Bool)?

    /// Virtual key code for Space (kVK_Space). Used by the text-command
    /// shortcut detection below.
    private static let textCommandShortcutKeyCode: UInt16 = 49

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?

    /// Whether the CGEvent tap is currently alive. We use this as
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

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .scrollWheel]
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
            options: .defaultTap,
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

        if eventType == .scrollWheel {
            let globalScrollWheelEvent = GlobalScrollWheelEvent(
                verticalDeltaInLines: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                verticalDeltaInPoints: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                horizontalDeltaInLines: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
                horizontalDeltaInPoints: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
                modifierFlagsRawValue: event.flags.rawValue
            )
            if globalScrollWheelEventHandler?(globalScrollWheelEvent) == true {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        var shouldConsumeCurrentEvent = false
        if eventType == .keyDown {
            let globalKeyDownEvent = GlobalKeyDownEvent(
                keyCode: eventKeyCode,
                modifierFlagsRawValue: event.flags.rawValue
            )
            shouldConsumeCurrentEvent = globalKeyDownEventHandler?(globalKeyDownEvent) ?? false
            if !shouldConsumeCurrentEvent {
                globalKeyDownPublisher.send(globalKeyDownEvent)
            }
        }

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

        // Text-command toggle hotkey: cmd + shift + space, detected on keyDown.
        // The listen-only tap doesn't consume the event, so this fires even
        // when another app currently has keyboard focus.
        if Self.isTextCommandShortcutKeyDown(
            eventType: eventType,
            keyCode: eventKeyCode,
            modifierFlags: event.flags
        ) {
            DotDebugLogger.log("shortcut.text", "text-command shortcut toggled")
            textCommandToggleRequestPublisher.send(())
        }

        if shouldConsumeCurrentEvent {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private static func isTextCommandShortcutKeyDown(
        eventType: CGEventType,
        keyCode: UInt16,
        modifierFlags: CGEventFlags
    ) -> Bool {
        guard eventType == .keyDown else { return false }
        guard keyCode == Self.textCommandShortcutKeyCode else { return false }
        // Must have cmd AND shift held, but neither option nor ctrl —
        // keep the shortcut unambiguous, avoid collisions with the
        // four-modifier emoji/special-character chords, and stay
        // disjoint from the push-to-talk modifier set (ctrl + option).
        guard modifierFlags.contains(.maskCommand) else { return false }
        guard modifierFlags.contains(.maskShift) else { return false }
        guard !modifierFlags.contains(.maskAlternate) else { return false }
        guard !modifierFlags.contains(.maskControl) else { return false }
        return true
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
