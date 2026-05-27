//
//  NicheAppSuggestionMapping.swift
//  leanring-buddy
//
//  Maps common macOS app bundle IDs to app-aware example prompts.
//

import Foundation

enum NicheAppSuggestionMapping {
    private struct AppSuggestionEntry {
        let appDisplayName: String
        let suggestions: [NicheSuggestion]
    }

    private static let entriesByBundleId: [String: AppSuggestionEntry] = [
        "com.mitchellh.ghostty": AppSuggestionEntry(
            appDisplayName: "Ghostty",
            suggestions: [
                NicheSuggestion(
                    id: "ghostty-command",
                    prompt: "Explain this terminal command on my screen."
                ),
                NicheSuggestion(
                    id: "ghostty-flag",
                    prompt: "What does this flag do?"
                ),
                NicheSuggestion(
                    id: "ghostty-git",
                    prompt: "Walk me through the git output I'm looking at."
                )
            ]
        ),
        "com.todesktop.230313mzl4w4u92": AppSuggestionEntry(
            appDisplayName: "Cursor",
            suggestions: [
                NicheSuggestion(
                    id: "cursor-agent",
                    prompt: "Where is the agent panel?"
                ),
                NicheSuggestion(
                    id: "cursor-diff",
                    prompt: "Explain the diff on my screen."
                ),
                NicheSuggestion(
                    id: "cursor-run",
                    prompt: "How do I run this project from here?"
                )
            ]
        ),
        "com.apple.dt.Xcode": AppSuggestionEntry(
            appDisplayName: "Xcode",
            suggestions: [
                NicheSuggestion(
                    id: "xcode-source-control",
                    prompt: "How do I commit from Xcode? Point at the Source Control menu."
                ),
                NicheSuggestion(
                    id: "xcode-run-scheme",
                    prompt: "Which scheme should I run? Point at the run destination picker."
                ),
                NicheSuggestion(
                    id: "xcode-breakpoint",
                    prompt: "Walk me through adding a breakpoint here — point at the gutter."
                ),
                NicheSuggestion(
                    id: "xcode-debug-area",
                    prompt: "Where do I see console output while debugging? Point at it."
                ),
                NicheSuggestion(
                    id: "xcode-navigator",
                    prompt: "How do I find a file in this project? Point at the navigator."
                )
            ]
        ),
        "com.apple.Terminal": AppSuggestionEntry(
            appDisplayName: "Terminal",
            suggestions: [
                NicheSuggestion(
                    id: "terminal-run-command",
                    prompt: "What command should I run here for this project? Point at the prompt."
                ),
                NicheSuggestion(
                    id: "terminal-git-status",
                    prompt: "Walk me through checking git status — point at what to type."
                ),
                NicheSuggestion(
                    id: "terminal-path",
                    prompt: "Am I in the right folder? Point at the current path."
                )
            ]
        ),
        "com.microsoft.VSCode": AppSuggestionEntry(
            appDisplayName: "VS Code",
            suggestions: [
                NicheSuggestion(
                    id: "vscode-command-palette",
                    prompt: "How do I open the command palette here? Point at it."
                ),
                NicheSuggestion(
                    id: "vscode-run-task",
                    prompt: "Where do I run a build task in VS Code? Point at the menu."
                ),
                NicheSuggestion(
                    id: "vscode-debug",
                    prompt: "How do I start debugging this file? Point at the run button."
                )
            ]
        ),
        "com.apple.FinalCut": AppSuggestionEntry(
            appDisplayName: "Final Cut Pro",
            suggestions: [
                NicheSuggestion(
                    id: "finalcut-export",
                    prompt: "How do I export this timeline? Point at the share or export button."
                ),
                NicheSuggestion(
                    id: "finalcut-color",
                    prompt: "Where is the color inspector? Point at it on screen."
                ),
                NicheSuggestion(
                    id: "finalcut-blade",
                    prompt: "How do I split this clip? Point at the blade tool."
                ),
                NicheSuggestion(
                    id: "finalcut-audio",
                    prompt: "Where do I adjust audio levels on this clip? Point at the controls."
                )
            ]
        ),
        "com.apple.iMovieApp": AppSuggestionEntry(
            appDisplayName: "iMovie",
            suggestions: [
                NicheSuggestion(
                    id: "imovie-export",
                    prompt: "How do I export this project? Point at the share button."
                ),
                NicheSuggestion(
                    id: "imovie-trim",
                    prompt: "How do I trim this clip? Point at the right control."
                ),
                NicheSuggestion(
                    id: "imovie-transition",
                    prompt: "Where do I add a transition between clips? Point at it."
                )
            ]
        ),
        "com.figma.Desktop": AppSuggestionEntry(
            appDisplayName: "Figma",
            suggestions: [
                NicheSuggestion(
                    id: "figma-export",
                    prompt: "How do I export this frame? Point at the export panel."
                ),
                NicheSuggestion(
                    id: "figma-components",
                    prompt: "Where are components in this file? Point at the assets panel."
                ),
                NicheSuggestion(
                    id: "figma-auto-layout",
                    prompt: "How do I turn on auto layout for this frame? Point at the control."
                ),
                NicheSuggestion(
                    id: "figma-prototype",
                    prompt: "How do I preview this prototype? Point at the play button."
                )
            ]
        ),
        "com.bohemiancoding.sketch3": AppSuggestionEntry(
            appDisplayName: "Sketch",
            suggestions: [
                NicheSuggestion(
                    id: "sketch-export",
                    prompt: "How do I export these artboards? Point at the export controls."
                ),
                NicheSuggestion(
                    id: "sketch-symbols",
                    prompt: "Where do I find symbols in this document? Point at the panel."
                ),
                NicheSuggestion(
                    id: "sketch-layout",
                    prompt: "How do I align these layers? Point at the alignment tools."
                )
            ]
        ),
        "com.apple.Notes": AppSuggestionEntry(
            appDisplayName: "Notes",
            suggestions: [
                NicheSuggestion(
                    id: "notes-checklist",
                    prompt: "How do I turn this into a checklist? Point at the format button."
                ),
                NicheSuggestion(
                    id: "notes-folder",
                    prompt: "Where should I file this note? Point at the folder sidebar."
                ),
                NicheSuggestion(
                    id: "notes-share",
                    prompt: "How do I share this note with a classmate? Point at share."
                )
            ]
        ),
        "com.apple.iWork.Pages": AppSuggestionEntry(
            appDisplayName: "Pages",
            suggestions: [
                NicheSuggestion(
                    id: "pages-format",
                    prompt: "How do I fix the formatting on this paragraph? Point at the inspector."
                ),
                NicheSuggestion(
                    id: "pages-export-pdf",
                    prompt: "How do I export this as a PDF? Point at the export menu."
                ),
                NicheSuggestion(
                    id: "pages-citation",
                    prompt: "Where do I add footnotes or citations? Point at the menu."
                )
            ]
        ),
        "com.apple.TextEdit": AppSuggestionEntry(
            appDisplayName: "TextEdit",
            suggestions: [
                NicheSuggestion(
                    id: "textedit-plain-text",
                    prompt: "How do I switch this to plain text? Point at the format menu."
                ),
                NicheSuggestion(
                    id: "textedit-find",
                    prompt: "Where is find and replace? Point at the menu item."
                ),
                NicheSuggestion(
                    id: "textedit-save-as",
                    prompt: "How do I save this in a different format? Point at Save As."
                )
            ]
        ),
        "com.apple.Safari": AppSuggestionEntry(
            appDisplayName: "Safari",
            suggestions: [
                NicheSuggestion(
                    id: "safari-tab-group",
                    prompt: "How do I organize these tabs? Point at the tab group control."
                ),
                NicheSuggestion(
                    id: "safari-reader",
                    prompt: "How do I open reader view on this page? Point at the button."
                ),
                NicheSuggestion(
                    id: "safari-downloads",
                    prompt: "Where did my download go? Point at the downloads button."
                )
            ]
        ),
        "com.apple.mail": AppSuggestionEntry(
            appDisplayName: "Mail",
            suggestions: [
                NicheSuggestion(
                    id: "mail-compose",
                    prompt: "How do I attach a file to this email? Point at the attach button."
                ),
                NicheSuggestion(
                    id: "mail-search",
                    prompt: "How do I search for an old message? Point at the search field."
                ),
                NicheSuggestion(
                    id: "mail-rules",
                    prompt: "Where do I set up a mail rule? Point at the preferences menu."
                )
            ]
        ),
        "com.apple.finder": AppSuggestionEntry(
            appDisplayName: "Finder",
            suggestions: [
                NicheSuggestion(
                    id: "finder-quick-look",
                    prompt: "How do I preview this file without opening it? Point at Quick Look."
                ),
                NicheSuggestion(
                    id: "finder-tags",
                    prompt: "How do I tag these files? Point at the tags control."
                ),
                NicheSuggestion(
                    id: "finder-path-bar",
                    prompt: "How do I copy the path to this folder? Point at the path bar."
                )
            ]
        ),
        "com.notion.id": AppSuggestionEntry(
            appDisplayName: "Notion",
            suggestions: [
                NicheSuggestion(
                    id: "notion-template",
                    prompt: "How do I duplicate this page as a template? Point at the menu."
                ),
                NicheSuggestion(
                    id: "notion-toggle",
                    prompt: "How do I collapse this section? Point at the toggle."
                ),
                NicheSuggestion(
                    id: "notion-share",
                    prompt: "How do I share this page with my team? Point at share."
                )
            ]
        ),
        "com.spotify.client": AppSuggestionEntry(
            appDisplayName: "Spotify",
            suggestions: [
                NicheSuggestion(
                    id: "spotify-queue",
                    prompt: "How do I add this song to my queue? Point at the menu."
                ),
                NicheSuggestion(
                    id: "spotify-playlist",
                    prompt: "How do I save this to a playlist? Point at the plus button."
                ),
                NicheSuggestion(
                    id: "spotify-lyrics",
                    prompt: "Where do I see lyrics for this track? Point at the lyrics button."
                )
            ]
        )
    ]

    static func appSpecificSuggestions(bundleId: String) -> [NicheSuggestion]? {
        entriesByBundleId[bundleId]?.suggestions
    }

    static func appDisplayName(bundleId: String) -> String? {
        entriesByBundleId[bundleId]?.appDisplayName
    }

    static func contextLabel(bundleId: String) -> String? {
        guard let entry = entriesByBundleId[bundleId] else { return nil }
        return "While you're in \(entry.appDisplayName), try saying one of these:"
    }
}
