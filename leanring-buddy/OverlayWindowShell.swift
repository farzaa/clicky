//
//  OverlayWindowShell.swift
//  leanring-buddy
//
//  Transparent click-through AppKit shell used by Spider's per-screen overlay.
//

import AppKit

final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hasShadow = false
        hidesOnDeactivate = false
        setFrame(screen.frame, display: true)

        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}
