//
//  CompanionServicePreferences.swift
//  leanring-buddy
//
//  User-selectable providers for reasoning and spoken output.
//

import Foundation

enum CompanionAIProvider: String, CaseIterable, Identifiable {
    case openAI
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .claude: return "Claude"
        }
    }
}

enum CompanionSpeechOutputProvider: String, CaseIterable, Identifiable {
    case system
    case elevenLabs
    case silent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "Mac Voice"
        case .elevenLabs: return "ElevenLabs"
        case .silent: return "Text Only"
        }
    }
}
