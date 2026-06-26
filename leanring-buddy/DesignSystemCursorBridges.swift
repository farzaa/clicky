//
//  DesignSystemCursorBridges.swift
//  leanring-buddy
//
//  Narrow AppKit bridges for cursor rects and native tooltips.
//

import AppKit
import SwiftUI

/// Uses AppKit's cursor rect system to reliably show a pointing hand cursor.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

/// Uses AppKit's cursor rect system to reliably show an I-beam cursor.
private class IBeamCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    /// Pass through mouse events so the text control underneath still receives focus.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct IBeamCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        IBeamCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private struct NativeTooltipView: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

extension View {
    /// Attaches a native macOS tooltip that works even alongside `.onHover`.
    func nativeTooltip(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            return AnyView(self.overlay(NativeTooltipView(tooltip: text)))
        } else {
            return AnyView(self)
        }
    }
}
