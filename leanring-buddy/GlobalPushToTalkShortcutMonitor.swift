//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures Spider keyboard shortcuts while the app runs in the background.
//  Uses Carbon for the reliable summon hotkey, plus a listen-only CGEvent tap
//  for modifier-only push-to-talk when Accessibility allows it.
//

import AppKit
import Combine
import Carbon.HIToolbox
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    private var summonHotKeyRef: EventHotKeyRef?
    private var summonHotKeyEventHandler: EventHandlerRef?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start(accessibilityTrusted: Bool) {
        registerSummonHotKeyIfNeeded()

        guard accessibilityTrusted else {
            stopEventTap()
            return
        }

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
            SpiderDiagnostics.event("global push-to-talk event tap creation failed")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            SpiderDiagnostics.event("global push-to-talk run loop source creation failed")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false
        stopEventTap()
        stopSummonHotKey()
    }

    private func stopEventTap() {
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

    private func registerSummonHotKeyIfNeeded() {
        guard summonHotKeyRef == nil else { return }

        if summonHotKeyEventHandler == nil {
            var eventTypes = [
                EventTypeSpec(
                    eventClass: OSType(kEventClassKeyboard),
                    eventKind: UInt32(kEventHotKeyPressed)
                ),
                EventTypeSpec(
                    eventClass: OSType(kEventClassKeyboard),
                    eventKind: UInt32(kEventHotKeyReleased)
                ),
            ]

            let handlerStatus = eventTypes.withUnsafeMutableBufferPointer { bufferPointer in
                InstallEventHandler(
                    GetApplicationEventTarget(),
                    Self.summonHotKeyHandler,
                    Int(UInt32(bufferPointer.count)),
                    bufferPointer.baseAddress,
                    Unmanaged.passUnretained(self).toOpaque(),
                    &summonHotKeyEventHandler
                )
            }

            guard handlerStatus == noErr else {
                SpiderDiagnostics.event("summon hotkey handler creation failed")
                return
            }
        }

        let hotKeyID = EventHotKeyID(
            signature: Self.summonHotKeySignature,
            id: Self.summonHotKeyID
        )
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &summonHotKeyRef
        )

        if hotKeyStatus != noErr {
            SpiderDiagnostics.event("summon hotkey registration failed")
        }
    }

    private func stopSummonHotKey() {
        if let summonHotKeyRef {
            UnregisterEventHotKey(summonHotKeyRef)
            self.summonHotKeyRef = nil
        }

        if let summonHotKeyEventHandler {
            RemoveEventHandler(summonHotKeyEventHandler)
            self.summonHotKeyEventHandler = nil
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
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }

    private static let summonHotKeySignature: OSType = 0x5350_4452 // SPDR
    private static let summonHotKeyID: UInt32 = 1

    private static let summonHotKeyHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }

        var hotKeyID = EventHotKeyID()
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard parameterStatus == noErr,
              hotKeyID.signature == GlobalPushToTalkShortcutMonitor.summonHotKeySignature,
              hotKeyID.id == GlobalPushToTalkShortcutMonitor.summonHotKeyID else {
            return noErr
        }

        let monitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
            .fromOpaque(userData)
            .takeUnretainedValue()

        let eventKind = GetEventKind(event)

        DispatchQueue.main.async {
            monitor.handleReliableHotKeyEvent(eventKind: eventKind)
        }

        return noErr
    }

    private func handleReliableHotKeyEvent(eventKind: UInt32) {
        switch eventKind {
        case UInt32(kEventHotKeyPressed):
            guard !isShortcutCurrentlyPressed else { return }
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case UInt32(kEventHotKeyReleased):
            guard isShortcutCurrentlyPressed else { return }
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        default:
            break
        }
    }
}
