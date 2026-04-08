//
//  ComputerUseActionExecutor.swift
//  leanring-buddy
//
//  Executes local computer-control actions for Computer Use mode.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct ComputerUseActionInstruction: Decodable {
    let type: String
    let x: Double?
    let y: Double?
    let screen: Int?
    let text: String?
    let key: String?
    let modifiers: [String]?
    let startX: Double?
    let startY: Double?
    let endX: Double?
    let endY: Double?
    let deltaX: Double?
    let deltaY: Double?

    /// Copies the instruction while overriding screenshot-space coordinates from `[POINT:...]`
    /// so pointer and click use the same integers.
    func replacingSpatialFields(x: Double?, y: Double?, screen: Int?) -> ComputerUseActionInstruction {
        ComputerUseActionInstruction(
            type: type,
            x: x ?? self.x,
            y: y ?? self.y,
            screen: screen ?? self.screen,
            text: text,
            key: key,
            modifiers: modifiers,
            startX: startX,
            startY: startY,
            endX: endX,
            endY: endY,
            deltaX: deltaX,
            deltaY: deltaY
        )
    }
}

enum ResolvedComputerUseAction {
    case leftClick(globalPoint: CGPoint)
    case doubleClick(globalPoint: CGPoint)
    case rightClick(globalPoint: CGPoint)
    case typeText(String)
    case keyPress(String)
    case keyCombo(key: String, modifiers: [String])
    case scroll(deltaX: Double, deltaY: Double)
    case drag(fromGlobalPoint: CGPoint, toGlobalPoint: CGPoint)
}

struct ComputerUseActionExecutionResult {
    let actionDescription: String
    let isSuccess: Bool
    let failureReason: String?
}

@MainActor
final class ComputerUseActionExecutor {
    func execute(actions: [ResolvedComputerUseAction]) -> [ComputerUseActionExecutionResult] {
        actions.map { execute(action: $0) }
    }

    private func execute(action: ResolvedComputerUseAction) -> ComputerUseActionExecutionResult {
        switch action {
        case .leftClick(let globalPoint):
            let postClickOutcome = postClick(at: globalPoint, button: .left, clickCount: 1)
            return result(
                description: "left click",
                didSucceed: postClickOutcome.success,
                failureReason: postClickOutcome.failureReasonIfFailed
                    ?? "Could not deliver left click (System Events or CGEvent)."
            )
        case .doubleClick(let globalPoint):
            let postClickOutcome = postClick(at: globalPoint, button: .left, clickCount: 2)
            return result(
                description: "double click",
                didSucceed: postClickOutcome.success,
                failureReason: postClickOutcome.failureReasonIfFailed
                    ?? "Could not deliver double click (System Events or CGEvent)."
            )
        case .rightClick(let globalPoint):
            let postClickOutcome = postClick(at: globalPoint, button: .right, clickCount: 1)
            return result(
                description: "right click",
                didSucceed: postClickOutcome.success,
                failureReason: postClickOutcome.failureReasonIfFailed
                    ?? "Could not post right-click event."
            )
        case .typeText(let text):
            let didSucceed = runSystemEventsScript(scriptBody: "keystroke \(quotedAppleScriptString(text))")
            return result(description: "type text", didSucceed: didSucceed, failureReason: "Could not type text with System Events.")
        case .keyPress(let key):
            let didSucceed = runSystemEventsScript(scriptBody: scriptBodyForKeyPress(key: key))
            return result(description: "key press", didSucceed: didSucceed, failureReason: "Could not press key with System Events.")
        case .keyCombo(let key, let modifiers):
            let didSucceed = runSystemEventsScript(scriptBody: scriptBodyForKeyCombo(key: key, modifiers: modifiers))
            return result(description: "key combo", didSucceed: didSucceed, failureReason: "Could not send key combo with System Events.")
        case .scroll(let deltaX, let deltaY):
            let didSucceed = postScroll(deltaX: deltaX, deltaY: deltaY)
            return result(description: "scroll", didSucceed: didSucceed, failureReason: "Could not post scroll event.")
        case .drag(let fromGlobalPoint, let toGlobalPoint):
            let didSucceed = postDrag(from: fromGlobalPoint, to: toGlobalPoint)
            return result(description: "drag", didSucceed: didSucceed, failureReason: "Could not post drag event.")
        }
    }

