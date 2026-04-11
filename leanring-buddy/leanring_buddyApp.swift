import SwiftUI

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var appDelegate
    @State private var frontendStore = DebilFrontendStore()

    var body: some Scene {
        MenuBarExtra {
            DebilRootView()
                .environment(frontendStore)
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
            Image("deb-logo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .accessibilityLabel("Deb")
        }
        .menuBarExtraStyle(.window)
    }
}
