import SwiftUI

enum DebilRoute: Hashable {
    case dashboard
    case myCourses
    case courseDetail(String)
}

struct DebilRootView: View {
    @EnvironmentObject private var frontendStore: DebilFrontendStore
    @State private var route: DebilRoute = .dashboard

    var body: some View {
        Group {
            if frontendStore.isAuthenticated {
                authenticatedContent
            } else {
                LoginView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
        .onChange(of: frontendStore.isAuthenticated) { _, isAuthenticated in
            if !isAuthenticated {
                route = .dashboard
            }
        }
    }

    @ViewBuilder
    private var authenticatedContent: some View {
        switch route {
        case .dashboard:
            DashboardView(
                onSignOut: {
                    Task {
                        await frontendStore.signOut()
                    }
                },
                onExisting: { route = .myCourses }
            )
        case .myCourses:
            MyCoursesView(
                onBack: { route = .dashboard },
                onCourseDetail: { route = .courseDetail($0) }
            )
        case .courseDetail(let workspaceID):
            CourseDetailView(
                courseId: workspaceID,
                onBack: { route = .myCourses }
            )
        }
    }
}
