//
//  CompanionPanelFormControls.swift
//  leanring-buddy
//
//  Reusable form rows for the Spider menu bar panel.
//

import SwiftUI

struct CompanionPanelMultilineField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let minHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(DS.Typography.cardTitle)
                .foregroundStyle(DS.SpiderPanel.Colors.textPrimary)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(DS.Typography.rowBody)
                        .foregroundStyle(DS.SpiderPanel.Colors.textFaint)
                        .padding(.top, 1)
                        .padding(.leading, 1)
                }

                TextEditor(text: $text)
                    .font(DS.Typography.rowBody)
                    .foregroundStyle(DS.SpiderPanel.Colors.textPrimary)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
            }
            .frame(minHeight: minHeight, alignment: .topLeading)
        }
        .padding(18)
        .background(CompanionPanelSurface.assetCard)
    }
}

struct CompanionPanelValueField: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(DS.Typography.rowTitle)
                .foregroundStyle(DS.SpiderPanel.Colors.textPrimary)

            Spacer()

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DS.SpiderPanel.Colors.textPrimary)
                .multilineTextAlignment(.trailing)
                .frame(width: 132)
        }
        .frame(height: 55)
    }
}

struct CompanionPanelPriceField: View {
    let title: String
    @Binding var amount: String
    @Binding var currency: String
    let placeholder: String
    let currencyOptions: [CompanionPanelCurrencyOption]
    var unitSuffix: String?
    var numericOnly = false

    var body: some View {
        let showsUnitSuffix = unitSuffix != nil
        let amountFieldWidth: CGFloat = showsUnitSuffix ? 48 : 58
        let controlWidth: CGFloat = showsUnitSuffix ? 172 : 132

        return HStack(spacing: 12) {
            Text(title)
                .font(DS.Typography.rowTitle)
                .foregroundStyle(DS.SpiderPanel.Colors.textPrimary)
                .lineLimit(1)

            Spacer()

            HStack(spacing: 6) {
                TextField(placeholder, text: amountBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(DS.SpiderPanel.Colors.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .frame(width: amountFieldWidth)

                Menu {
                    ForEach(currencyOptions) { option in
                        Button(option.menuTitle) {
                            currency = option.code
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        HStack(spacing: 0) {
                            Text(currency)
                            if let unitSuffix {
                                Text(unitSuffix)
                            }
                        }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(DS.SpiderPanel.Colors.textPrimary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DS.SpiderPanel.Colors.textFaint)
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .frame(width: controlWidth, alignment: .trailing)
        }
        .frame(height: 55)
    }

    private var amountBinding: Binding<String> {
        Binding(
            get: { amount },
            set: { newValue in
                amount = numericOnly
                    ? CompanionPanelMissionMoneyPolicy.sanitizedNumericMoneyInput(newValue)
                    : newValue
            }
        )
    }
}

struct CompanionPanelMenuRow: View {
    let title: String
    let value: String
    let options: [String]
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option) {
                    onSelect(option)
                }
            }
        } label: {
            HStack {
                Text(title)
                    .font(DS.Typography.rowTitle)
                    .foregroundStyle(DS.SpiderPanel.Colors.textPrimary)

                Spacer()

                Text(value)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(DS.SpiderPanel.Colors.textPrimary)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.SpiderPanel.Colors.textFaint)
            }
            .frame(height: 55)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

struct CompanionPanelCampaignGoalRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isSelected ? DS.SpiderPanel.Colors.accent : Color.white.opacity(0.08))
                        .frame(width: 25, height: 25)

                    if isSelected {
                        Circle()
                            .fill(DS.SpiderPanel.Colors.accentText)
                            .frame(width: 11, height: 11)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(DS.Typography.rowTitle)
                        .foregroundStyle(DS.SpiderPanel.Colors.textPrimary)
                    Text(subtitle)
                        .font(DS.Typography.rowBody)
                        .foregroundStyle(DS.SpiderPanel.Colors.textMuted)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Spacer()
            }
            .frame(minHeight: DS.SpiderPanel.Layout.campaignGoalRowHeight)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

struct CompanionPanelFooterButtons: View {
    let backTitle: String?
    let nextTitle: String
    let canContinue: Bool
    let backAction: (() -> Void)?
    let nextAction: () -> Void

    var body: some View {
        HStack {
            if let backTitle, let backAction {
                Button(action: backAction) {
                    Text(backTitle)
                        .font(DS.Typography.button)
                        .foregroundStyle(DS.SpiderPanel.Colors.textMuted)
                        .frame(width: 100, height: 38)
                        .background(CompanionPanelSurface.secondaryPillBackground)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            Spacer()

            Button(action: nextAction) {
                Text(nextTitle)
                    .font(DS.Typography.button)
                    .foregroundStyle(DS.SpiderPanel.Colors.accentText)
                    .frame(width: 100, height: 38)
                    .background(CompanionPanelSurface.primaryPillBackground(isEnabled: canContinue))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(!canContinue)
        }
    }
}

struct CompanionPanelSettingsNavigationRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(DS.Typography.rowTitle)
                    .foregroundStyle(DS.SpiderPanel.Colors.textPrimary)

                Spacer()

                Image(systemName: "arrow.right")
                    .font(DS.Typography.icon)
                    .foregroundStyle(DS.SpiderPanel.Colors.textMuted)
            }
            .frame(height: 48)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

struct CompanionPanelPermissionStatusRow: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(DS.Typography.rowTitle)
                    .foregroundStyle(DS.SpiderPanel.Colors.textPrimary)

                Spacer()

                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? DS.SpiderPanel.Colors.accent.opacity(0.24) : Color.white.opacity(0.10))
                        .frame(width: 36, height: 20)

                    Circle()
                        .fill(isOn ? DS.SpiderPanel.Colors.accent : DS.SpiderPanel.Colors.textFaint)
                        .frame(width: 18, height: 18)
                        .padding(.horizontal, 1)
                }
            }
            .frame(height: 48)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

struct CompanionPanelCircularIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DS.SpiderPanel.Colors.textPrimary)
                .frame(width: 38, height: 38)
                .background(CompanionPanelSurface.liquidCircleBackground)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
