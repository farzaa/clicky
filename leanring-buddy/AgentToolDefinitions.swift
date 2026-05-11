//
//  AgentToolDefinitions.swift
//  leanring-buddy
//
//  Tool schemas and parsed-block types for the Anthropic tool-use agent
//  loop. See docs/agent-loop-tool-use-migration.md.
//

import Foundation
import CoreGraphics

/// JSON-Schema description of one tool sent to the Anthropic API. The
/// `inputSchema` value must serialize to a valid JSON Schema object.
struct AgentToolDefinition {
    let name: String
    let description: String
    let inputSchema: [String: Any]

    var apiPayload: [String: Any] {
        return [
            "name": name,
            "description": description,
            "input_schema": inputSchema
        ]
    }
}

/// One tool_use block parsed from a Claude response. The `input` dict comes
/// straight from the API and is decoded into a typed `AgentToolCall` by
/// `AgentToolDefinitions.decodeToolCall(...)`.
struct AgentToolUseBlock {
    let toolUseID: String
    let toolName: String
    let inputArguments: [String: Any]
}

/// Direction the user wants to scroll, in viewport-content terms. "down"
/// reveals what was below the fold; "up" reveals what was above; etc.
enum AgentScrollDirection: String {
    case up
    case down
    case left
    case right

    /// Unit vector describing where the on-screen cursor companion should
    /// briefly nudge during the scroll, matching the user's mental model of
    /// dragging the scrollbar in that direction.
    var visualHintUnitVector: CGVector {
        switch self {
        case .up:    return CGVector(dx: 0, dy: -1)
        case .down:  return CGVector(dx: 0, dy: 1)
        case .left:  return CGVector(dx: -1, dy: 0)
        case .right: return CGVector(dx: 1, dy: 0)
        }
    }
}

/// How far to scroll in one call. Maps to a fixed line count when we post
/// the scroll wheel event — small = ~3 lines, medium = ~10 lines, large =
/// ~30 lines (roughly small step / half page / full page).
enum AgentScrollAmount: String {
    case small
    case medium
    case large

    var scrollLineMagnitude: Int32 {
        switch self {
        case .small:  return 3
        case .medium: return 10
        case .large:  return 30
        }
    }
}

/// Strongly-typed representation of one tool call after decoding. The agent
/// loop dispatches on this enum instead of switching on `toolName` everywhere.
enum AgentToolCall {
    case pointAtElement(coordinate: CGPoint, label: String?, screen: Int?)
    case clickElement(coordinate: CGPoint, label: String?, screen: Int?)
    case typeText(String)
    case pressKeystroke(spec: String)
    case scroll(direction: AgentScrollDirection, amount: AgentScrollAmount)
    case openURL(String)
    case openApplication(nameOrBundleIdentifier: String)
    case switchSpace(direction: CompanionComputerController.SpaceSwitchDirection)
    case showMissionControl
    case navigateBrowserToURL(String)
    case openNewBrowserTab(initialURL: String?)
    case closeCurrentBrowserTab
    case switchBrowserTab(Int)
    case browserHistoryBack
    case browserHistoryForward
    case mediaControl(CompanionMediaControlCommand)
    case bailOut(reason: String)
}

enum AgentToolDefinitions {

    /// Single source of truth for the tool catalog exposed to Claude. Order
    /// matches the documentation order in the system prompt so the model's
    /// tool-call distribution stays interpretable.
    static let toolCatalog: [AgentToolDefinition] = [
        pointAtElementTool,
        clickElementTool,
        typeTextTool,
        pressKeystrokeTool,
        scrollTool,
        openURLTool,
        openApplicationTool,
        switchSpaceTool,
        showMissionControlTool,
        navigateBrowserTool,
        openNewTabTool,
        closeTabTool,
        switchTabTool,
        browserBackTool,
        browserForwardTool,
        mediaControlTool,
        bailOutTool
    ]

