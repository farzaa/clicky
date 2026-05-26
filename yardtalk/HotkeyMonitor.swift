//
//  HotkeyMonitor.swift
//  yardtalk
//
//  Watches for a global hotkey. Two modes:
//  - .toggle: first press fires `onPress`, second press fires `onRelease`.
//    Used by the recording hotkey (⌃⌥D — toggle record start/stop).
//  - .tap: each press fires `onPress`; `onRelease` is never invoked and
//    `isActive` stays false. Used by the marker hotkey (⌃⌥M — drop a
//    marker each time it's pressed during a recording).
//
//  Requires Accessibility permission for the global monitor; the local
//  monitor handles the case where YardTalk itself is the active app.
//

import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class HotkeyMonitor {
    enum Mode {
        case toggle
        case tap
    }

    let mode: Mode
    let modifiers: NSEvent.ModifierFlags
    let keyCode: UInt16

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private(set) var isActive = false

    init(
        mode: Mode = .toggle,
        modifiers: NSEvent.ModifierFlags = [.control, .option],
        keyCode: UInt16 = UInt16(kVK_ANSI_D)
    ) {
        self.mode = mode
        self.modifiers = modifiers
        self.keyCode = keyCode
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

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleKeyDown(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleKeyDown(event)
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
        if mode == .toggle && isActive {
            isActive = false
            onRelease?()
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        let activeModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard activeModifiers == modifiers && event.keyCode == keyCode else { return }

        switch mode {
        case .toggle:
            if isActive {
                isActive = false
                onRelease?()
            } else {
                isActive = true
                onPress?()
            }
        case .tap:
            onPress?()
        }
    }
}