    private func result(description: String, didSucceed: Bool, failureReason: String) -> ComputerUseActionExecutionResult {
        ComputerUseActionExecutionResult(
            actionDescription: description,
            isSuccess: didSucceed,
            failureReason: didSucceed ? nil : failureReason
        )
    }

    /// After `CGWarpMouseCursorPosition`, log drift for diagnostics.
    /// Mapping / overlay code works in AppKit global coordinates (origin at desktop bottom-left),
    /// while synthetic HID posting is most reliable when using CoreGraphics desktop coordinates
    /// (origin at desktop top-left). We normalize both spaces here so drift checks are apples-to-apples.
    private struct PointerWarpPreparationResult {
        let clickPoint: CGPoint
        let alignmentWarning: String?
    }

    private let mouseWarpVerificationToleranceInPoints: CGFloat = 3.0

    /// Global desktop bounds across all screens in AppKit coordinates.
    /// Used to convert between AppKit-global and CoreGraphics-global coordinate spaces.
    private var globalDesktopBoundsInAppKitCoordinates: CGRect {
        NSScreen.screens.reduce(CGRect.null) { partialBounds, screen in
            partialBounds.union(screen.frame)
        }
    }

    /// Converts an AppKit global point (bottom-left desktop origin) to CoreGraphics global
    /// desktop coordinates (top-left desktop origin) for CG warp / HID event APIs.
    private func coreGraphicsGlobalPointFromAppKitGlobalPoint(_ appKitGlobalPoint: CGPoint) -> CGPoint {
        let desktopBounds = globalDesktopBoundsInAppKitCoordinates
        return CGPoint(
            x: appKitGlobalPoint.x,
            y: desktopBounds.maxY - appKitGlobalPoint.y
        )
    }

    /// Converts a CoreGraphics global point (top-left desktop origin) back to AppKit global
    /// coordinates (bottom-left desktop origin) for logging and comparison.
    private func appKitGlobalPointFromCoreGraphicsGlobalPoint(_ coreGraphicsGlobalPoint: CGPoint) -> CGPoint {
        let desktopBounds = globalDesktopBoundsInAppKitCoordinates
        return CGPoint(
            x: coreGraphicsGlobalPoint.x,
            y: desktopBounds.maxY - coreGraphicsGlobalPoint.y
        )
    }

    private func preparePointerForSyntheticMouseAction(desiredGlobalPoint: CGPoint) -> PointerWarpPreparationResult {
        let desiredCoreGraphicsPoint = coreGraphicsGlobalPointFromAppKitGlobalPoint(desiredGlobalPoint)
        CGWarpMouseCursorPosition(desiredCoreGraphicsPoint)
        usleep(120_000)

        let observedCoreGraphicsPoint = CGEvent(source: nil)?.location ?? desiredCoreGraphicsPoint
        let observedAppKitPoint = appKitGlobalPointFromCoreGraphicsGlobalPoint(observedCoreGraphicsPoint)
        let driftInPoints = hypot(
            observedAppKitPoint.x - desiredGlobalPoint.x,
            observedAppKitPoint.y - desiredGlobalPoint.y
        )
        if driftInPoints <= mouseWarpVerificationToleranceInPoints {
            return PointerWarpPreparationResult(clickPoint: desiredGlobalPoint, alignmentWarning: nil)
        }

        let warningMessage =
            "Pointer location differs from target by \(String(format: "%.1f", driftInPoints))pt " +
            "(targetAppKit \(desiredGlobalPoint), observedAppKit \(observedAppKitPoint), " +
            "targetCG \(desiredCoreGraphicsPoint), observedCG \(observedCoreGraphicsPoint)); " +
            "executing click at target."
        return PointerWarpPreparationResult(clickPoint: desiredGlobalPoint, alignmentWarning: warningMessage)
    }

