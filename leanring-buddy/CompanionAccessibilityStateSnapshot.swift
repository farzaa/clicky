//
//  CompanionAccessibilityStateSnapshot.swift
//  leanring-buddy
//
//  Captures the post-action macOS Accessibility state so the agent loop
//  can feed Claude unambiguous ground truth in every tool_result, instead
//  of asking the model to infer "did the action take effect?" from
//  screenshots alone. See AGENTS.md for the design rationale.
//

import AppKit
import ApplicationServices

/// Snapshot of "what does macOS think happened?" after an agent tool call.
///
/// Captured fields (each independently optional — partial captures are fine):
///   - frontmostApplicationName: app that owns keyboard focus
///   - frontmostWindowTitle: title of that app's key window
///   - focusedElementRole: AX role of the currently-focused element
///     (e.g. AXTextField, AXTextArea, AXButton, AXWebArea)
///   - focusedElementValue: current value of the focused element, truncated
///     (text for fields, numeric string for sliders, etc.)
///   - focusedElementLabel: best-effort human-readable label for the
///     focused element (kAXTitle → kAXDescription → kAXIdentifier →
///     kAXPlaceholderValue, in that order of preference)
///
/// Every field is independently optional — AX queries can fail per-attribute
/// without failing the whole snapshot, so we capture what we can. If
/// nothing meaningful was captured, `compactDescription` returns "" so
/// we don't pollute the model's context with empty placeholder fields.
struct CompanionAccessibilityStateSnapshot {
    let frontmostApplicationName: String?
    let frontmostWindowTitle: String?
    let focusedElementRole: String?
    let focusedElementValue: String?
    let focusedElementLabel: String?
    /// Diagnostic: which AX lookup path actually returned the focused
    /// element. Logged so we can tell which paths succeed for which apps.
    /// Possible values: "system-wide", "frontmost-app", "focused-window",
    /// "none".
    let focusedElementSource: String

    /// Reads the current AX state. Costs roughly 5–30 ms depending on how
    /// many attribute queries succeed; the AX framework batches across the
    /// XPC boundary so a handful of attribute reads stays cheap. Safe to
    /// call from any thread per Apple's documentation.
    static func capture() -> CompanionAccessibilityStateSnapshot {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let frontmostApplicationName = frontmostApplication?.localizedName

        // Try several paths to find the focused UI element. Electron apps
        // (Slack, Discord, VS Code) don't reliably bubble focus through
        // the system-wide AX root, so a single lookup misses them. We try
        // in order of generality and stop at the first success.
        var focusedElement: AXUIElement? = nil
        var focusedElementSource = "none"

        // Path 1: system-wide AX root. Works for most native apps.
        let systemWideElement = AXUIElementCreateSystemWide()
        if let element = Self.copyAXElementAttribute(
            from: systemWideElement,
            attributeName: kAXFocusedUIElementAttribute
        ) {
            focusedElement = element
            focusedElementSource = "system-wide"
        }

        // Path 2: frontmost-app AX root. Works for Electron contenteditables
        // and other apps that don't propagate focus to the session-level
        // AX root but DO answer focus queries against their own process.
        if focusedElement == nil, let frontmostProcessIdentifier = frontmostApplication?.processIdentifier {
            let applicationAXElement = AXUIElementCreateApplication(frontmostProcessIdentifier)
            if let element = Self.copyAXElementAttribute(
                from: applicationAXElement,
                attributeName: kAXFocusedUIElementAttribute
            ) {
                focusedElement = element
                focusedElementSource = "frontmost-app"
            }

            // Path 3: frontmost-app's focused window. Some apps expose
            // kAXFocusedUIElementAttribute only on the window, not the
            // process. Walk down from the focused window.
            if focusedElement == nil,
               let focusedWindow = Self.copyAXElementAttribute(
                   from: applicationAXElement,
                   attributeName: kAXFocusedWindowAttribute
               ),
               let elementFromWindow = Self.copyAXElementAttribute(
                   from: focusedWindow,
                   attributeName: kAXFocusedUIElementAttribute
               ) {
                focusedElement = elementFromWindow
                focusedElementSource = "focused-window"
            }
        }

        let focusedElementRole = focusedElement.flatMap {
            Self.copyStringAttribute(from: $0, attributeName: kAXRoleAttribute)
        }
        let focusedElementValue = focusedElement.flatMap {
            Self.copyAXValueDescription(from: $0)
        }
        let focusedElementLabel = focusedElement.flatMap {
            Self.copyFocusedElementLabel(from: $0)
        }

        let frontmostWindowTitle = Self.computeFrontmostWindowTitle(
            focusedElement: focusedElement,
            frontmostApplication: frontmostApplication
        )

        DotDebugLogger.log("ax.snapshot", "captured", metadata: [
            "axTrusted": AXIsProcessTrusted(),
            "frontmost": frontmostApplicationName ?? "nil",
            "focusedSource": focusedElementSource,
            "focusedRole": focusedElementRole ?? "nil",
            "focusedValueLength": focusedElementValue?.count ?? 0
        ])

        return CompanionAccessibilityStateSnapshot(
            frontmostApplicationName: frontmostApplicationName,
            frontmostWindowTitle: frontmostWindowTitle,
            focusedElementRole: focusedElementRole,
            focusedElementValue: focusedElementValue,
            focusedElementLabel: focusedElementLabel,
            focusedElementSource: focusedElementSource
        )
    }

