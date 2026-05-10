//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI

#if canImport(Sparkle)
import Sparkle
#endif

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private let accountManager = DotAccountManager()
    #if canImport(Sparkle)
    private var sparkleUpdaterController: SPUStandardUpdaterController?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Dot: Starting...")
        print("🎯 Dot: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        DotAnalytics.configure()
        DotAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(
            companionManager: companionManager,
            accountManager: accountManager
        )
        companionManager.start()
        // Auto-open the panel if the user has work to do — sign-in is the
        // top-priority gate, then onboarding/permissions.
        if !accountManager.isSignedIn || !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        startSparkleUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Receives `dot://` URLs that macOS routes back to the app after the user
    /// finishes Google sign-in in the browser. Forwards them to the account
    /// manager which exchanges the code for an install token. Also routes
    /// `dot://debug?transcript=…` URLs into the agent loop for local testing.
    func application(_ application: NSApplication, open urls: [URL]) {
        for incomingURL in urls {
            if handleDebugTranscriptURLIfMatch(incomingURL) {
                continue
            }
            let wasHandled = accountManager.handleIncomingAuthURL(incomingURL)
            if wasHandled {
                menuBarPanelManager?.showPanelOnLaunch()
            }
        }
    }

    /// Recognizes `dot://debug?transcript=…` URLs and feeds the decoded
    /// transcript through the same dispatch path as a real push-to-talk
    /// release. Returns true if the URL was a debug URL (handled or empty),
    /// false otherwise so the caller falls through to other URL handlers.
    /// Local-dev surface — unauthenticated; gate or remove before shipping.
    private func handleDebugTranscriptURLIfMatch(_ incomingURL: URL) -> Bool {
        guard incomingURL.scheme?.lowercased() == "dot" else { return false }
        guard incomingURL.host?.lowercased() == "debug" else { return false }
        let urlComponents = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false)
        let transcriptQueryValue = urlComponents?.queryItems?.first(where: { $0.name == "transcript" })?.value ?? ""
        let trimmedTranscript = transcriptQueryValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return true }
        print("🧪 Dot: debug URL fired transcript \"\(trimmedTranscript)\"")
        companionManager.runTranscriptThroughAgentLoopForDebug(transcript: trimmedTranscript)
        return true
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Dot: Registered as login item")
            } catch {
                print("⚠️ Dot: Failed to register as login item: \(error)")
            }
        }
    }

    #if canImport(Sparkle)
    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Dot: Sparkle updater failed to start: \(error)")
        }
    }
    #endif
}