    private func postClick(at globalPoint: CGPoint, button: CGMouseButton, clickCount: Int) -> (
        success: Bool,
        failureReasonIfFailed: String?
    ) {
        let activation = activateApplicationOwningFrontmostWindowAt(globalPoint)
        if activation.didFindWindow, let application = activation.targetApplication {
            print(
                "🖱️ Computer use click: activate pid=\(application.processIdentifier) " +
                "bundle=\(application.bundleIdentifier ?? "nil") ok=\(activation.didActivate)"
            )
        } else {
            print("🖱️ Computer use click: no on-screen window under point for activation")
        }
        // Browsers (Chromium, WebKit) often ignore System Events `click at` for in-page UI
        // even when AppleScript reports success. We post HID events first and convert from
        // AppKit-global points (mapping/overlay space) to CoreGraphics-global points for CG APIs.
        usleep(200_000)

        let pointerPreparation = preparePointerForSyntheticMouseAction(desiredGlobalPoint: globalPoint)
        if let alignmentWarning = pointerPreparation.alignmentWarning {
            print("⚠️ \(alignmentWarning)")
        }

        let clickPoint = pointerPreparation.clickPoint

        if postSyntheticMouseClickViaCGEvent(at: clickPoint, button: button, clickCount: clickCount) {
            print(
                "🖱️ Computer use click: delivered via CGEvent (cghidEventTap) at \(clickPoint)"
            )
            return (true, nil)
        }

        if button == .left {
            let coordinatePair = systemEventsClickCoordinatePair(globalPoint: globalPoint)
            let processNameForSystemEvents = activation.targetApplication
                .map { resolvedSystemEventsProcessName(for: $0) }
            if postClickViaSystemEvents(
                processName: processNameForSystemEvents,
                x: coordinatePair.x,
                y: coordinatePair.y,
                clickCount: clickCount
            ) {
                print("🖱️ Computer use click: delivered via System Events click at (fallback after CGEvent failure)")
                return (true, nil)
            }
            print("🖱️ Computer use click: both CGEvent and System Events failed")
            var failureReason =
                "Could not deliver click — CGEvent failed and System Events fallback failed."
            if let alignmentWarning = pointerPreparation.alignmentWarning {
                failureReason += " \(alignmentWarning)"
            }
            return (false, failureReason)
        }

        var failureReason = "Could not post click — CGEvent failed (no System Events fallback for non-left button)."
        if let alignmentWarning = pointerPreparation.alignmentWarning {
            failureReason += " \(alignmentWarning)"
        }
        return (false, failureReason)
    }

    /// System Events `click at` expects AppKit-style global points in this app’s existing flow.
    /// Multi-monitor points are already expressed in that space by `resolveGlobalPoint` in `CompanionManager`.
    private func systemEventsClickCoordinatePair(globalPoint: CGPoint) -> (x: Int, y: Int) {
        (Int(round(globalPoint.x)), Int(round(globalPoint.y)))
    }

    /// `tell process` must match the name shown in Activity Monitor; `localizedName` is usually correct.
    private func resolvedSystemEventsProcessName(for application: NSRunningApplication) -> String {
        if let bundleIdentifier = application.bundleIdentifier {
            switch bundleIdentifier {
            case "com.google.Chrome":
                return "Google Chrome"
            case "com.google.Chrome.canary":
                return "Google Chrome Canary"
            case "com.microsoft.edgemac":
                return "Microsoft Edge"
            case "com.apple.Safari":
                return "Safari"
            case "com.operasoftware.Opera":
                return "Opera"
            case "org.mozilla.firefox":
                return "Firefox"
            default:
                break
            }
        }
        if let localizedName = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !localizedName.isEmpty {
            return localizedName
        }
        return application.bundleURL?.deletingPathExtension().lastPathComponent ?? "Unknown"
    }

