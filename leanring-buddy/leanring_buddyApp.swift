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
    /// manager which exchanges the code for an install token.
    func application(_ application: NSApplication, open urls: [URL]) {
        for incomingURL in urls {
            let wasHandled = accountManager.handleIncomingAuthURL(incomingURL)
            if wasHandled {
                menuBarPanelManager?.showPanelOnLaunch()
            }
        }
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
