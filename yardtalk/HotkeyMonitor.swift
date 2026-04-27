//
//  HotkeyMonitor.swift
//  yardtalk
//
//  Watches for hold-to-record modifier-only hotkeys. Default trigger is
//  Control+Option. Fires `onPress` on the leading edge (modifiers held
//  exactly), `onRelease` on the trailing edge. Requires Accessibility
//  permission for the global monitor; the local monitor handles the case
//  where YardTalk itself is the active app.
//

import AppKit
import Foundation

@MainActor
final class HotkeyMonitor {
    let trigger: NSEvent.ModifierFlags

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isPressed = false

    init(trigger: NSEvent.ModifierFlags = [.control, .option]) {
        self.trigger = trigger
    }

    deinit {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func start() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
            return event
        }
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if isPressed {
            isPressed = false
            onRelease?()
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let activeModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let nowPressed = activeModifiers == trigger

        if nowPressed && !isPressed {
            isPressed = true
            onPress?()
        } else if !nowPressed && isPressed {
            isPressed = false
            onRelease?()
        }
    }
}
