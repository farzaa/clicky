import SwiftUI

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var appDelegate
    @StateObject private var frontendStore = DebilFrontendStore()

    var body: some Scene {
        MenuBarExtra {
            DebilRootView()
                .environmentObject(frontendStore)
                .background(DS.background)
                .preferredColorScheme(.dark)
                .frame(
                    minWidth: 380,
                    idealWidth: 420,
                    maxWidth: 540,
                    minHeight: 460,
                    idealHeight: 560,
                    maxHeight: 820
                )
        } label: {
            Image(systemName: "cursorarrow")
                .accessibilityLabel("Debil")
        }
        .menuBarExtraStyle(.window)
    }
}
