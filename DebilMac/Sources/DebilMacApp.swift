import SwiftUI

@main
struct DebilMacApp: App {
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Same screens as before (`RootView`), but opened from the menu bar like NordVPN / Proton VPN / Clicky.
        MenuBarExtra {
            RootView()
                .background(DS.background)
                .preferredColorScheme(.dark)
                // Width tuned so dashboard rows + course list don’t clip; height scrolls inside screens.
                // Short minHeight keeps sign-in on one screen; user can drag to resize taller for My Courses.
                .frame(minWidth: 380, idealWidth: 420, maxWidth: 520, minHeight: 440, idealHeight: 520, maxHeight: 780)
        } label: {
            Image(systemName: "cursorarrow")
                .accessibilityLabel("Deb")
        }
        .menuBarExtraStyle(.window)
    }
}

enum AppRoute: Hashable {
    case login
    case dashboard
    case myCourses
    case courseDetail(String)
}

struct RootView: View {
    @State private var route: AppRoute = .login

    var body: some View {
        Group {
            switch route {
            case .login:
                LoginView(
                    onContinue: { route = .dashboard }
                )
            case .dashboard:
                DashboardView(
                    onSignOut: { route = .login },
                    onExisting: { route = .myCourses }
                )
            case .myCourses:
                MyCoursesView(
                    onBack: { route = .dashboard },
                    onCourseDetail: { route = .courseDetail($0) }
                )
            case .courseDetail(let id):
                CourseDetailView(
                    courseId: id,
                    onBack: { route = .myCourses }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
    }
}
