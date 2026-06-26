//
//  CompanionPanelMissionWizardViews.swift
//  leanring-buddy
//
//  Ad Mission wizard steps for the Spider menu bar panel.
//

import SwiftUI

struct CompanionPanelOfferStepView: View {
    let appLanguage: SpiderAppLanguage
    @Binding var missionDraft: CompanionPanelMissionDraft
    let onBack: () -> Void
    let onNext: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            wizardHeader(title: copy("Mission"), onBack: onBack)

            VStack(alignment: .leading, spacing: 4) {
                Text(copy("Start with your offer"))
                    .font(DS.Typography.panelTitle)
                    .foregroundStyle(spiderTextPrimary)

                Text(copy("Tell Spider what you’re selling. It will turn your\noffer into a Meta campaign direction."))
                    .font(DS.Typography.rowBody)
                    .foregroundStyle(spiderTextMuted)
                    .lineSpacing(1)
            }

            CompanionPanelMultilineField(
                title: copy("Describe your offer"),
                placeholder: copy("Example: A $97 AI productivity course\nfor freelancers"),
                text: $missionDraft.offer,
                minHeight: 250
            )

            CompanionPanelFooterButtons(
                backTitle: nil,
                nextTitle: copy("Next"),
                canContinue: !missionDraft.offer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                backAction: nil,
                nextAction: onNext
            )
        }
    }

    private func wizardHeader(title: String, onBack: @escaping () -> Void) -> some View {
        CompanionPanelWizardHeader(
            title: title,
            appLanguage: appLanguage,
            onBack: onBack,
            onOpenSettings: onOpenSettings,
            onQuit: onQuit
        )
    }

    private func copy(_ key: String) -> String {
        SpiderPanelCopy.text(key, language: appLanguage)
    }
}

struct CompanionPanelCampaignGoalStepView: View {
    let appLanguage: SpiderAppLanguage
    @Binding var missionDraft: CompanionPanelMissionDraft
    let onBack: () -> Void
    let onNext: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            wizardHeader(title: copy("Mission"), onBack: onBack)

            Text(copy("What should this campaign do?"))
                .font(DS.Typography.panelHeader)
                .foregroundStyle(spiderTextPrimary)

            VStack(spacing: DS.SpiderPanel.Layout.campaignGoalRowSpacing) {
                ForEach(campaignGoalOptions) { option in
                    CompanionPanelCampaignGoalRow(
                        title: copy(option.title),
                        subtitle: copy(option.subtitle),
                        isSelected: missionDraft.businessGoal == option.title
                    ) {
                        missionDraft.businessGoal = option.title
                    }
                    if option.id != campaignGoalOptions.last?.id {
                        Divider()
                            .background(DS.SpiderPanel.Colors.divider)
                            .padding(.leading, DS.SpiderPanel.Layout.campaignGoalDividerIndent)
                    }
                }
            }
            .padding(.horizontal, DS.SpiderPanel.Layout.listHorizontalPadding)
            .padding(.vertical, DS.SpiderPanel.Layout.campaignGoalVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CompanionPanelSurface.assetCard)

            CompanionPanelFooterButtons(
                backTitle: copy("Back"),
                nextTitle: copy("Next"),
                canContinue: true,
                backAction: onBack,
                nextAction: onNext
            )
        }
    }

    private var campaignGoalOptions: [CompanionPanelCampaignGoalOption] {
        CompanionPanelMissionOptions.campaignGoalOptions
    }

    private func wizardHeader(title: String, onBack: @escaping () -> Void) -> some View {
        CompanionPanelWizardHeader(
            title: title,
            appLanguage: appLanguage,
            onBack: onBack,
            onOpenSettings: onOpenSettings,
            onQuit: onQuit
        )
    }

    private func copy(_ key: String) -> String {
        SpiderPanelCopy.text(key, language: appLanguage)
    }
}