    static var apiPayloadList: [[String: Any]] {
        return toolCatalog.map { $0.apiPayload }
    }

    // MARK: - Tool definitions

    private static let coordinateSchemaProperties: [String: Any] = [
        "x": [
            "type": "integer",
            "description": "Pixel x-coordinate in the most recent screenshot's coordinate space. Origin (0,0) is the top-left of the image; x increases to the right."
        ],
        "y": [
            "type": "integer",
            "description": "Pixel y-coordinate in the most recent screenshot's coordinate space. y increases downward."
        ],
        "label": [
            "type": "string",
            "description": "1–3 word description of the target element, e.g. \"save button\" or \"search field\"."
        ],
        "screen": [
            "type": "integer",
            "description": "Optional 1-based screen index when the target is on a different monitor than the cursor's primary screen. Match the \"screen N\" number from the image label."
        ]
    ]

    private static let pointAtElementTool = AgentToolDefinition(
        name: "point_at_element",
        description: "Fly the blue cursor companion to a UI element on screen so the user can see what you're referring to. Use when the user asks where something is or how to do something — pointing makes the help concrete. Do not call this tool when pointing wouldn't help (general knowledge questions, screen not relevant). At most one point_at_element call per turn.",
        inputSchema: [
            "type": "object",
            "properties": coordinateSchemaProperties,
            "required": ["x", "y"]
        ]
    )

    private static let clickElementTool = AgentToolDefinition(
        name: "click_element",
        description: "Click a UI element on screen. Use only when (a) the target is page content (not browser chrome — for the address bar / tabs use the navigate / tab tools instead), AND (b) you can identify the target confidently from the current screenshot. Coordinates are pixels in the latest screenshot. Clicks try AXPress first (no cursor move) and fall back to a coordinate event that restores the hardware cursor.",
        inputSchema: [
            "type": "object",
            "properties": coordinateSchemaProperties,
            "required": ["x", "y"]
        ]
    )

    private static let typeTextTool = AgentToolDefinition(
        name: "type_text",
        description: "Type a string into the currently focused field. Only types literal characters — cannot send special keys (backspace, return, modifier shortcuts). Use press_keystroke for those. Newlines: include a literal \\n in the string.",
        inputSchema: [
            "type": "object",
            "properties": [
                "text": [
                    "type": "string",
                    "description": "The literal text to type. Use \\n for newline."
                ]
            ],
            "required": ["text"]
        ]
    )

    private static let scrollTool = AgentToolDefinition(
        name: "scroll",
        description: "Scroll the content under the cursor in a given direction. \"down\" reveals content below the fold; \"up\" reveals content above; \"left\"/\"right\" pan a horizontally-scrollable view. The scroll lands wherever the hardware cursor currently is — to scroll a specific pane (sidebar, embedded list), call point_at_element first to move the cursor there, then call scroll on the next step. Side-effect: the blue cursor companion briefly nudges in the scroll direction so the user sees what's happening.",
        inputSchema: [
            "type": "object",
            "properties": [
                "direction": [
                    "type": "string",
                    "enum": ["up", "down", "left", "right"],
                    "description": "Direction to scroll. \"down\" = reveal what's below the current viewport."
                ],
                "amount": [
                    "type": "string",
                    "enum": ["small", "medium", "large"],
                    "description": "small ≈ 3 lines (one notch); medium ≈ half a page; large ≈ full page. Default medium."
                ]
            ],
            "required": ["direction"]
        ]
    )

    private static let pressKeystrokeTool = AgentToolDefinition(
        name: "press_keystroke",
        description: "Press a single keystroke or modifier shortcut. Use for special keys (backspace, return, escape, tab, arrows, home/end, page up/down, function keys) or modifier combos (cmd+a, cmd+shift+z, ctrl+space). Letters and digits are also valid spec values. Combine modifiers with +. For browser navigation, prefer navigate_browser / open_new_tab / etc — they're more reliable.",
        inputSchema: [
            "type": "object",
            "properties": [
                "spec": [
                    "type": "string",
                    "description": "Case-insensitive keystroke specification. Examples: \"return\", \"backspace\", \"escape\", \"cmd+a\", \"cmd+shift+z\", \"ctrl+space\", \"left\", \"f5\"."
                ]
            ],
            "required": ["spec"]
        ]
    )

