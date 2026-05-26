//
//  SettingsView.swift
//  yardtalk
//
//  Settings screen accessible from the panel header. Houses the synthesis
//  provider picker (Apple on-device or Ollama) and the NU PAT for upload.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    @Binding var screen: ProjectPickerScreen

    @State private var providerKind: SynthesisProviderKind = .apple
    @State private var ollamaBaseURL: String = OllamaProvider.defaultBaseURLString
    @State private var ollamaModel: String = OllamaProvider.defaultModel
    @State private var anthropicKeyInput: String = ""
    @State private var anthropicModel: String = AnthropicProvider.defaultModel
    @State private var hasStoredAnthropicKey: Bool = false
    @State private var synthesisMessage: String?

    @State private var nuPATInput: String = ""
    @State private var hasStoredNUPAT: Bool = false
    @State private var nuSaveMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                backRow

                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                synthesisProviderSection
                nuPATSection
                recordingSection
            }
            .padding(.bottom, 4)
        }
        .frame(maxHeight: 420)
        .onAppear {
            loadProviderPreferences()
            hasStoredNUPAT = KeychainService.read(key: CompanionManager.nuPATKeychainKey) != nil
            hasStoredAnthropicKey = KeychainService.read(key: CompanionManager.anthropicAPIKeyKeychainKey) != nil
        }
    }

    private var backRow: some View {
        HStack {
            Button {
                screen = .main
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            Spacer()
        }
    }

    // MARK: - Synthesis provider

    private var synthesisProviderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SYNTHESIS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)

            activeProviderRow

            providerPicker

            switch providerKind {
            case .apple:
                appleProviderRow
            case .ollama:
                ollamaConfigRows
                Text(ollamaHelpText)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .anthropic:
                anthropicConfigRows
                Text(anthropicHelpText)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = synthesisMessage {
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.success)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private var activeProviderRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(companionManager.synthesisProvider != nil ? DS.Colors.success : Color.gray)
                .frame(width: 6, height: 6)
            Text("Active:")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
            Text(companionManager.synthesisProvider?.displayName ?? "None configured")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
        }
        .padding(.bottom, 2)
    }

    private var providerPicker: some View {
        VStack(spacing: 4) {
            ForEach(SynthesisProviderKind.allCases, id: \.self) { kind in
                providerOptionRow(kind)
            }
        }
    }

    private func providerOptionRow(_ kind: SynthesisProviderKind) -> some View {
        let isSelected = providerKind == kind
        return Button {
            selectProvider(kind)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? DS.Colors.accent : DS.Colors.textTertiary)
                Text(kind.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(providerSubtitle(for: kind))
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? DS.Colors.accent.opacity(0.15) : Color.white.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? DS.Colors.accent.opacity(0.4) : DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func providerSubtitle(for kind: SynthesisProviderKind) -> String {
        switch kind {
        case .apple: return "on-device"
        case .ollama: return "local server"
        case .anthropic: return "cloud · BYOK"
        }
    }

    private func selectProvider(_ kind: SynthesisProviderKind) {
        guard kind != providerKind else { return }
        providerKind = kind
        UserDefaults.standard.set(kind.rawValue, forKey: CompanionManager.synthesisProviderKindKey)
        companionManager.refreshSynthesisProvider()
        flashSynthesisMessage("Provider set to \(kind.displayName)")
    }

    private var appleProviderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Model")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 56, alignment: .leading)
                Text("Apple Foundation Model (system)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
            }
            HStack(spacing: 6) {
                Image(systemName: isAppleAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(isAppleAvailable ? DS.Colors.success : Color(red: 0.85, green: 0.55, blue: 0.2))
                Text(appleStatusText)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
            }
            Text("Apple ships a single on-device foundation model that updates with macOS — there's no model picker here. Switch to Ollama if you want to choose a specific model.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ollamaConfigRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Model")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 56, alignment: .leading)
                TextField(OllamaProvider.defaultModel, text: $ollamaModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            HStack(spacing: 6) {
                Text("Host")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 56, alignment: .leading)
                TextField(OllamaProvider.defaultBaseURLString, text: $ollamaBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            HStack {
                Spacer()
                Button {
                    saveOllamaConfig()
                } label: {
                    Text("Save")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(canSaveOllamaConfig ? DS.Colors.accent : DS.Colors.accent.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(!canSaveOllamaConfig)
            }
        }
    }

    private var ollamaHelpText: String {
        "Runs synthesis through a local Ollama server. Install with `brew install ollama`, start with `brew services start ollama`, then `ollama pull \(OllamaProvider.defaultModel)` (or another model you set above). Nothing leaves your machine."
    }

    // MARK: - Anthropic config

    /// Curated list of Claude model IDs offered in the picker. Power
    /// users wanting a specific dated version can override via the
    /// `anthropicModel` UserDefaults key directly.
    private static let anthropicModelOptions: [(id: String, label: String)] = [
        ("claude-opus-4-7", "Opus 4.7 — highest quality"),
        ("claude-sonnet-4-6", "Sonnet 4.6 — balanced"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5 — fast & cheap")
    ]

    private var anthropicConfigRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Model")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 56, alignment: .leading)
                anthropicModelMenu
                Spacer()
            }

            if hasStoredAnthropicKey {
                HStack(spacing: 6) {
                    Text("Key")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 56, alignment: .leading)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.success)
                    Text("Saved in Keychain")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Button {
                        removeAnthropicKey()
                    } label: {
                        Text("Remove")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(red: 0.85, green: 0.3, blue: 0.3))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(Color(red: 0.85, green: 0.3, blue: 0.3).opacity(0.5), lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            } else {
                HStack(spacing: 6) {
                    Text("Key")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 56, alignment: .leading)
                    SecureField("sk-ant-...", text: $anthropicKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                HStack {
                    Spacer()
                    Button {
                        saveAnthropicKey()
                    } label: {
                        Text("Save key")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(canSaveAnthropicKey ? DS.Colors.accent : DS.Colors.accent.opacity(0.4)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(!canSaveAnthropicKey)
                }
            }
        }
    }

    private var anthropicHelpText: String {
        "Sends synthesis requests to Anthropic's Claude API. Your key is stored in the macOS Keychain and travels only on outbound API calls. Get a key at console.anthropic.com. This is the only provider that leaves your device."
    }

    private var anthropicModelMenu: some View {
        Menu {
            ForEach(Self.anthropicModelOptions, id: \.id) { option in
                Button {
                    selectAnthropicModel(option.id)
                } label: {
                    if option.id == anthropicModel {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentAnthropicModelLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: 220, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .pointerCursor()
    }

    private var currentAnthropicModelLabel: String {
        Self.anthropicModelOptions.first(where: { $0.id == anthropicModel })?.label ?? anthropicModel
    }

    private func selectAnthropicModel(_ modelID: String) {
        guard modelID != anthropicModel else { return }
        anthropicModel = modelID
        UserDefaults.standard.set(modelID, forKey: CompanionManager.anthropicModelKey)
        if hasStoredAnthropicKey {
            companionManager.refreshSynthesisProvider()
            flashSynthesisMessage("Model set to \(modelID)")
        }
    }

    private var canSaveAnthropicKey: Bool {
        let trimmedKey = anthropicKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedKey.hasPrefix("sk-ant-")
    }

    private func saveAnthropicKey() {
        let trimmedKey = anthropicKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainService.save(key: CompanionManager.anthropicAPIKeyKeychainKey, value: trimmedKey)
            hasStoredAnthropicKey = true
            anthropicKeyInput = ""
            // Make sure the picker's current selection is also
            // persisted, in case the user changed it before saving.
            UserDefaults.standard.set(anthropicModel, forKey: CompanionManager.anthropicModelKey)
            companionManager.refreshSynthesisProvider()
            flashSynthesisMessage("Claude configured")
        } catch {
            flashSynthesisMessage("Save failed: \(error.localizedDescription)")
        }
    }

    private func removeAnthropicKey() {
        KeychainService.delete(key: CompanionManager.anthropicAPIKeyKeychainKey)
        hasStoredAnthropicKey = false
        anthropicKeyInput = ""
        companionManager.refreshSynthesisProvider()
        flashSynthesisMessage("Key removed")
    }

    private var isAppleAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AppleFoundationProvider.isAvailable
        }
        #endif
        return false
    }

    private var appleStatusText: String {
        if isAppleAvailable {
            return "On-device model ready"
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return "Unavailable — enable Apple Intelligence in System Settings"
        }
        #endif
        return "Requires macOS 26 Tahoe with Apple Intelligence"
    }

    private var canSaveOllamaConfig: Bool {
        let trimmedModel = ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedModel.isEmpty && URL(string: trimmedURL) != nil
    }

    private func loadProviderPreferences() {
        let stored = UserDefaults.standard.string(forKey: CompanionManager.synthesisProviderKindKey)
            .flatMap(SynthesisProviderKind.init(rawValue:))
        // Mirror the launch resolver: if no preference, default the
        // picker to Apple when available, otherwise Ollama.
        if let stored {
            providerKind = stored
        } else {
            providerKind = isAppleAvailable ? .apple : .ollama
        }
        ollamaModel = UserDefaults.standard.string(forKey: CompanionManager.ollamaModelKey)
            ?? OllamaProvider.defaultModel
        ollamaBaseURL = UserDefaults.standard.string(forKey: CompanionManager.ollamaBaseURLKey)
            ?? OllamaProvider.defaultBaseURLString
        let storedAnthropicModel = UserDefaults.standard.string(forKey: CompanionManager.anthropicModelKey)
            ?? AnthropicProvider.defaultModel
        // If the stored model isn't one of the curated picker options
        // (e.g. someone upgraded from an older build that defaulted
        // differently), snap to the default so the menu has a visible
        // selection rather than rendering blank.
        let knownIDs = Self.anthropicModelOptions.map(\.id)
        anthropicModel = knownIDs.contains(storedAnthropicModel) ? storedAnthropicModel : AnthropicProvider.defaultModel
    }

    private func saveOllamaConfig() {
        let trimmedModel = ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmedModel, forKey: CompanionManager.ollamaModelKey)
        UserDefaults.standard.set(trimmedURL, forKey: CompanionManager.ollamaBaseURLKey)
        companionManager.refreshSynthesisProvider()
        flashSynthesisMessage("Ollama config saved")
    }

    private func flashSynthesisMessage(_ text: String) {
        synthesisMessage = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation { synthesisMessage = nil }
        }
    }

    // MARK: - NU PAT

    private var nuPATSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NEIGHBORHOODUNITED PAT")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)

            if hasStoredNUPAT {
                storedNUPATRow
            } else {
                nuPATInputRow
            }

            Text("Personal Access Token used to upload synthesized sessions to your NU instance. Mint one in the NU admin (Connected Apps). Stored in macOS Keychain.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let message = nuSaveMessage {
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.success)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private var storedNUPATRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.success)
                Text("PAT saved")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Spacer()
            Button {
                removeNUPAT()
            } label: {
                Text("Remove")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(red: 0.85, green: 0.3, blue: 0.3))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .stroke(Color(red: 0.85, green: 0.3, blue: 0.3).opacity(0.5), lineWidth: 0.8)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private var nuPATInputRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("pat_...", text: $nuPATInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

            HStack {
                Spacer()
                Button {
                    saveNUPAT()
                } label: {
                    Text("Save PAT")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(canSaveNUPAT ? DS.Colors.accent : DS.Colors.accent.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(!canSaveNUPAT)
            }
        }
    }

    private var canSaveNUPAT: Bool {
        let trimmed = nuPATInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.hasPrefix("pat_")
    }

    private func saveNUPAT() {
        let trimmed = nuPATInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainService.save(key: CompanionManager.nuPATKeychainKey, value: trimmed)
            hasStoredNUPAT = true
            nuPATInput = ""
            companionManager.refreshNUClient()
            flashNUMessage("PAT saved")
        } catch {
            flashNUMessage("Save failed: \(error.localizedDescription)")
        }
    }

    private func removeNUPAT() {
        KeychainService.delete(key: CompanionManager.nuPATKeychainKey)
        hasStoredNUPAT = false
        nuPATInput = ""
        companionManager.refreshNUClient()
        flashNUMessage("PAT removed")
    }

    // MARK: - Recording

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECORDING")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)

            Toggle(isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: "includeSelfInRecording") },
                set: { UserDefaults.standard.set($0, forKey: "includeSelfInRecording") }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include YardTalk in recording")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("Shows the menu bar panel in screen captures. Useful for demos and sharing settings.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private func flashNUMessage(_ text: String) {
        nuSaveMessage = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation { nuSaveMessage = nil }
        }
    }
}