    /// Compact one-line rendering for inclusion in a `tool_result` content
    /// string. Returns "" when nothing meaningful was captured so the
    /// caller can skip appending it. Format is intentionally simple
    /// `key=value, key=value` pairs so the model can scan it at a glance:
    ///
    ///     [ax] frontmost=Slack window="Susanna Atanessian", focused=AXTextArea label="Message Susanna Atanessian" value=""
    var compactDescription: String {
        var sections: [String] = []

        if let frontmostApplicationName {
            var applicationSection = "frontmost=\(frontmostApplicationName)"
            if let frontmostWindowTitle, !frontmostWindowTitle.isEmpty {
                applicationSection += " window=\(Self.quotedForToolResult(frontmostWindowTitle))"
            }
            sections.append(applicationSection)
        }

        if let focusedElementRole {
            var focusSection = "focused=\(focusedElementRole)"
            if let focusedElementLabel, !focusedElementLabel.isEmpty {
                focusSection += " label=\(Self.quotedForToolResult(focusedElementLabel))"
            }
            if let focusedElementValue {
                let truncatedValue: String
                if focusedElementValue.count > Self.maximumFocusedValueCharacterCount {
                    truncatedValue = String(focusedElementValue.prefix(Self.maximumFocusedValueCharacterCount)) + "…"
                } else {
                    truncatedValue = focusedElementValue
                }
                focusSection += " value=\(Self.quotedForToolResult(truncatedValue))"
            }
            sections.append(focusSection)
        }

        guard !sections.isEmpty else { return "" }
        return "[ax] " + sections.joined(separator: ", ")
    }

    // MARK: - Internals

    /// We truncate the focused element's value so a 10 KB textarea
    /// doesn't blow up every tool_result. 200 chars is plenty for the
    /// model to recognize "input has 'hello' in it" or "field is empty".
    private static let maximumFocusedValueCharacterCount = 200

    /// Generic AX attribute reader returning a `String?` (e.g. kAXRole,
    /// kAXTitle, kAXDescription). Returns nil for any failure mode so
    /// callers can short-circuit naturally with `flatMap`.
    private static func copyStringAttribute(
        from element: AXUIElement,
        attributeName: String
    ) -> String? {
        var rawValue: AnyObject?
        let copyStatus = AXUIElementCopyAttributeValue(
            element,
            attributeName as CFString,
            &rawValue
        )
        guard copyStatus == .success else { return nil }
        return rawValue as? String
    }

    /// Generic AX attribute reader returning a child `AXUIElement?`
    /// (e.g. kAXFocusedUIElement, kAXWindow, kAXFocusedWindow).
    private static func copyAXElementAttribute(
        from element: AXUIElement,
        attributeName: String
    ) -> AXUIElement? {
        var rawValue: AnyObject?
        let copyStatus = AXUIElementCopyAttributeValue(
            element,
            attributeName as CFString,
            &rawValue
        )
        guard copyStatus == .success, let rawValue else { return nil }
        guard CFGetTypeID(rawValue) == AXUIElementGetTypeID() else { return nil }
        return (rawValue as! AXUIElement)
    }

    /// `kAXValueAttribute` returns CFString for text fields but CFNumber for
    /// sliders/steppers and CFBoolean for toggles. We coerce to a printable
    /// form so the snapshot always has a usable string representation.
    private static func copyAXValueDescription(from element: AXUIElement) -> String? {
        var rawValue: AnyObject?
        let copyStatus = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &rawValue
        )
        guard copyStatus == .success, let rawValue else { return nil }
        if let stringValue = rawValue as? String { return stringValue }
        if let numberValue = rawValue as? NSNumber { return numberValue.stringValue }
        return String(describing: rawValue)
    }

    /// Best-effort human-readable label for the focused element. Order
    /// favors explicit labels over fallbacks. Many text fields expose only
    /// `kAXPlaceholderValueAttribute` (the gray placeholder text), so we
    /// keep that as the lowest-priority fallback rather than dropping it.
    private static func copyFocusedElementLabel(from element: AXUIElement) -> String? {
        let attributeCandidates: [String] = [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXIdentifierAttribute,
            kAXPlaceholderValueAttribute
        ]
        for attributeName in attributeCandidates {
            if let value = copyStringAttribute(from: element, attributeName: attributeName),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Resolves the title of the window the user is interacting with.
    /// Preferred path: walk from the focused element to its containing
    /// window. Fallback: ask the frontmost app's AX root for its focused
    /// window. Either path can return nil (web content, custom-drawn
    /// surfaces, apps without AX) — that's expected.
    private static func computeFrontmostWindowTitle(
        focusedElement: AXUIElement?,
        frontmostApplication: NSRunningApplication?
    ) -> String? {
        if let focusedElement,
           let containingWindow = copyAXElementAttribute(
               from: focusedElement,
               attributeName: kAXWindowAttribute
           ),
           let titleFromContainingWindow = copyStringAttribute(
               from: containingWindow,
               attributeName: kAXTitleAttribute
           ),
           !titleFromContainingWindow.isEmpty {
            return titleFromContainingWindow
        }

        guard let processIdentifier = frontmostApplication?.processIdentifier else {
            return nil
        }
        let applicationAXElement = AXUIElementCreateApplication(processIdentifier)
        guard let focusedWindow = copyAXElementAttribute(
            from: applicationAXElement,
            attributeName: kAXFocusedWindowAttribute
        ) else {
            return nil
        }
        return copyStringAttribute(from: focusedWindow, attributeName: kAXTitleAttribute)
    }

    /// Single-line quoting that's safe for the model to parse. Strip
    /// newlines/CRs so the `[ax] ...` line stays on one line, and wrap
    /// in double-quotes so embedded commas/spaces don't confuse the model
    /// about field boundaries.
    private static func quotedForToolResult(_ value: String) -> String {
        let singleLineValue = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\"\(singleLineValue)\""
    }
}
