import AppKit

/// Keeps the app menu-bar–only (no Dock tile), same idea as Clicky / many VPN utilities.
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
