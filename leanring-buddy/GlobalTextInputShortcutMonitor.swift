//
//  GlobalTextInputShortcutMonitor.swift
//  leanring-buddy
//
//  Captures the typed command popup shortcut while Clicky is backgrounded.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalTextInputShortcutMonitor: ObservableObject {
    let shortcutTriggeredPublisher = PassthroughSubject<Void, Never>()

    var currentShortcut: ClickyKeyboardShortcut {
        didSet {
            isShortcutCurrentlyPressed = false
        }
    }

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    private var isShortcutCurrentlyPressed = false

    init(currentShortcut: ClickyKeyboardShortcut = .persistedTextInputShortcut()) {
        self.currentShortcut = currentShortcut
    }

    deinit {
        stop()
    }

    func start() {
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalTextInputShortcutMonitor = Unmanaged<GlobalTextInputShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalTextInputShortcutMonitor.handleGlobalEventTap(
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
            print("⚠️ Global text input shortcut: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global text input shortcut: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

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
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let eventModifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            .intersection(.deviceIndependentFlagsMask)
        let eventMatchesCurrentShortcut = currentShortcut.matches(
            keyCode: eventKeyCode,
            modifierFlags: eventModifierFlags
        )

        if eventType == .keyDown && eventMatchesCurrentShortcut && !isShortcutCurrentlyPressed {
            isShortcutCurrentlyPressed = true
            shortcutTriggeredPublisher.send(())
        }

        if eventType == .keyUp && eventKeyCode == currentShortcut.keyCode {
            isShortcutCurrentlyPressed = false
        }

        if eventType == .flagsChanged && !eventModifierFlags.isSuperset(of: currentShortcut.modifierFlags) {
            isShortcutCurrentlyPressed = false
        }

        return Unmanaged.passUnretained(event)
    }
}
