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
    case fillTextField(coordinate: CGPoint, label: String?, screen: Int?, text: String, clearExisting: Bool)
    case fillAndSubmit(coordinate: CGPoint, label: String?, screen: Int?, text: String, clearExisting: Bool, submitKeystrokeSpec: String)
    case performActionSequence([AgentActionSequenceStep])
    case pressKeystroke(spec: String)
    case scroll(direction: AgentScrollDirection, amount: AgentScrollAmount)
    case waitForSeconds(Int)
    case openURL(String)
    case openApplication(nameOrBundleIdentifier: String)
    case getForegroundDocumentContext
    case openLocalPath(path: String, applicationNameOrBundleIdentifier: String?, preferNewApplicationInstance: Bool)
    case runLocalCommand(workingDirectoryPath: String, command: String, timeoutSeconds: Int)
    case createZipArchive(outputPath: String, entries: [AgentZipArchiveEntry])
    case chooseFileOrFolder(path: String)
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
    /// Anthropic's predefined memory tool (memory_20250818). The input dict
    /// is passed straight through to `DotMemoryStore.dispatch` — Anthropic
    /// owns the schema, we just execute against ~/Library/Application
    /// Support/Dot/memories/.
    case memory(input: [String: Any])
}

enum AgentActionSequenceStep {
    case clickElement(coordinate: CGPoint, label: String?, screen: Int?)
    case typeText(String)
    case pressKeystroke(spec: String)
    case pauseForMilliseconds(Int)
    case scroll(direction: AgentScrollDirection, amount: AgentScrollAmount)
}

struct AgentZipArchiveEntry {
    let sourcePath: String
    let archivePath: String
}

enum AgentToolDefinitions {

