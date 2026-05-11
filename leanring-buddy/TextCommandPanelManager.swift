//
//  TextCommandPanelManager.swift
//  leanring-buddy
//
//  Floating single-line text-command panel for Dot. Shown/hidden by
//  cmd+shift+space; submitting feeds the same downstream agent loop as a
//  push-to-talk voice transcript. Auto-hides on submit/escape/click-out
//  so screenshots taken by the agent loop don't include the panel.
//
//  Mirrors MenuBarPanelManager's NSPanel pattern (borderless,
//  non-activating, KeyablePanel-compatible) so the text field can grab
//  keyboard focus without bringing Dot to the foreground in the dock.
//

import AppKit
import SwiftUI

@MainActor
final class TextCommandPanelManager: NSObject {
    /// Width of the floating command palette. Tuned to be wide enough to
    /// type a sentence-length command without scrolling, narrow enough
    /// not to dominate the screen.
    private let textCommandPanelWidth: CGFloat = 560

    /// Distance from the top of the active screen the panel floats at.
    /// Above-center reads as "command palette" (Spotlight-style) and
    /// keeps it out of the way of typical page content the agent will
    /// operate on after submit.
    private let panelTopOffsetFromActiveScreenInPoints: CGFloat = 180

    private var textCommandPanel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var weakAppToRestoreOnHide: NSRunningApplication?

    private let onTextCommandSubmitted: (String) -> Void

    init(onTextCommandSubmitted: @escaping (String) -> Void) {
        self.onTextCommandSubmitted = onTextCommandSubmitted
        super.init()
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localKeyDownMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Tap-to-toggle entry point. Wired to the shortcut monitor's
    /// text-command publisher; each tap either shows or hides the panel.
    func toggleTextCommandPanel() {
        if let textCommandPanel, textCommandPanel.isVisible {
            hideTextCommandPanel(restoreFocusToPreviousApp: true)
        } else {
            showTextCommandPanel()
        }
    }

    // MARK: - Show / hide

    private func showTextCommandPanel() {
        // Remember which app the user was working in so we can hand
        // focus back when the panel dismisses. macOS does this naturally
        // for many cases, but explicit activation removes the edge cases
        // (notably when the user submitted and the agent loop kicks in).
        weakAppToRestoreOnHide = NSWorkspace.shared.frontmostApplication

        if textCommandPanel == nil {
            createTextCommandPanel()
        }

        positionPanelAboveCenterOfActiveScreen()
        textCommandPanel?.makeKeyAndOrderFront(nil)
        textCommandPanel?.orderFrontRegardless()
        installClickOutsideMonitor()
        installEscapeKeyMonitor()
    }

    /// Hides the panel, removes its event monitors, and (optionally)
    /// activates whatever app was frontmost when the panel was shown.
    /// `restoreFocusToPreviousApp` is false when we hide because the
    /// user submitted a command — the agent loop is about to operate on
    /// the previous app's window, and explicit activation would create
    /// an unnecessary flash. macOS handles focus restoration naturally
    /// in that case.
    private func hideTextCommandPanel(restoreFocusToPreviousApp: Bool) {
        textCommandPanel?.orderOut(nil)
        removeClickOutsideMonitor()
        removeEscapeKeyMonitor()
        if restoreFocusToPreviousApp {
            weakAppToRestoreOnHide?.activate(options: [])
        }
        weakAppToRestoreOnHide = nil
    }

    private func createTextCommandPanel() {
        let panelHeightEstimate: CGFloat = 60

        let textCommandPanelView = TextCommandPanelView(
            onSubmitCommand: { [weak self] submittedText in
                self?.handleSubmittedCommand(submittedText)
            },
            onDismiss: { [weak self] in
                self?.hideTextCommandPanel(restoreFocusToPreviousApp: true)
            }
        )
        .frame(width: textCommandPanelWidth)

        let hostingView = NSHostingView(rootView: textCommandPanelView)
        hostingView.frame = NSRect(
            x: 0, y: 0,
            width: textCommandPanelWidth,
            height: panelHeightEstimate
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let panel = KeyablePanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: textCommandPanelWidth,
                height: panelHeightEstimate
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentView = hostingView

        textCommandPanel = panel
    }

    private func positionPanelAboveCenterOfActiveScreen() {
        guard let textCommandPanel else { return }

        let activeScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let activeScreen else { return }

        // Resize panel to actual content height once SwiftUI has measured
        // itself — avoids the panel being taller or shorter than the pill.
        let fittingHeight = textCommandPanel.contentView?.fittingSize.height
            ?? textCommandPanel.frame.height

        let activeScreenFrame = activeScreen.visibleFrame
        let panelOriginX = activeScreenFrame.midX - (textCommandPanelWidth / 2)
        let panelOriginY = activeScreenFrame.maxY - panelTopOffsetFromActiveScreenInPoints - fittingHeight

        textCommandPanel.setFrame(
            NSRect(
                x: panelOriginX,
                y: panelOriginY,
                width: textCommandPanelWidth,
                height: fittingHeight
            ),
            display: true
        )
    }

    private func handleSubmittedCommand(_ submittedText: String) {
        // Hide BEFORE we ask the agent loop to start so the first
        // screenshot doesn't include the panel chrome.
        hideTextCommandPanel(restoreFocusToPreviousApp: false)
        onTextCommandSubmitted(submittedText)
    }

    // MARK: - Click-outside dismissal

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, let textCommandPanel = self.textCommandPanel else { return }
            let mouseLocationInScreenSpace = NSEvent.mouseLocation
            if textCommandPanel.frame.contains(mouseLocationInScreenSpace) {
                return
            }
            self.hideTextCommandPanel(restoreFocusToPreviousApp: true)
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }

    // MARK: - Escape-key dismissal

    /// SwiftUI's TextField doesn't expose an "onEscape" callback on
    /// older macOS targets, so we install a local NSEvent monitor that
    /// only fires while the panel is the key window. Returning nil
    /// consumes the event so escape doesn't leak through to the text
    /// field itself.
    private func installEscapeKeyMonitor() {
        removeEscapeKeyMonitor()
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // 53 is the macOS virtual key code for Escape.
            if event.keyCode == 53 {
                self.hideTextCommandPanel(restoreFocusToPreviousApp: true)
                return nil
            }
            return event
        }
    }

    private func removeEscapeKeyMonitor() {
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }
    }
}
