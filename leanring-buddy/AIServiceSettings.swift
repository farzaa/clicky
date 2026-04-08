//
//  AIServiceSettings.swift
//  leanring-buddy
//
//  Local persisted settings for OpenRouter and ElevenLabs.
//

import Foundation
import Combine

@MainActor
final class AIServiceSettings: ObservableObject {
    @Published var selectedOpenRouterModelID: String
    @Published var elevenLabsVoiceID: String
    @Published var openRouterAPIKey: String = ""
    @Published var elevenLabsAPIKey: String = ""

    private let secureSettingsStore = SecureSettingsStore()
    private let selectedOpenRouterModelDefaultsKey = "selectedOpenRouterModelID"
    private let elevenLabsVoiceIDDefaultsKey = "elevenLabsVoiceID"

    init() {
        selectedOpenRouterModelID = UserDefaults.standard.string(forKey: selectedOpenRouterModelDefaultsKey)
            ?? "openai/gpt-4o-mini"
        elevenLabsVoiceID = UserDefaults.standard.string(forKey: elevenLabsVoiceIDDefaultsKey)
            ?? "EXAVITQu4vr4xnSDxMaL"
        reloadSecureValues()
    }

    func saveSelectedOpenRouterModelID(_ selectedOpenRouterModelID: String) {
        let trimmedSelectedOpenRouterModelID = selectedOpenRouterModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSelectedOpenRouterModelID.isEmpty else { return }
        self.selectedOpenRouterModelID = trimmedSelectedOpenRouterModelID
        UserDefaults.standard.set(trimmedSelectedOpenRouterModelID, forKey: selectedOpenRouterModelDefaultsKey)
    }

    func saveElevenLabsVoiceID(_ elevenLabsVoiceID: String) {
        let trimmedElevenLabsVoiceID = elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.elevenLabsVoiceID = trimmedElevenLabsVoiceID
        UserDefaults.standard.set(trimmedElevenLabsVoiceID, forKey: elevenLabsVoiceIDDefaultsKey)
    }

    func saveOpenRouterAPIKey(_ openRouterAPIKey: String) throws {
        try secureSettingsStore.setStringValue(openRouterAPIKey, for: .openRouterAPIKey)
        self.openRouterAPIKey = openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func saveElevenLabsAPIKey(_ elevenLabsAPIKey: String) throws {
        try secureSettingsStore.setStringValue(elevenLabsAPIKey, for: .elevenLabsAPIKey)
        self.elevenLabsAPIKey = elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func reloadSecureValues() {
        do {
            openRouterAPIKey = try secureSettingsStore.stringValue(for: .openRouterAPIKey) ?? ""
        } catch {
            openRouterAPIKey = ""
            print("⚠️ Settings: could not load OpenRouter API key: \(error.localizedDescription)")
        }

        do {
            elevenLabsAPIKey = try secureSettingsStore.stringValue(for: .elevenLabsAPIKey) ?? ""
        } catch {
            elevenLabsAPIKey = ""
            print("⚠️ Settings: could not load ElevenLabs API key: \(error.localizedDescription)")
        }
    }

    var hasOpenRouterAPIKey: Bool {
        !openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasElevenLabsAPIKey: Bool {
        !elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
