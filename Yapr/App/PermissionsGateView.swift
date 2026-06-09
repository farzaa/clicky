//
//  PermissionsGateView.swift
//  Yapr
//
//  First-run gate that asks the user to grant microphone + Photos library
//  access. Shown by `RootView` whenever either permission is missing.
//
//  Behavior:
//   • Tapping a row whose status is `.notDetermined` shows the system prompt.
//   • Tapping a row whose status is `.denied` opens iOS Settings, since iOS
//     never re-shows the system prompt after the first denial.
//

import AVFoundation
import Photos
import SwiftUI
import UIKit

struct PermissionsGateView: View {
    let microphoneStatus: AVAuthorizationStatus
    let photosStatus: RecentScreenshotProvider.AccessStatus

    let onRequestMicrophonePermission: () -> Void
    let onRequestPhotosPermission: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(DS.Colors.brandBlue)
                Text("two quick permissions")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("yapr needs your mic to hear you, and your photos library so it can read your most recent screenshot. nothing is uploaded that you don't ask about.")
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            VStack(spacing: 12) {
                permissionRow(
                    iconSystemName: "mic.fill",
                    title: "microphone",
                    subtitle: microphoneSubtitle,
                    status: microphoneStatus == .authorized ? .granted : (microphoneStatus == .denied ? .denied : .notRequested),
                    onTap: handleMicrophoneTap
                )

                permissionRow(
                    iconSystemName: "photo.on.rectangle",
                    title: "photos library",
                    subtitle: photosSubtitle,
                    status: photosRowStatus,
                    onTap: handlePhotosTap
                )
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Row

    private enum PermissionRowStatus {
        case granted
        case denied
        case notRequested
    }

    private var photosRowStatus: PermissionRowStatus {
        switch photosStatus {
        case .authorized, .limited: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notRequested
        }
    }

    private var microphoneSubtitle: String {
        switch microphoneStatus {
        case .authorized: return "granted"
        case .denied: return "tap to open settings"
        case .restricted: return "restricted by device policy"
        case .notDetermined: return "tap to grant"
        @unknown default: return "tap to grant"
        }
    }

    private var photosSubtitle: String {
        switch photosStatus {
        case .authorized: return "granted (full access)"
        case .limited: return "granted (limited access)"
        case .denied: return "tap to open settings"
        case .restricted: return "restricted by device policy"
        case .notDetermined: return "tap to grant"
        }
    }

    private func permissionRow(
        iconSystemName: String,
        title: String,
        subtitle: String,
        status: PermissionRowStatus,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: iconSystemName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(DS.Colors.background)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Colors.textTertiary)
                }

                Spacer()

                statusIndicator(status: status)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.background)
            )
        }
        .buttonStyle(.plain)
        .disabled(status == .granted)
    }

    private func statusIndicator(status: PermissionRowStatus) -> some View {
        Group {
            switch status {
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DS.Colors.success)
            case .denied:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Colors.warning)
            case .notRequested:
                Image(systemName: "chevron.right")
                    .foregroundStyle(DS.Colors.textTertiary)
            }
        }
        .font(.system(size: 17, weight: .semibold))
    }

    // MARK: - Tap handlers

    private func handleMicrophoneTap() {
        switch microphoneStatus {
        case .denied, .restricted:
            openSettings()
        case .notDetermined, .authorized:
            onRequestMicrophonePermission()
        @unknown default:
            onRequestMicrophonePermission()
        }
    }

    private func handlePhotosTap() {
        switch photosStatus {
        case .denied, .restricted:
            openSettings()
        case .notDetermined, .authorized, .limited:
            onRequestPhotosPermission()
        }
    }

    private func openSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
    }
}