    /// Fallback when CGEvent posting fails: System Events `click at` scoped to the target process when known.
    private func postClickViaSystemEvents(processName: String?, x: Int, y: Int, clickCount: Int) -> Bool {
        let clickLines: [String] = (1...clickCount).map { index in
            var line = "click at {\(x), \(y)}"
            if index < clickCount {
                line += "\ndelay 0.07"
            }
            return line
        }
        let clickBlock = clickLines.joined(separator: "\n        ")

        let scriptSource: String
        if let processName, !processName.isEmpty {
            let escapedProcessName = quotedAppleScriptString(processName)
            scriptSource = """
            tell application "System Events"
                tell process \(escapedProcessName)
                    \(clickBlock)
                end tell
            end tell
            """
        } else {
            scriptSource = """
            tell application "System Events"
                \(clickBlock)
            end tell
            """
        }

        return runFullAppleScript(source: scriptSource)
    }

    private func postSyntheticMouseClickViaCGEvent(
        at globalPoint: CGPoint,
        button: CGMouseButton,
        clickCount: Int
    ) -> Bool {
        let mouseDownEventType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let mouseUpEventType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        let eventSource = CGEventSource(stateID: .hidSystemState)
        let coreGraphicsPoint = coreGraphicsGlobalPointFromAppKitGlobalPoint(globalPoint)
        for currentClickCount in 1...clickCount {
            guard let mouseDownEvent = CGEvent(
                    mouseEventSource: eventSource,
                    mouseType: mouseDownEventType,
                    mouseCursorPosition: coreGraphicsPoint,
                    mouseButton: button
                ),
                let mouseUpEvent = CGEvent(
                    mouseEventSource: eventSource,
                    mouseType: mouseUpEventType,
                    mouseCursorPosition: coreGraphicsPoint,
                    mouseButton: button
                ) else {
                return false
            }
            mouseDownEvent.setIntegerValueField(.mouseEventClickState, value: Int64(currentClickCount))
            mouseUpEvent.setIntegerValueField(.mouseEventClickState, value: Int64(currentClickCount))
            mouseDownEvent.post(tap: .cghidEventTap)
            mouseUpEvent.post(tap: .cghidEventTap)
            usleep(80_000)
        }
        return true
    }

    private func runFullAppleScript(source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else {
            return false
        }
        var scriptError: NSDictionary?
        _ = script.executeAndReturnError(&scriptError)
        if let error = scriptError {
            print("⚠️ AppleScript error: \(error)")
            return false
        }
        return true
    }

    /// Walks on-screen windows front-to-back and activates the app that owns the first window
    /// whose bounds contain `globalPoint` (AppKit global coordinates), skipping this app’s windows.
    private func activateApplicationOwningFrontmostWindowAt(_ globalPoint: CGPoint) -> (
        didFindWindow: Bool,
        targetApplication: NSRunningApplication?,
        didActivate: Bool
    ) {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [NSDictionary] else {
            return (false, nil, false)
        }

        for windowInfo in windowList {
            guard let pidNumber = windowInfo[kCGWindowOwnerPID] as? NSNumber else { continue }
            let windowOwnerProcessIdentifier = pidNumber.int32Value
            if windowOwnerProcessIdentifier == ownProcessIdentifier { continue }

            if let alphaNumber = windowInfo[kCGWindowAlpha] as? NSNumber, alphaNumber.doubleValue < 0.05 {
                continue
            }

            guard let boundsDict = windowInfo[kCGWindowBounds] as? [String: Any] else { continue }
            let originX = CGFloat((boundsDict["X"] as? NSNumber)?.doubleValue ?? 0)
            let originY = CGFloat((boundsDict["Y"] as? NSNumber)?.doubleValue ?? 0)
            let sizeWidth = CGFloat((boundsDict["Width"] as? NSNumber)?.doubleValue ?? 0)
            let sizeHeight = CGFloat((boundsDict["Height"] as? NSNumber)?.doubleValue ?? 0)
            let windowBounds = CGRect(x: originX, y: originY, width: sizeWidth, height: sizeHeight)
            guard sizeWidth >= 2, sizeHeight >= 2 else { continue }
            guard windowBounds.contains(globalPoint) else { continue }

            guard let application = NSRunningApplication(processIdentifier: windowOwnerProcessIdentifier) else {
                continue
            }
            let didActivate = application.activate(options: [.activateIgnoringOtherApps])
            return (true, application, didActivate)
        }

        return (false, nil, false)
    }

