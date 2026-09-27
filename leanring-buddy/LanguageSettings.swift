//
//  LanguageSettings.swift
//  leanring-buddy
//
//  Shared, UserDefaults-backed store for dictation language preferences.
//  All transcription providers read from here so the choice is consistent.
//

import Foundation

/// A language the user can select for manual dictation.
struct DictationLanguage: Identifiable, Equatable {
    /// BCP-47 tag sent to transcription APIs (e.g. "en", "pl", "ru").
    let id: String
    /// Human-readable label shown in the UI.
    let displayName: String
    /// Apple locale identifier used to build SFSpeechRecognizer (e.g. "en-US").
    let localeIdentifier: String
}

/// The full catalogue of languages Clicky exposes for manual selection.
/// Extend this list to add more languages — no other code changes needed.
extension DictationLanguage {
    static let catalogue: [DictationLanguage] = [
        DictationLanguage(id: "en",    displayName: "English",    localeIdentifier: "en-US"),
        DictationLanguage(id: "zh",    displayName: "Chinese",    localeIdentifier: "zh-CN"),
        DictationLanguage(id: "de",    displayName: "German",     localeIdentifier: "de-DE"),
        DictationLanguage(id: "es",    displayName: "Spanish",    localeIdentifier: "es-ES"),
        DictationLanguage(id: "fr",    displayName: "French",     localeIdentifier: "fr-FR"),
        DictationLanguage(id: "hi",    displayName: "Hindi",      localeIdentifier: "hi-IN"),
        DictationLanguage(id: "it",    displayName: "Italian",    localeIdentifier: "it-IT"),
        DictationLanguage(id: "ja",    displayName: "Japanese",   localeIdentifier: "ja-JP"),
        DictationLanguage(id: "ko",    displayName: "Korean",     localeIdentifier: "ko-KR"),
        DictationLanguage(id: "nl",    displayName: "Dutch",      localeIdentifier: "nl-NL"),
        DictationLanguage(id: "pl",    displayName: "Polish",     localeIdentifier: "pl-PL"),
        DictationLanguage(id: "pt",    displayName: "Portuguese", localeIdentifier: "pt-BR"),
        DictationLanguage(id: "ru",    displayName: "Russian",    localeIdentifier: "ru-RU"),
        DictationLanguage(id: "sv",    displayName: "Swedish",    localeIdentifier: "sv-SE"),
        DictationLanguage(id: "tr",    displayName: "Turkish",    localeIdentifier: "tr-TR"),
        DictationLanguage(id: "uk",    displayName: "Ukrainian",  localeIdentifier: "uk-UA"),
    ]

    static func language(forID id: String) -> DictationLanguage? {
        catalogue.first { $0.id == id }
    }
}

// MARK: - Persistence keys

private enum LanguageSettingsKey {
    static let autoDetect = "dictationAutoDetectLanguage"
    static let selectedIDs = "dictationSelectedLanguageIDs"
}

// MARK: - LanguageSettings

/// Observable store. Bind SwiftUI views directly to its published properties.
final class LanguageSettings: ObservableObject {

    static let shared = LanguageSettings()

    // MARK: Published state

    /// When `true` every provider uses its own auto-detection heuristics.
    /// When `false` only the user-selected languages are considered.
    @Published var autoDetect: Bool {
        didSet {
            UserDefaults.standard.set(autoDetect, forKey: LanguageSettingsKey.autoDetect)
        }
    }

    /// The BCP-47 IDs of the languages chosen for manual mode.
    /// Always contains at least one entry (falls back to English).
    @Published var selectedLanguageIDs: Set<String> {
        didSet {
            let ids = Array(selectedLanguageIDs)
            UserDefaults.standard.set(ids, forKey: LanguageSettingsKey.selectedIDs)
        }
    }

    // MARK: Derived convenience

    /// Resolved `DictationLanguage` objects for the current selection.
    var selectedLanguages: [DictationLanguage] {
        selectedLanguageIDs
            .compactMap { DictationLanguage.language(forID: $0) }
            .sorted { $0.displayName < $1.displayName }
    }

    /// The single BCP-47 language tag to pass to APIs that only accept one
    /// language (OpenAI Whisper, AssemblyAI).  Returns `nil` when auto-detect
    /// is enabled so callers can omit the field and let the API decide.
    var primaryLanguageID: String? {
        guard !autoDetect else { return nil }
        // Prefer English if it's in the selection, otherwise pick alphabetically.
        if selectedLanguageIDs.contains("en") { return "en" }
        return selectedLanguages.first?.id
    }

    /// Locale objects for providers like Apple Speech that take one locale at
    /// a time.  When auto-detect is on this is `nil` so callers fall back to
    /// `Locale.autoupdatingCurrent`.
    var preferredLocales: [Locale]? {
        guard !autoDetect else { return nil }
        return selectedLanguages.map { Locale(identifier: $0.localeIdentifier) }
    }

    // MARK: Init

    private init() {
        // Load persisted auto-detect preference (defaults to true on first launch).
        let storedAutoDetect = UserDefaults.standard.object(forKey: LanguageSettingsKey.autoDetect)
        self.autoDetect = storedAutoDetect.flatMap { $0 as? Bool } ?? true

        // Load persisted language IDs (defaults to English on first launch).
        let storedIDs = UserDefaults.standard.stringArray(forKey: LanguageSettingsKey.selectedIDs)
        if let storedIDs, !storedIDs.isEmpty {
            self.selectedLanguageIDs = Set(storedIDs)
        } else {
            self.selectedLanguageIDs = ["en"]
        }
    }

    // MARK: Mutations

    func toggleLanguage(_ language: DictationLanguage) {
        if selectedLanguageIDs.contains(language.id) {
            // Never allow deselecting the last language.
            guard selectedLanguageIDs.count > 1 else { return }
            selectedLanguageIDs.remove(language.id)
        } else {
            selectedLanguageIDs.insert(language.id)
        }
    }
}
