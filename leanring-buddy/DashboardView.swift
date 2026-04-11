import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var frontendStore: DebilFrontendStore

    var onSignOut: () -> Void
    var onExisting: () -> Void

    var body: some View {
        GeometryReader { geometryProxy in
            let iconSize = min(geometryProxy.size.height * 0.25, 98)

            VStack(spacing: 0) {
                headerBar

                Button(action: onExisting) {
                    VStack(spacing: 16) {
                        DashboardHeroMark(size: iconSize)

                        VStack(spacing: 6) {
                            Text("My Courses")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(DS.foreground)
                                .multilineTextAlignment(.center)

                            Text("Browse workspaces, upload files, and preview course materials.")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(DS.mutedForeground)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(width: geometryProxy.size.width, height: geometryProxy.size.height - 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(DS.card.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(frontendStore.currentUser?.displayName ?? "Debil")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.foreground)
                Text(frontendStore.currentUser?.emailAddress ?? "")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DS.mutedForeground)
            }

            Spacer(minLength: 8)

            Button("Sign out", action: onSignOut)
                .buttonStyle(.bordered)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DS.border.opacity(0.45))
                .frame(height: 1)
        }
    }
}

private struct DashboardHeroMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(DS.accent.opacity(0.6))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(DS.border.opacity(0.8), lineWidth: 1)
                )

            Image(systemName: "folder.fill")
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(DS.foreground)

            Image(systemName: "graduationcap.fill")
                .font(.system(size: size * 0.16, weight: .bold))
                .foregroundStyle(DS.background)
                .padding(6)
                .background(Circle().fill(DS.foreground.opacity(0.95)))
                .overlay(Circle().stroke(DS.border.opacity(0.5), lineWidth: 1))
                .offset(x: size * 0.24, y: size * 0.24)
        }
        .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 6)
    }
}
