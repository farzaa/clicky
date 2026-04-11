import SwiftUI

/// Home: single clear entry into your course workspace.
struct DashboardView: View {
    var onSignOut: () -> Void
    var onExisting: () -> Void

    var body: some View {
        GeometryReader { geo in
            let iconSize = min(geo.size.height * 0.25, 98)

            Button(action: onExisting) {
                VStack(spacing: 16) {
                    DashboardHeroMark(size: iconSize)

                    VStack(spacing: 6) {
                        Text("My Courses")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(DS.foreground)
                            .multilineTextAlignment(.center)

                        Text("Browse, add files, and manage course materials")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(DS.mutedForeground)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 16)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(DS.card.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
        .overlay(alignment: .topLeading) {
            Button(action: onSignOut) {
                Text("Debil")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(DS.mutedForeground.opacity(0.4))
                    .padding(.leading, 8)
                    .padding(.top, 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sign out")
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