    /// Single source of truth for the tool catalog exposed to Claude. Order
    /// matches the documentation order in the system prompt so the model's
    /// tool-call distribution stays interpretable.
    static let toolCatalog: [AgentToolDefinition] = [
        pointAtElementTool,
        clickElementTool,
        typeTextTool,
        fillTextFieldTool,
        fillAndSubmitTool,
        performActionSequenceTool,
        pressKeystrokeTool,
        scrollTool,
        waitForSecondsTool,
        openURLTool,
        openApplicationTool,
        getForegroundDocumentContextTool,
        openLocalPathTool,
        runLocalCommandTool,
        createZipArchiveTool,
        chooseFileOrFolderTool,
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

    /// Predefined Anthropic tools (declared by `type` rather than a custom
    /// `input_schema`). Currently just the memory tool. Anthropic owns the
    /// command schema; the model has been trained against it directly, so we
    /// intentionally don't wrap it in `AgentToolDefinition`.
    private static let predefinedToolPayloads: [[String: Any]] = [
        [
            "type": "memory_20250818",
            "name": "memory"
        ]
    ]

    static var apiPayloadList: [[String: Any]] {
        return apiPayloadList(includingMemoryTool: true)
    }

    static func apiPayloadList(includingMemoryTool shouldIncludeMemoryTool: Bool) -> [[String: Any]] {
        // Predefined tools first so the cache_control marker that
        // `runAgentTurnWithToolUse` adds to the LAST entry lands on a
        // custom tool (well-tested combo), not on a predefined tool.
        let customToolPayloads = toolCatalog.map { $0.apiPayload }
        guard shouldIncludeMemoryTool else {
            return customToolPayloads
        }
        return predefinedToolPayloads + customToolPayloads
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
        description: "Click a UI element on screen. Use only when (a) the target is page content (not browser chrome — for the address bar / tabs use the navigate / tab tools instead), AND (b) you can identify the target confidently from the current screenshot. Coordinates are pixels in the latest screenshot. Clicks send real coordinate mouse events and restore the hardware cursor afterward, so web canvases such as Google Slides receive an actual mouseDown/mouseUp sequence.",
        inputSchema: [
            "type": "object",
            "properties": coordinateSchemaProperties,
            "required": ["x", "y"]
        ]
    )

    private static let typeTextTool = AgentToolDefinition(
        name: "type_text",
        description: "Type a string into the currently focused field. Only types literal characters — cannot send special keys (backspace, return, modifier shortcuts). Use press_keystroke for those. Newlines: include a literal \\n in the string. PREFER fill_text_field instead when the goal is 'put text X into field Y' — it handles the click + focus + type sequence atomically.",
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

    private static let fillAndSubmitTool = AgentToolDefinition(
        name: "fill_and_submit",
        description: "Atomically click a text field, type into it, and press a submit keystroke (default: return) — all in ONE tool call. This DOES SUBMIT — only use when the user explicitly asked you to send the message, submit the form, run the search, etc. For chat apps like Slack/Discord/iMessage this presses return which posts the message. For URL bars and form fields it confirms. If the user just wants to draft text without sending, use fill_text_field instead. Internally: same hover-primed click + focus settle + optional cmd+a clear + type sequence as fill_text_field, then 100 ms settle, then the submit keystroke.",
        inputSchema: [
            "type": "object",
            "properties": [
                "x": [
                    "type": "integer",
                    "description": "Pixel x-coordinate of the text field in the most recent screenshot."
                ],
                "y": [
                    "type": "integer",
                    "description": "Pixel y-coordinate of the text field in the most recent screenshot. Aim for the CENTER of the input area, not the header/toolbar above it."
                ],
                "label": [
                    "type": "string",
                    "description": "1–3 word description of the field, e.g. \"message input\", \"search box\"."
                ],
                "screen": [
                    "type": "integer",
                    "description": "Optional 1-based screen index if the field is on a non-primary monitor."
                ],
                "text": [
                    "type": "string",
                    "description": "Literal text to type before submitting. Use \\n for newline within the body."
                ],
                "clear_existing": [
                    "type": "boolean",
                    "description": "If true, select-all (cmd+a) before typing so the new text replaces any existing content. Default false."
                ],
                "submit_keystroke": [
                    "type": "string",
                    "description": "Keystroke spec to press after typing. Default \"return\" (works for Slack/Discord/iMessage send, search bars, most forms). Use \"cmd+return\" for apps that require it (some email clients). Same spec format as press_keystroke."
                ]
            ],
            "required": ["x", "y", "text"]
        ]
    )

    private static let fillTextFieldTool = AgentToolDefinition(
        name: "fill_text_field",
        description: "Atomically click a text field and type into it in ONE tool call. STRONGLY PREFER this over click_element + type_text whenever the goal is 'put text X into field Y' WITHOUT submitting. Internally: hover-primes the target, clicks with a realistic press duration to focus the field (works on Slack/Discord/VS Code where naive synthetic clicks don't transfer focus), optionally clears existing content with cmd+a, waits briefly for focus to settle, then types the text. Does NOT press enter — use fill_and_submit if the goal is to send or submit. Coordinates are pixels in the latest screenshot.",
        inputSchema: [
            "type": "object",
            "properties": [
                "x": [
                    "type": "integer",
                    "description": "Pixel x-coordinate of the text field in the most recent screenshot."
                ],
                "y": [
                    "type": "integer",
                    "description": "Pixel y-coordinate of the text field in the most recent screenshot. Aim for the CENTER of the input area, not the header/toolbar above it."
                ],
                "label": [
                    "type": "string",
                    "description": "1–3 word description of the field, e.g. \"message input\", \"search box\"."
                ],
                "screen": [
                    "type": "integer",
                    "description": "Optional 1-based screen index if the field is on a non-primary monitor."
                ],
                "text": [
                    "type": "string",
                    "description": "Literal text to type after focusing. Use \\n for newline. Does NOT press enter at the end — call press_keystroke('return') separately if you want to submit."
                ],
                "clear_existing": [
                    "type": "boolean",
                    "description": "If true, select-all (cmd+a) before typing so the new text replaces any existing content. Default false (append/insert at cursor)."
                ]
            ],
            "required": ["x", "y", "text"]
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

    private static let performActionSequenceTool = AgentToolDefinition(
        name: "perform_action_sequence",
        description: "Execute 1-6 deterministic local UI actions serially before the next screenshot. Use this to chunk through actions that do NOT require seeing the intermediate screen: repeated scrolls; click a known field then type; type then press return; cmd+a then type; tab/tab/return keyboard flows. Do NOT use across a visual decision point, page navigation, modal appearance, unknown layout shift, purchase/checkout/send confirmation, or anything where action N+1 depends on seeing what action N changed. Never repeat the exact same mutating sequence twice in a row; observe, choose a different tool, wait, or bail out instead. Prefer fill_text_field/fill_and_submit for a single known text field; use this for heterogeneous or repeated primitives.",
        inputSchema: [
            "type": "object",
            "properties": [
                "actions": [
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 6,
                    "description": "Ordered primitive actions to execute before the next screenshot. Stop at the next visual decision point.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "type": [
                                "type": "string",
                                "enum": ["click_element", "type_text", "press_keystroke", "pause", "scroll"],
                                "description": "Primitive action type."
                            ],
                            "x": [
                                "type": "integer",
                                "description": "For click_element: pixel x-coordinate in the most recent screenshot."
                            ],
                            "y": [
                                "type": "integer",
                                "description": "For click_element: pixel y-coordinate in the most recent screenshot."
                            ],
                            "label": [
                                "type": "string",
                                "description": "For click_element: 1-3 word target label."
                            ],
                            "screen": [
                                "type": "integer",
                                "description": "For click_element: optional 1-based screen index."
                            ],
                            "text": [
                                "type": "string",
                                "description": "For type_text: literal text to type. Use \\n for newline."
                            ],
                            "spec": [
                                "type": "string",
                                "description": "For press_keystroke: key spec like return, tab, escape, cmd+a, cmd+shift+z."
                            ],
                            "milliseconds": [
                                "type": "integer",
                                "description": "For pause: short fixed wait in milliseconds. Clamped to 0-1500."
                            ],
                            "direction": [
                                "type": "string",
                                "enum": ["up", "down", "left", "right"],
                                "description": "For scroll: direction to scroll."
                            ],
                            "amount": [
                                "type": "string",
                                "enum": ["small", "medium", "large"],
                                "description": "For scroll: default medium."
                            ]
                        ],
                        "required": ["type"]
                    ]
                ]
            ],
            "required": ["actions"]
        ]
    )

    private static let waitForSecondsTool = AgentToolDefinition(
        name: "wait_for_seconds",
        description: "Wait briefly before observing the screen again. Use for page loads, uploads, autograders, app launches, modal transitions, or any job whose result is expected to appear after a short delay. Prefer this over repeatedly clicking refresh or guessing that an async operation is done.",
        inputSchema: [
            "type": "object",
            "properties": [
                "seconds": [
                    "type": "integer",
                    "description": "Seconds to wait. Keep it short; values are clamped by the app to 1-30 seconds."
                ]
            ],
            "required": ["seconds"]
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

    private static let getForegroundDocumentContextTool = AgentToolDefinition(
        name: "get_foreground_document_context",
        description: "Return best-effort context for the user's frontmost app/document: app name, window title, current browser URL when available, AX document URL/path when available, and selected text when available. Use when the user says \"this page\", \"this pdf\", \"the current paper\", \"the current project\", or asks you to base local/coding work on what is currently open.",
        inputSchema: [
            "type": "object",
            "properties": [:] as [String: Any]
        ]
    )

    private static let openLocalPathTool = AgentToolDefinition(
        name: "open_local_path",
        description: "Open an existing local file or folder, optionally in a specific app. Use this to open a generated project folder in Cursor or VS Code, open a PDF in Preview, or reveal a local artifact for the user. This routes through NSWorkspace instead of Finder clicks or Spotlight keystrokes.",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Existing local file or folder path. Use an absolute path or ~/... path."
                ],
                "app": [
                    "type": "string",
                    "description": "Optional app name or bundle identifier, e.g. \"Cursor\", \"Visual Studio Code\", \"Preview\". Omit to use the default app."
                ],
                "new_window": [
                    "type": "boolean",
                    "description": "If true and an app is provided, ask macOS to launch a new application instance/window instead of reusing an existing one. Use for requests like \"new Cursor window\"."
                ]
            ],
            "required": ["path"]
        ]
    )