struct CompanionPanelAudienceStepView: View {
    let appLanguage: SpiderAppLanguage
    @Binding var missionDraft: CompanionPanelMissionDraft
    let onBack: () -> Void
    let onNext: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            wizardHeader(title: copy("Mission"), onBack: onBack)

            VStack(alignment: .leading, spacing: 4) {
                Text(copy("Who is this for?"))
                    .font(DS.Typography.panelTitle)
                    .foregroundStyle(spiderTextPrimary)

                Text(copy("Spider needs to know the buyer before\nchoosing the campaign path."))
                    .font(DS.Typography.rowBody)
                    .foregroundStyle(spiderTextMuted)
                    .lineSpacing(1)
            }

            VStack(spacing: 14) {
                CompanionPanelMultilineField(
                    title: copy("Target audience"),
                    placeholder: copy("Example: Freelancers who use AI tools\nbut struggle to stay productive"),
                    text: $missionDraft.audience,
                    minHeight: 86
                )

                audienceDetailsCard
            }

            CompanionPanelFooterButtons(
                backTitle: copy("Back"),
                nextTitle: copy("Next"),
                canContinue: !missionDraft.audience.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                backAction: onBack,
                nextAction: onNext
            )
        }
        .onAppear {
            missionDraft.applyAudienceDefaultsIfNeeded()
        }
    }

    private var audienceDetailsCard: some View {
        VStack(spacing: 0) {
            CompanionPanelPriceField(
                title: copy("Price / ticket"),
                amount: $missionDraft.ticketAmount,
                currency: $missionDraft.ticketCurrencyCode,
                placeholder: CompanionPanelMissionOptions.defaultTicketAmount,
                currencyOptions: currencyOptions
            )
            CompanionPanelSurface.assetDivider
            CompanionPanelMenuRow(title: copy("Market"), value: missionDraft.marketValue, options: marketOptions) { selection in
                missionDraft.country = selection
            }
            CompanionPanelSurface.assetDivider
            CompanionPanelMenuRow(title: copy("Language"), value: missionDraft.audienceLanguageValue, options: audienceLanguageOptions) { selection in
                missionDraft.language = selection
            }
            CompanionPanelSurface.assetDivider
            CompanionPanelMenuRow(title: copy("Platform"), value: missionDraft.adPlatformValue, options: adPlatformMenuOptions) { selection in
                missionDraft.adPlatform = selection
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .background(CompanionPanelSurface.assetCard)
    }

    private var currencyOptions: [CompanionPanelCurrencyOption] {
        CompanionPanelMissionMoneyPolicy.currencyOptions
    }

    private var marketOptions: [String] {
        CompanionPanelMissionOptions.marketOptions
    }

    private var adPlatformMenuOptions: [String] {
        CompanionPanelMissionOptions.adPlatformMenuOptions
    }

    private var audienceLanguageOptions: [String] {
        CompanionPanelMissionOptions.audienceLanguageOptions
    }

    private func wizardHeader(title: String, onBack: @escaping () -> Void) -> some View {
        CompanionPanelWizardHeader(
            title: title,
            appLanguage: appLanguage,
            onBack: onBack,
            onOpenSettings: onOpenSettings,
            onQuit: onQuit
        )
    }

    private func copy(_ key: String) -> String {
        SpiderPanelCopy.text(key, language: appLanguage)
    }
}

struct CompanionPanelTestLimitStepView: View {
    let appLanguage: SpiderAppLanguage
    @Binding var missionDraft: CompanionPanelMissionDraft
    let onBack: () -> Void
    let onNext: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            wizardHeader(title: copy("Mission"), onBack: onBack)

            VStack(alignment: .leading, spacing: 4) {
                Text(copy("Set your test limit"))
                    .font(DS.Typography.panelTitle)
                    .foregroundStyle(spiderTextPrimary)

                Text(copy("Spider won’t set or spend this. It only uses\nyour limit to keep the setup inside your plan."))
                    .font(DS.Typography.rowBody)
                    .foregroundStyle(spiderTextMuted)
                    .lineSpacing(1)
            }

            testLimitCard

            Text(copy("You’ll type this manually inside %@.", missionDraft.adPlatformValue))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.SpiderPanel.Colors.textFaint)

            CompanionPanelFooterButtons(
                backTitle: copy("Back"),
                nextTitle: copy("Next"),
                canContinue: true,
                backAction: onBack,
                nextAction: onNext
            )
        }
        .onAppear {
            missionDraft.applyTestLimitDefaultsIfNeeded()
        }
    }

    private var testLimitCard: some View {
        VStack(spacing: 0) {
            CompanionPanelPriceField(
                title: copy("Total test limit"),
                amount: $missionDraft.totalTestLimit,
                currency: $missionDraft.ticketCurrencyCode,
                placeholder: CompanionPanelMissionOptions.defaultTotalTestLimit,
                currencyOptions: currencyOptions
            )
            CompanionPanelSurface.assetDivider
            CompanionPanelPriceField(
                title: copy("Daily guardrail"),
                amount: $missionDraft.dailyGuardrail,
                currency: $missionDraft.ticketCurrencyCode,
                placeholder: CompanionPanelMissionOptions.defaultDailyGuardrail,
                currencyOptions: currencyOptions,
                unitSuffix: "/day",
                numericOnly: true
            )
            CompanionPanelSurface.assetDivider
            CompanionPanelValueField(
                title: copy("Test length"),
                text: $missionDraft.testLength,
                placeholder: CompanionPanelMissionOptions.defaultTestLength
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .background(CompanionPanelSurface.assetCard)
    }

    private var currencyOptions: [CompanionPanelCurrencyOption] {
        CompanionPanelMissionMoneyPolicy.currencyOptions
    }

    private func wizardHeader(title: String, onBack: @escaping () -> Void) -> some View {
        CompanionPanelWizardHeader(
            title: title,
            appLanguage: appLanguage,
            onBack: onBack,
            onOpenSettings: onOpenSettings,
            onQuit: onQuit
        )
    }

    private func copy(_ key: String) -> String {
        SpiderPanelCopy.text(key, language: appLanguage)
    }

    private func copy(_ key: String, _ argument: String) -> String {
        String(format: copy(key), argument)
    }
}

struct CompanionPanelCampaignReadyStepView: View {
    let appLanguage: SpiderAppLanguage
    let missionDraft: CompanionPanelMissionDraft
    let onBack: () -> Void
    let onGuide: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            wizardHeader(title: copy("Let’s Go!"), onBack: onBack)

            VStack(spacing: 8) {
                Text(copy("Your campaign path is ready"))
                    .font(DS.Typography.panelTitle)
                    .foregroundStyle(DS.SpiderPanel.Colors.textPrimary)

                Text(copy("Spider will guide you step by step inside\n%@. You stay in control.", missionDraft.adPlatformValue))
                    .font(DS.Typography.rowBody)
                    .foregroundStyle(DS.SpiderPanel.Colors.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(1)

                Text(copy("You click. Spider never spends."))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.SpiderPanel.Colors.textFaint)
            }
            .frame(maxWidth: .infinity)

            CompanionPanelFooterButtons(
                backTitle: copy("Back"),
                nextTitle: copy("Guide Me"),
                canContinue: true,
                backAction: onBack,
                nextAction: onGuide
            )
        }
    }

    private func wizardHeader(title: String, onBack: @escaping () -> Void) -> some View {
        CompanionPanelWizardHeader(
            title: title,
            appLanguage: appLanguage,
            onBack: onBack,
            onOpenSettings: onOpenSettings,
            onQuit: onQuit
        )
    }

    private func copy(_ key: String) -> String {
        SpiderPanelCopy.text(key, language: appLanguage)
    }

    private func copy(_ key: String, _ argument: String) -> String {
        String(format: copy(key), argument)
    }
}

private var spiderTextPrimary: Color {
    DS.SpiderPanel.Colors.textPrimary
}

private var spiderTextMuted: Color {
    DS.SpiderPanel.Colors.textMuted
}