    private func postScroll(deltaX: Double, deltaY: Double) -> Bool {
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else {
            return false
        }
        scrollEvent.post(tap: .cghidEventTap)
        return true
    }

    private func postDrag(from: CGPoint, to: CGPoint) -> Bool {
        let activation = activateApplicationOwningFrontmostWindowAt(from)
        if activation.didFindWindow, let application = activation.targetApplication {
            print(
                "🖱️ Computer use drag: activate pid=\(application.processIdentifier) " +
                "bundle=\(application.bundleIdentifier ?? "nil") ok=\(activation.didActivate) tap=cghidEventTap"
            )
        }
        usleep(175_000)

        let fromPreparation = preparePointerForSyntheticMouseAction(desiredGlobalPoint: from)
        if let alignmentWarning = fromPreparation.alignmentWarning {
            print("⚠️ Computer use drag start: \(alignmentWarning)")
        }
        let dragStartPoint = fromPreparation.clickPoint

        let toPreparation = preparePointerForSyntheticMouseAction(desiredGlobalPoint: to)
        if let alignmentWarning = toPreparation.alignmentWarning {
            print("⚠️ Computer use drag end: \(alignmentWarning)")
        }
        let dragEndPoint = toPreparation.clickPoint

        // Return to drag start before mouse-down (second prepare moved the cursor to `to`).
        CGWarpMouseCursorPosition(coreGraphicsGlobalPointFromAppKitGlobalPoint(dragStartPoint))
        usleep(90_000)

        let eventSource = CGEventSource(stateID: .hidSystemState)
        let dragStartCoreGraphicsPoint = coreGraphicsGlobalPointFromAppKitGlobalPoint(dragStartPoint)
        let dragEndCoreGraphicsPoint = coreGraphicsGlobalPointFromAppKitGlobalPoint(dragEndPoint)
        guard let mouseDownEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: dragStartCoreGraphicsPoint, mouseButton: .left),
              let mouseDraggedEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: dragEndCoreGraphicsPoint, mouseButton: .left),
              let mouseUpEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: dragEndCoreGraphicsPoint, mouseButton: .left) else {
            return false
        }
        mouseDownEvent.post(tap: .cghidEventTap)
        usleep(40_000)
        mouseDraggedEvent.post(tap: .cghidEventTap)
        usleep(40_000)
        mouseUpEvent.post(tap: .cghidEventTap)
        return true
    }

    private func runSystemEventsScript(scriptBody: String) -> Bool {
        let source = """
        tell application "System Events"
            \(scriptBody)
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            return false
        }
        var scriptError: NSDictionary?
        _ = script.executeAndReturnError(&scriptError)
        return scriptError == nil
    }

    private func scriptBodyForKeyPress(key: String) -> String {
        if let keyCode = specialKeyCode(for: key) {
            return "key code \(keyCode)"
        }
        return "keystroke \(quotedAppleScriptString(key))"
    }

    private func scriptBodyForKeyCombo(key: String, modifiers: [String]) -> String {
        let modifierTokens = modifiers
            .map { $0.lowercased() }
            .compactMap { normalizedModifier in
                switch normalizedModifier {
                case "command", "cmd":
                    return "command down"
                case "shift":
                    return "shift down"
                case "option", "alt":
                    return "option down"
                case "control", "ctrl":
                    return "control down"
                default:
                    return nil
                }
            }
            .joined(separator: ", ")

        let baseAction: String
        if let keyCode = specialKeyCode(for: key) {
            baseAction = "key code \(keyCode)"
        } else {
            baseAction = "keystroke \(quotedAppleScriptString(key))"
        }

        guard !modifierTokens.isEmpty else {
            return baseAction
        }
        return "\(baseAction) using {\(modifierTokens)}"
    }

    private func specialKeyCode(for key: String) -> Int? {
        switch key.lowercased() {
        case "return", "enter":
            return 36
        case "tab":
            return 48
        case "space":
            return 49
        case "escape", "esc":
            return 53
        case "delete", "backspace":
            return 51
        default:
            return nil
        }
    }

    private func quotedAppleScriptString(_ rawText: String) -> String {
        let escaped = rawText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