    private static let runLocalCommandTool = AgentToolDefinition(
        name: "run_local_command",
        description: "Run one bounded local command for file/code inspection, tests, or packaging work needed by the user's live task. Use this instead of Finder when you need to inspect a project folder, run tests, or create a zip. The app enforces a working directory, a short timeout, output caps, and a conservative command allowlist. Do NOT use for destructive operations, installs, network fetches, long builds, daemons, or background processes. If the command is rejected, choose a simpler read/test/archive command.",
        inputSchema: [
            "type": "object",
            "properties": [
                "cwd": [
                    "type": "string",
                    "description": "Existing local directory to run the command in. Use an absolute path or ~/... path."
                ],
                "command": [
                    "type": "string",
                    "description": "Single command line to run, e.g. \"ls\", \"find . -maxdepth 2 -type f\", \"python3 -m pytest\", \"zip -r ../submission.zip . -x .git/* __pycache__/*\". Shell chaining, redirection, backgrounding, installs, sudo, deletes, and destructive commands are rejected."
                ],
                "timeout_seconds": [
                    "type": "integer",
                    "description": "Optional timeout, capped at 30 seconds. Default 15."
                ]
            ],
            "required": ["cwd", "command"]
        ]
    )

    private static let createZipArchiveTool = AgentToolDefinition(
        name: "create_zip_archive",
        description: "Create a zip archive from existing local files/folders with explicit archive paths. Use when a website expects a submission/upload zip and the included folders need specific names, e.g. source /Users/me/project/src as archive path src, or source /Users/me/project/exp/runA as archive path exp/s2_ifql. This is safer and clearer than shell mkdir/cp/zip. It only copies existing files into a temporary staging folder, zips that folder, and returns the output zip path.",
        inputSchema: [
            "type": "object",
            "properties": [
                "output_path": [
                    "type": "string",
                    "description": "Destination .zip file path. Use an absolute path or ~/... path. Parent directories are created if needed; an existing zip at this path is replaced."
                ],
                "entries": [
                    "type": "array",
                    "description": "Files or folders to include in the archive, each with the exact path it should have inside the zip.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "source_path": [
                                "type": "string",
                                "description": "Existing local file or folder path to copy into the archive."
                            ],
                            "archive_path": [
                                "type": "string",
                                "description": "Relative path inside the zip, e.g. src, README.md, exp/s2_ifql. Must not be absolute and must not contain . or .. path components."
                            ]
                        ],
                        "required": ["source_path", "archive_path"]
                    ]
                ]
            ],
            "required": ["output_path", "entries"]
        ]
    )

    private static let chooseFileOrFolderTool = AgentToolDefinition(
        name: "choose_file_or_folder",
        description: "Choose an existing local file or folder in the frontmost macOS Open/Choose dialog. Use after clicking a website/app upload or choose-file button. It drives the standard file picker directly: for files it opens the parent folder, moves into the contents column, type-selects the basename, then confirms. This is much more reliable than clicking through Finder visually. If no file picker is frontmost, click the upload/choose button first.",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Existing local file or folder path to choose. Use an absolute path or ~/... path."
                ]
            ],
            "required": ["path"]
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
        case "fill_text_field":
            guard let coordinate = decodeCoordinate(from: toolUseBlock.inputArguments),
                  let textValue = toolUseBlock.inputArguments["text"] as? String else { return nil }
            let unescapedText = textValue.replacingOccurrences(of: "\\n", with: "\n")
            let clearExistingValue = (toolUseBlock.inputArguments["clear_existing"] as? Bool) ?? false
            return .fillTextField(
                coordinate: coordinate,
                label: decodeOptionalString(toolUseBlock.inputArguments["label"]),
                screen: decodeOptionalInt(toolUseBlock.inputArguments["screen"]),
                text: unescapedText,
                clearExisting: clearExistingValue
            )
        case "fill_and_submit":
            guard let coordinate = decodeCoordinate(from: toolUseBlock.inputArguments),
                  let textValue = toolUseBlock.inputArguments["text"] as? String else { return nil }
            let unescapedText = textValue.replacingOccurrences(of: "\\n", with: "\n")
            let clearExistingValue = (toolUseBlock.inputArguments["clear_existing"] as? Bool) ?? false
            let submitKeystrokeSpec = (toolUseBlock.inputArguments["submit_keystroke"] as? String) ?? "return"
            return .fillAndSubmit(
                coordinate: coordinate,
                label: decodeOptionalString(toolUseBlock.inputArguments["label"]),
                screen: decodeOptionalInt(toolUseBlock.inputArguments["screen"]),
                text: unescapedText,
                clearExisting: clearExistingValue,
                submitKeystrokeSpec: submitKeystrokeSpec
            )
        case "perform_action_sequence":
            guard let rawActions = toolUseBlock.inputArguments["actions"] as? [[String: Any]],
                  !rawActions.isEmpty,
                  rawActions.count <= 6 else { return nil }
            let decodedSteps = rawActions.compactMap { rawAction in
                decodeActionSequenceStep(from: rawAction)
            }
            guard decodedSteps.count == rawActions.count else { return nil }
            return .performActionSequence(decodedSteps)
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
        case "wait_for_seconds":
            let secondsValue = decodeOptionalInt(toolUseBlock.inputArguments["seconds"]) ?? 5
            return .waitForSeconds(secondsValue)
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
        case "get_foreground_document_context":
            return .getForegroundDocumentContext
        case "open_local_path":
            guard let pathValue = toolUseBlock.inputArguments["path"] as? String,
                  !pathValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .openLocalPath(
                path: pathValue.trimmingCharacters(in: .whitespacesAndNewlines),
                applicationNameOrBundleIdentifier: decodeOptionalString(toolUseBlock.inputArguments["app"]),
                preferNewApplicationInstance: (toolUseBlock.inputArguments["new_window"] as? Bool) ?? false
            )
        case "run_local_command":
            guard let workingDirectoryValue = toolUseBlock.inputArguments["cwd"] as? String,
                  let commandValue = toolUseBlock.inputArguments["command"] as? String else { return nil }
            let timeoutSeconds = decodeOptionalInt(toolUseBlock.inputArguments["timeout_seconds"]) ?? 15
            return .runLocalCommand(
                workingDirectoryPath: workingDirectoryValue.trimmingCharacters(in: .whitespacesAndNewlines),
                command: commandValue.trimmingCharacters(in: .whitespacesAndNewlines),
                timeoutSeconds: timeoutSeconds
            )
        case "create_zip_archive":
            guard let outputPathValue = toolUseBlock.inputArguments["output_path"] as? String,
                  let rawEntries = toolUseBlock.inputArguments["entries"] as? [[String: Any]],
                  !outputPathValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !rawEntries.isEmpty else { return nil }
            let decodedEntries = rawEntries.compactMap { rawEntry -> AgentZipArchiveEntry? in
                guard let sourcePathValue = rawEntry["source_path"] as? String,
                      let archivePathValue = rawEntry["archive_path"] as? String else { return nil }
                let trimmedSourcePath = sourcePathValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedArchivePath = archivePathValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedSourcePath.isEmpty, !trimmedArchivePath.isEmpty else { return nil }
                return AgentZipArchiveEntry(
                    sourcePath: trimmedSourcePath,
                    archivePath: trimmedArchivePath
                )
            }
            guard decodedEntries.count == rawEntries.count else { return nil }
            return .createZipArchive(
                outputPath: outputPathValue.trimmingCharacters(in: .whitespacesAndNewlines),
                entries: decodedEntries
            )
        case "choose_file_or_folder":
            guard let pathValue = toolUseBlock.inputArguments["path"] as? String,
                  !pathValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .chooseFileOrFolder(path: pathValue.trimmingCharacters(in: .whitespacesAndNewlines))
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
        case "memory":
            // Forward the raw input dict; DotMemoryStore validates each field
            // against Anthropic's command schema (view/create/str_replace/etc).
            return .memory(input: toolUseBlock.inputArguments)
        default:
            return nil
        }
    }

    private static func decodeActionSequenceStep(from rawAction: [String: Any]) -> AgentActionSequenceStep? {
        guard let typeValue = rawAction["type"] as? String else { return nil }
        let normalizedType = typeValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedType {
        case "click", "click_element":
            guard let coordinate = decodeCoordinate(from: rawAction) else { return nil }
            return .clickElement(
                coordinate: coordinate,
                label: decodeOptionalString(rawAction["label"]),
                screen: decodeOptionalInt(rawAction["screen"])
            )

        case "type", "type_text":
            guard let textValue = rawAction["text"] as? String else { return nil }
            return .typeText(textValue.replacingOccurrences(of: "\\n", with: "\n"))

        case "key", "press", "press_keystroke":
            guard let specValue = rawAction["spec"] as? String,
                  !specValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .pressKeystroke(spec: specValue.trimmingCharacters(in: .whitespacesAndNewlines))

        case "pause", "wait":
            let rawMilliseconds = decodeOptionalInt(rawAction["milliseconds"])
                ?? decodeOptionalInt(rawAction["ms"])
                ?? ((decodeOptionalInt(rawAction["seconds"]) ?? 0) * 1_000)
            let clampedMilliseconds = min(max(rawMilliseconds, 0), 1_500)
            return .pauseForMilliseconds(clampedMilliseconds)

        case "scroll":
            guard let directionRawValue = rawAction["direction"] as? String,
                  let scrollDirection = AgentScrollDirection(rawValue: directionRawValue.lowercased()) else {
                return nil
            }
            let amountRawValue = (rawAction["amount"] as? String)?.lowercased() ?? "medium"
            let scrollAmount = AgentScrollAmount(rawValue: amountRawValue) ?? .medium
            return .scroll(direction: scrollDirection, amount: scrollAmount)

        default:
            return nil
        }
    }

    private static func decodeCoordinate(from inputArguments: [String: Any]) -> CGPoint? {
        if let xValue = decodeOptionalInt(inputArguments["x"]),
           let yValue = decodeOptionalInt(inputArguments["y"]) {
            return CGPoint(x: xValue, y: yValue)
        }

        for nestedCoordinateKey in ["coordinate", "coordinates", "point"] {
            if let nestedCoordinate = inputArguments[nestedCoordinateKey] as? [String: Any],
               let xValue = decodeOptionalInt(nestedCoordinate["x"]),
               let yValue = decodeOptionalInt(nestedCoordinate["y"]) {
                return CGPoint(x: xValue, y: yValue)
            }
            if let nestedCoordinate = inputArguments[nestedCoordinateKey] as? [Any],
               nestedCoordinate.count >= 2,
               let xValue = decodeOptionalInt(nestedCoordinate[0]),
               let yValue = decodeOptionalInt(nestedCoordinate[1]) {
                return CGPoint(x: xValue, y: yValue)
            }
        }

        return nil
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