    private static let openURLTool = AgentToolDefinition(
        name: "open_url",
        description: "Open a URL in the user's default browser. Atomic and reliable: routes through NSWorkspace, which handles activating the browser, creating a tab, and loading the URL — works regardless of which app is currently focused, and even when no browser is running yet. STRONGLY PREFER this for any \"open / go to / navigate to <site>\" request. Use navigate_browser only when you specifically need to load the URL into the *currently focused* browser tab (rare).",
        inputSchema: [
            "type": "object",
            "properties": [
                "url": [
                    "type": "string",
                    "description": "URL to open. Bare hosts like \"drive.google.com\" are accepted — the scheme (https://) is added automatically when missing. Also supports mailto:, tel:, etc."
                ]
            ],
            "required": ["url"]
        ]
    )

    private static let openApplicationTool = AgentToolDefinition(
        name: "open_app",
        description: "Launch or activate a native macOS application via NSWorkspace. Atomic and reliable — replaces clicking dock icons or driving Spotlight via cmd+space + type + return, both of which can land in the wrong place. Accepts either a friendly app name (\"Spotify\", \"Visual Studio Code\", \"Slack\") or a bundle identifier (\"com.spotify.client\"). If the app is already running it's brought to the front; otherwise it's launched. Allow ~1.5s for activation before the next screenshot.",
        inputSchema: [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "Application name (e.g. \"Spotify\", \"Visual Studio Code\") or bundle identifier (e.g. \"com.spotify.client\")."
                ]
            ],
            "required": ["name"]
        ]
    )

    private static let switchSpaceTool = AgentToolDefinition(
        name: "switch_space",
        description: "Switch to an adjacent macOS Space (virtual desktop). Posts the system-default ctrl+→ / ctrl+← shortcut. Use this — not press_keystroke('cmd+space') (which is Spotlight) or press_keystroke('space') (which is the spacebar) — when the user asks to switch desktops / spaces / virtual screens. For \"go to my coding space\" or similar named targets, call this once with direction=next or previous, then re-observe; chain more calls if the destination wasn't reached. If the user asks to see all spaces, use show_mission_control instead.",
        inputSchema: [
            "type": "object",
            "properties": [
                "direction": [
                    "type": "string",
                    "enum": ["next", "previous"],
                    "description": "next slides one Space to the right; previous slides one Space to the left."
                ]
            ],
            "required": ["direction"]
        ]
    )

    private static let showMissionControlTool = AgentToolDefinition(
        name: "show_mission_control",
        description: "Open macOS Mission Control so all Spaces and windows are visible at once. Posts the system-default ctrl+↑ shortcut. Use when the user wants to see all their Spaces / desktops, or when you need a visual to pick which Space to switch to next (you can call this, observe the new screenshot, then click_element on the target Space thumbnail).",
        inputSchema: [
            "type": "object",
            "properties": [:] as [String: Any]
        ]
    )

    private static let navigateBrowserTool = AgentToolDefinition(
        name: "navigate_browser",
        description: "Navigate the CURRENTLY FOCUSED browser tab to a URL via cmd+L + type + return keystrokes. Use only when the user specifically wants to replace the current tab (\"in this tab\", \"replace this page\"). For any other \"go to / open <site>\" request, USE open_url INSTEAD — open_url is keystroke-free, so it can't be intercepted by Chrome extension shortcuts or other system keybindings.",
        inputSchema: [
            "type": "object",
            "properties": [
                "url": [
                    "type": "string",
                    "description": "URL to navigate to. Can be a bare host like \"drive.google.com\" — the browser auto-resolves it."
                ]
            ],
            "required": ["url"]
        ]
    )

    private static let openNewTabTool = AgentToolDefinition(
        name: "open_new_tab",
        description: "Open a new tab in the FOCUSED browser via cmd+T + (optional) type + return keystrokes. Use only when the user specifically asks for a new tab AND a browser is the frontmost app. For \"open <site>\" requests where you just want the URL to load somewhere, USE open_url INSTEAD — it routes through macOS, so it isn't blocked by Chrome extension shortcuts that intercept cmd+T or cmd+L.",
        inputSchema: [
            "type": "object",
            "properties": [
                "url": [
                    "type": "string",
                    "description": "Optional URL to load in the new tab."
                ]
            ]
        ]
    )

    private static let closeTabTool = AgentToolDefinition(
        name: "close_tab",
        description: "Close the currently focused browser tab.",
        inputSchema: [
            "type": "object",
            "properties": [:] as [String: Any]
        ]
    )

    private static let switchTabTool = AgentToolDefinition(
        name: "switch_tab",
        description: "Switch to the Nth tab in the focused browser window (1-based, leftmost is 1, max 9).",
        inputSchema: [
            "type": "object",
            "properties": [
                "index": [
                    "type": "integer",
                    "description": "Tab index, 1 through 9.",
                    "minimum": 1,
                    "maximum": 9
                ]
            ],
            "required": ["index"]
        ]
    )

    private static let browserBackTool = AgentToolDefinition(
        name: "browser_back",
        description: "Navigate the browser one step back in history (cmd+left arrow).",
        inputSchema: [
            "type": "object",
            "properties": [:] as [String: Any]
        ]
    )

    private static let browserForwardTool = AgentToolDefinition(
        name: "browser_forward",
        description: "Navigate the browser one step forward in history (cmd+right arrow).",
        inputSchema: [
            "type": "object",
            "properties": [:] as [String: Any]
        ]
    )

    private static let mediaControlTool = AgentToolDefinition(
        name: "media_control",
        description: "Send a global media-key event — works whether or not a music app is focused. Use for pause/play/skip requests in preference to clicking a music app's UI.",
        inputSchema: [
            "type": "object",
            "properties": [
                "command": [
                    "type": "string",
                    "enum": ["play_pause", "next", "previous"],
                    "description": "play_pause toggles playback; next skips forward one track; previous goes back one track."
                ]
            ],
            "required": ["command"]
        ]
    )

    private static let bailOutTool = AgentToolDefinition(
        name: "bail_out",
        description: "Use when you're stuck and need user input. Examples: the previous action didn't produce the screen change you expected and you don't have a different approach, the target element is genuinely ambiguous and you can't tell which one to click, the task requires a destructive or sensitive action you shouldn't auto-execute. Calling this tool ends the turn — speak a clear text block explaining what you need from the user.",
        inputSchema: [
            "type": "object",
            "properties": [
                "reason": [
                    "type": "string",
                    "description": "Short explanation of why you're stuck or what you need from the user."
                ]
            ],
            "required": ["reason"]
        ]
    )

    // MARK: - Decode

    /// Converts a raw tool_use block from the API into a typed `AgentToolCall`.
    /// Returns nil if the tool name is unknown or required arguments are
    /// missing — callers should report a tool_result error so the model can
    /// self-correct in the next turn.
    static func decodeToolCall(from toolUseBlock: AgentToolUseBlock) -> AgentToolCall? {
        switch toolUseBlock.toolName {
        case "point_at_element":
            guard let coordinate = decodeCoordinate(from: toolUseBlock.inputArguments) else { return nil }
            return .pointAtElement(
                coordinate: coordinate,
                label: decodeOptionalString(toolUseBlock.inputArguments["label"]),
                screen: decodeOptionalInt(toolUseBlock.inputArguments["screen"])
            )
        case "click_element":
            guard let coordinate = decodeCoordinate(from: toolUseBlock.inputArguments) else { return nil }
            return .clickElement(
                coordinate: coordinate,
                label: decodeOptionalString(toolUseBlock.inputArguments["label"]),
                screen: decodeOptionalInt(toolUseBlock.inputArguments["screen"])
            )
        case "type_text":
            guard let textValue = toolUseBlock.inputArguments["text"] as? String else { return nil }
            // Same \\n → \n unescape that the legacy text-tag parser did.
            let unescaped = textValue.replacingOccurrences(of: "\\n", with: "\n")
            return .typeText(unescaped)
        case "press_keystroke":
            guard let specValue = toolUseBlock.inputArguments["spec"] as? String else { return nil }
            return .pressKeystroke(spec: specValue)
        case "scroll":
            guard let directionRawValue = toolUseBlock.inputArguments["direction"] as? String,
                  let scrollDirection = AgentScrollDirection(rawValue: directionRawValue.lowercased()) else {
                return nil
            }
            let amountRawValue = (toolUseBlock.inputArguments["amount"] as? String)?.lowercased() ?? "medium"
            let scrollAmount = AgentScrollAmount(rawValue: amountRawValue) ?? .medium
            return .scroll(direction: scrollDirection, amount: scrollAmount)
        case "open_url":
            guard let urlValue = toolUseBlock.inputArguments["url"] as? String,
                  !urlValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .openURL(urlValue.trimmingCharacters(in: .whitespacesAndNewlines))
        case "open_app":
            guard let nameValue = toolUseBlock.inputArguments["name"] as? String,
                  !nameValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .openApplication(
                nameOrBundleIdentifier: nameValue.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case "switch_space":
            guard let directionValue = toolUseBlock.inputArguments["direction"] as? String,
                  let parsedDirection = CompanionComputerController.SpaceSwitchDirection(
                      rawValue: directionValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                  ) else { return nil }
            return .switchSpace(direction: parsedDirection)
        case "show_mission_control":
            return .showMissionControl
        case "navigate_browser":
            guard let urlValue = toolUseBlock.inputArguments["url"] as? String,
                  !urlValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .navigateBrowserToURL(urlValue.trimmingCharacters(in: .whitespacesAndNewlines))
        case "open_new_tab":
            let initialURL = decodeOptionalString(toolUseBlock.inputArguments["url"])
            return .openNewBrowserTab(initialURL: initialURL)
        case "close_tab":
            return .closeCurrentBrowserTab
        case "switch_tab":
            guard let indexValue = decodeOptionalInt(toolUseBlock.inputArguments["index"]),
                  indexValue >= 1, indexValue <= 9 else { return nil }
            return .switchBrowserTab(indexValue)
        case "browser_back":
            return .browserHistoryBack
        case "browser_forward":
            return .browserHistoryForward
        case "media_control":
            guard let rawCommand = toolUseBlock.inputArguments["command"] as? String,
                  let mediaCommand = CompanionMediaControlCommand(controlTagValue: rawCommand) else { return nil }
            return .mediaControl(mediaCommand)
        case "bail_out":
            let reason = decodeOptionalString(toolUseBlock.inputArguments["reason"]) ?? "no reason given"
            return .bailOut(reason: reason)
        default:
            return nil
        }
    }

    private static func decodeCoordinate(from inputArguments: [String: Any]) -> CGPoint? {
        guard let xValue = decodeOptionalInt(inputArguments["x"]),
              let yValue = decodeOptionalInt(inputArguments["y"]) else {
            return nil
        }
        return CGPoint(x: xValue, y: yValue)
    }

    private static func decodeOptionalString(_ rawValue: Any?) -> String? {
        guard let stringValue = rawValue as? String else { return nil }
        let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decodeOptionalInt(_ rawValue: Any?) -> Int? {
        if let intValue = rawValue as? Int { return intValue }
        if let doubleValue = rawValue as? Double { return Int(doubleValue) }
        if let stringValue = rawValue as? String, let parsed = Int(stringValue) {
            return parsed
        }
        return nil
    }
}
