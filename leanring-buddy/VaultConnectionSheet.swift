//
//  VaultConnectionSheet.swift
//  leanring-buddy
//
//  Sheet for connecting an Obsidian vault or choosing a folder manually.
//

import SwiftUI

struct VaultConnectionSheet: View {
    let discoveredVaults: [DiscoveredVault]
    let onConnectDiscoveredVault: (DiscoveredVault) -> Void
    let onChooseDifferentFolder: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect your vault")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("Clicky reads your notes only when you ask about your vault or internal knowledge. Tap Connect, then confirm the folder in the picker.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if discoveredVaults.isEmpty {
                Text("No Obsidian vaults found on this Mac. Choose a folder with your markdown notes.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("We found these vaults")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(discoveredVaults) { discoveredVault in
                            discoveredVaultRow(discoveredVault)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            Button(action: onChooseDifferentFolder) {
                Text("Choose a different folder…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityIdentifier("clicky.panel.vault.choose-different-folder")

            HStack {
                Spacer()

                Button("Cancel", action: onCancel)
                    .buttonStyle(DSTextButtonStyle())
                    .accessibilityIdentifier("clicky.panel.vault.cancel")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.surface2)
    }

    private func discoveredVaultRow(_ discoveredVault: DiscoveredVault) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(discoveredVault.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)

                Text(discoveredVault.path)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Connect") {
                onConnectDiscoveredVault(discoveredVault)
            }
            .buttonStyle(DSSecondaryButtonStyle())
            .accessibilityIdentifier("clicky.panel.vault.connect.\(discoveredVault.id)")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                .fill(DS.Colors.surface3)
        )
    }
}
