//
//  GroundingAccessibilitySensor.swift
//  leanring-buddy
//
//  Accessibility and browser-surface confirmation for Vision-selected targets.
//  Values stay categorical so UI text and user content do not enter telemetry.
//

import AppKit
import ApplicationServices

@MainActor
enum GroundingAccessibilitySensor {
    struct Snapshot {
        let role: String?
        let roleCategory: GroundingBrowserRoleCategory
        let roleLooksInteractive: Bool
        let enabled: Bool?
        let hidden: Bool?
        let focused: Bool?
        let frontmostAppIsBrowser: Bool
    }

    static func accessibilitySignal(_ snapshot: Snapshot?) -> GroundingAuxiliarySignal {
        guard WindowPositionManager.hasAccessibilityPermission() else {
            return .unavailable(.macOSAccessibility)
        }
        guard let snapshot else {
            return .inconclusive(.macOSAccessibility)
        }
        if snapshot.enabled == false {
            return .contradicted(.macOSAccessibility, [.accessibilityElementDisabled])
        }
        if snapshot.roleLooksInteractive {
            return .confirmed(.macOSAccessibility)
        }
        if snapshot.role != nil {
            return .contradicted(.macOSAccessibility, [.accessibilityElementNotInteractive])
        }
        return .inconclusive(.macOSAccessibility)
    }

    static func browserMetadataSignal(_ metadata: GroundingBrowserMetadata) -> GroundingAuxiliarySignal {
        guard metadata.isWebSurface else {
            return .unavailable(.browserMetadata)
        }
        var contradictions: [GroundingSensorFusionContradiction] = []
        if metadata.elementDisabled == true {
            contradictions.append(.browserElementDisabled)
        }
        if metadata.elementHidden == true {
            contradictions.append(.browserElementHidden)
        }
        if metadata.elementCovered == true {
            contradictions.append(.browserElementCovered)
        }
        if !contradictions.isEmpty {
            return .contradicted(.browserMetadata, contradictions)
        }
        if metadata.elementInteractable == true || metadata.elementClickable == true {
            return .weaklyConfirmed(.browserMetadata)
        }
        if metadata.roleCategory != .unknown {
            return .inconclusive(.browserMetadata)
        }
        return .inconclusive(.browserMetadata)
    }

    static func browserMetadata(from snapshot: Snapshot?) -> GroundingBrowserMetadata {
        guard let snapshot,
              snapshot.frontmostAppIsBrowser else {
            return .unavailable
        }
        return GroundingBrowserMetadata(
            source: .accessibilityFallback,
            isWebSurface: true,
            roleCategory: snapshot.roleCategory,
            elementClickable: snapshot.roleLooksInteractive,
            elementInteractable: snapshot.enabled != false && snapshot.hidden != true && snapshot.roleLooksInteractive,
            elementDisabled: snapshot.enabled == false,
            elementHidden: snapshot.hidden == true,
            elementCovered: nil
        )
    }

    static func snapshot(
        at displayPoint: CGPoint,
        in displayFrame: CGRect,
        policy: GroundingSensorFusionPolicy
    ) -> Snapshot? {
        guard WindowPositionManager.hasAccessibilityPermission() else {
            return nil
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        var elementAtPoint: AXUIElement?
        let axY = displayFrame.maxY - displayPoint.y
        let result = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(displayPoint.x),
            Float(axY),
            &elementAtPoint
        )
        guard result == .success,
              let elementAtPoint else {
            return Snapshot(
                role: nil,
                roleCategory: .unknown,
                roleLooksInteractive: false,
                enabled: nil,
                hidden: nil,
                focused: nil,
                frontmostAppIsBrowser: isFrontmostAppBrowser()
            )
        }

        var currentElement: AXUIElement? = elementAtPoint
        var depth = 0
        var firstRole: String?
        var firstEnabled: Bool?
        var firstHidden: Bool?
        var firstFocused: Bool?

        while let element = currentElement, depth <= policy.maximumAXParentDepth {
            let role = axStringAttribute(element, kAXRoleAttribute as String)
            let enabled = axBoolAttribute(element, kAXEnabledAttribute as String)
            let hidden = axBoolAttribute(element, "AXHidden")
            let focused = axBoolAttribute(element, kAXFocusedAttribute as String)

            if firstRole == nil { firstRole = role }
            if firstEnabled == nil { firstEnabled = enabled }
            if firstHidden == nil { firstHidden = hidden }
            if firstFocused == nil { firstFocused = focused }

            if let role,
               interactiveAXRoles.contains(role) {
                return Snapshot(
                    role: role,
                    roleCategory: browserRoleCategory(forAXRole: role),
                    roleLooksInteractive: true,
                    enabled: enabled ?? firstEnabled,
                    hidden: hidden ?? firstHidden,
                    focused: focused ?? firstFocused,
                    frontmostAppIsBrowser: isFrontmostAppBrowser()
                )
            }

            currentElement = axElementAttribute(element, kAXParentAttribute as String)
            depth += 1
        }

        return Snapshot(
            role: firstRole,
            roleCategory: browserRoleCategory(forAXRole: firstRole),
            roleLooksInteractive: false,
            enabled: firstEnabled,
            hidden: firstHidden,
            focused: firstFocused,
            frontmostAppIsBrowser: isFrontmostAppBrowser()
        )
    }

    private static let interactiveAXRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXMenuButton",
        "AXMenuItem",
        "AXLink",
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSlider",
        "AXIncrementor",
    ]

    private static func browserRoleCategory(forAXRole role: String?) -> GroundingBrowserRoleCategory {
        switch role {
        case "AXButton":
            return .button
        case "AXLink":
            return .link
        case "AXTextField", "AXTextArea", "AXComboBox":
            return .textField
        case "AXCheckBox":
            return .checkbox
        case "AXRadioButton":
            return .radioButton
        case "AXMenuButton":
            return .menu
        case "AXMenuItem":
            return .menuItem
        case "AXPopUpButton":
            return .select
        case "AXSlider", "AXIncrementor":
            return .slider
        case "AXTable":
            return .table
        case "AXTabGroup":
            return .tab
        case nil:
            return .unknown
        default:
            return .other
        }
    }

    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "company.thebrowser.Browser",
    ]

    private static func isFrontmostAppBrowser() -> Bool {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return browserBundleIdentifiers.contains(bundleIdentifier)
    }

    private static func axStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let stringValue = value as? String else {
            return nil
        }
        return stringValue
    }

    private static func axBoolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private static func axElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        let opaqueValue = Unmanaged.passUnretained(value).toOpaque()
        return Unmanaged<AXUIElement>.fromOpaque(opaqueValue).takeUnretainedValue()
    }
}
