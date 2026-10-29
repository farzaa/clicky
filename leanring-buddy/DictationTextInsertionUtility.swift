//
//  DictationTextInsertionUtility.swift
//  leanring-buddy
//
//  Copy and insert helpers for the dictation history panel. "Insert" pastes
//  a saved transcript into whatever text field has focus in the app the user
//  was working in, then puts their previous clipboard contents back so the
//  insert never clobbers something they had copied.
//

import AppKit
import ApplicationServices

enum DictationTextInsertionUtility {
    /// Virtual key code for the "V" key on an ANSI keyboard (kVK_ANSI_V).
    private static let virtualKeyCodeForLetterV: CGKeyCode = 9

    /// How long to wait after the menu bar panel closes before sending cmd+V,
    /// so keyboard focus has returned to the app underneath.
    private static let delayBeforePastingAfterPanelDismissal: Duration = .milliseconds(150)

    /// Apps read the pasteboard asynchronously after they receive cmd+V, so we
    /// wait before restoring the user's previous clipboard contents.
    private static let delayBeforeRestoringPreviousClipboard: Duration = .milliseconds(500)

    /// Synthesizing a cmd+V keystroke requires Accessibility permission,
    /// which Clicky already asks for during onboarding.
    static var canInsertTextIntoFrontmostApp: Bool {
        AXIsProcessTrusted()
    }

    static func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Pastes text into the frontmost app by temporarily placing it on the
    /// clipboard and synthesizing cmd+V. The caller is responsible for
    /// dismissing the menu bar panel first so it doesn't receive the keystroke.
    static func insertTextIntoFrontmostApp(_ text: String) async {
        // The menu bar panel is non-activating, so the user's app normally stays
        // frontmost. If Clicky did become active (e.g. after a system prompt),
        // hand focus back so the paste lands in the user's app, not ours.
        if NSApp.isActive {
            NSApp.deactivate()
        }

        let pasteboard = NSPasteboard.general
        let previousClipboardItems = snapshotOfPasteboardItems(pasteboard)

        copyTextToClipboard(text)
        let pasteboardChangeCountAfterWritingText = pasteboard.changeCount

        try? await Task.sleep(for: delayBeforePastingAfterPanelDismissal)
        postCommandVKeystroke()

        try? await Task.sleep(for: delayBeforeRestoringPreviousClipboard)

        // Only restore if nothing else touched the clipboard in the meantime —
        // if the user copied something new, that should win.
        guard pasteboard.changeCount == pasteboardChangeCountAfterWritingText else { return }
        restorePasteboardItems(previousClipboardItems, to: pasteboard)
    }

    // MARK: - Private

    /// One representation (e.g. plain text, RTF, image) of a single pasteboard item.
    private typealias PasteboardItemRepresentation = (type: NSPasteboard.PasteboardType, data: Data)

    /// Each inner array holds every representation of one pasteboard item.
    private static func snapshotOfPasteboardItems(_ pasteboard: NSPasteboard) -> [[PasteboardItemRepresentation]] {
        let pasteboardItems = pasteboard.pasteboardItems ?? []

        return pasteboardItems.map { pasteboardItem -> [PasteboardItemRepresentation] in
            pasteboardItem.types.compactMap { pasteboardType -> PasteboardItemRepresentation? in
                guard let representationData = pasteboardItem.data(forType: pasteboardType) else { return nil }
                return (type: pasteboardType, data: representationData)
            }
        }
    }

    private static func restorePasteboardItems(
        _ previousClipboardItems: [[PasteboardItemRepresentation]],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()

        let restoredPasteboardItems: [NSPasteboardItem] = previousClipboardItems.compactMap { itemRepresentations -> NSPasteboardItem? in
            guard !itemRepresentations.isEmpty else { return nil }
            let restoredPasteboardItem = NSPasteboardItem()
            for representation in itemRepresentations {
                restoredPasteboardItem.setData(representation.data, forType: representation.type)
            }
            return restoredPasteboardItem
        }

        if !restoredPasteboardItems.isEmpty {
            pasteboard.writeObjects(restoredPasteboardItems)
        }
    }

    private static func postCommandVKeystroke() {
        let keyboardEventSource = CGEventSource(stateID: .combinedSessionState)

        guard let keyDownEvent = CGEvent(
            keyboardEventSource: keyboardEventSource,
            virtualKey: virtualKeyCodeForLetterV,
            keyDown: true
        ),
        let keyUpEvent = CGEvent(
            keyboardEventSource: keyboardEventSource,
            virtualKey: virtualKeyCodeForLetterV,
            keyDown: false
        ) else {
            print("⚠️ Dictation history: couldn't create cmd+V keyboard events")
            return
        }

        keyDownEvent.flags = .maskCommand
        keyUpEvent.flags = .maskCommand
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
    }
}
