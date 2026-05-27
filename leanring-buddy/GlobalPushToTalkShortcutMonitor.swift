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
import os

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.yourcompany.leanring-buddy",
        category: "PushToTalk"
    )

    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// True once a CGEvent tap is installed and enabled for this process.
    @Published private(set) var isEventTapInstalled = false

    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        guard WindowPositionManager.hasInputMonitoringPermission() else {
            Self.logger.error("Input Monitoring permission missing — push-to-talk hotkey inactive")
            stop()
            return
        }

        if let globalEventTap, !CGEvent.tapIsEnabled(tap: globalEventTap) {
            Self.logger.notice("Recreating disabled CGEvent tap")
            stop()
        }

        guard globalEventTap == nil else {
            isEventTapInstalled = true
            return
        }

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
            if !CGPreflightListenEventAccess() {
                Self.logger.error("Input Monitoring permission required for push-to-talk")
                print("⚠️ Global push-to-talk: Input Monitoring permission is required (System Settings → Privacy & Security → Input Monitoring)")
            } else {
                Self.logger.error("CGEvent tapCreate returned nil despite Input Monitoring being granted")
                print("⚠️ Global push-to-talk: couldn't create CGEvent tap — quit and reopen Clicky")
            }
            isEventTapInstalled = false
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            Self.logger.error("Couldn't create CGEvent tap run loop source")
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            isEventTapInstalled = false
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
        isEventTapInstalled = CGEvent.tapIsEnabled(tap: globalEventTap)
        Self.logger.notice("CGEvent tap installed (enabled=\(self.isEventTapInstalled, privacy: .public))")
    }

    func stop() {
        isShortcutCurrentlyPressed = false
        isEventTapInstalled = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            Self.logger.notice("CGEvent tap disabled by system — re-enabling")
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
                isEventTapInstalled = CGEvent.tapIsEnabled(tap: globalEventTap)
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

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            Self.logger.notice("Push-to-talk shortcut pressed")
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            Self.logger.notice("Push-to-talk shortcut released")
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }
}
