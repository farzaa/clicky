//
//  AskYaprIntent.swift
//  Yapr (compiled into both the app and the Control Center widget extension)
//
//  The `AppIntent` invoked when the user taps Yapr's button in iOS Control
//  Center. It sets a "launched from Control Center" flag in the shared
//  App Group `UserDefaults` and asks iOS to bring the Yapr app to the
//  foreground. The app reads the flag on launch and immediately fetches
//  the user's most recent screenshot + pre-arms the voice orb so they can
//  hold the orb and start talking right away.
//
//  iOS sandboxing means a Control Center button can't capture the screen
//  itself — only an active broadcast session can do that. The pattern we
//  use here is the next-best thing: the user takes a normal iPhone
//  screenshot (volume-up + side button), then taps the Yapr button in
//  Control Center to ask about it, with one less tap than launching the
//  app from the Home Screen.
//

import AppIntents
import Foundation

struct AskYaprIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Yapr"

    static var description: IntentDescription? = IntentDescription(
        "Open Yapr and ask about your most recent screenshot."
    )

    /// Tells iOS to bring the Yapr app to the foreground after `perform()`
    /// completes. Required so the voice orb is visible to the user.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Set the flag so the main app knows it was launched from the
        // Control Center button (not the Home Screen icon, not Spotlight,
        // not a Siri Shortcut). The app reads and clears this on launch.
        AppGroupKeys.sharedDefaults?.set(
            true,
            forKey: AppGroupKeys.didLaunchFromControlCenter
        )

        return .result()
    }
}
