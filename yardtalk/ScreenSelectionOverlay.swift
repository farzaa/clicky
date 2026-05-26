//
//  ScreenSelectionOverlay.swift
//  yardtalk
//
//  Full-screen overlays for visual display selection. One borderless
//  window per connected display, each showing a "Record This Screen"
//  button. Clicking one selects that display and dismisses all overlays.
//  Pressing Escape cancels without changing the selection.
//
//  LSUIElement apps don't activate normally, so we subclass NSWindow to
//  override canBecomeKey/canBecomeMain and use NSApp.activate to bring
//  the overlay to front. An NSEvent local monitor handles Escape since
//  the SwiftUI onKeyPress won't fire without proper first-responder
//  chain in a non-activating app.
//

import AppKit
import SwiftUI

@MainActor
final class ScreenSelectionOverlay {
    private var windows: [NSWindow] = []
    private var onSelect: ((CGDirectDisplayID) -> Void)?
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?

    func show(displays: [DisplayInfo], currentSelection: CGDirectDisplayID?, onSelect: @escaping (CGDirectDisplayID) -> Void) {
        dismiss()
        self.onSelect = onSelect

        for display in displays {
            guard let screen = screenForDisplay(display.id) else { continue }

            let isSelected = display.id == currentSelection
            let overlayView = ScreenOverlayView(
                displayInfo: display,
                isCurrentSelection: isSelected,
                onSelect: { [weak self] in
                    self?.selectDisplay(display.id)
                },
                onCancel: { [weak self] in
                    self?.dismiss()
                }
            )

            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.contentView = NSHostingView(rootView: overlayView)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .statusBar + 1
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = false
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true

            window.setFrame(screen.frame, display: true)
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        for window in windows {
            window.makeKeyAndOrderFront(nil)
        }

        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.dismiss()
                return nil
            }
            return event
        }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in
                    self?.dismiss()
                }
            }
        }
    }

    func dismiss() {
        if let monitor = localEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            localEscapeMonitor = nil
        }
        if let monitor = globalEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            globalEscapeMonitor = nil
        }
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        onSelect = nil
    }

    private func selectDisplay(_ displayID: CGDirectDisplayID) {
        let callback = onSelect
        dismiss()
        callback?(displayID)
    }

    private func screenForDisplay(_ displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct ScreenOverlayView: View {
    let displayInfo: DisplayInfo
    let isCurrentSelection: Bool
    let onSelect: () -> Void
    let onCancel: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .onTapGesture { onCancel() }

            VStack(spacing: 16) {
                Image(systemName: "display")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundColor(.white.opacity(0.8))

                Text(displayInfo.name)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)

                Text("\(displayInfo.width) × \(displayInfo.height)")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))

                if isCurrentSelection {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                        Text("Currently Selected")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.green.opacity(0.9))
                    .padding(.top, 4)
                }

                Button(action: onSelect) {
                    Text(isCurrentSelection ? "Keep This Screen" : "Record This Screen")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(isHovering ? Color.blue : Color.blue.opacity(0.8))
                        )
                        .shadow(color: .blue.opacity(0.4), radius: isHovering ? 12 : 6)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHovering = hovering
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Text("Press Esc or click anywhere to cancel")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.top, 8)
            }
        }
        .ignoresSafeArea()
    }
}
