//
//  ConversationEntry.swift
//  leanring-buddy
//
//  A single completed exchange between the user and Claude within the current
//  app session. Used by CompanionManager to track history and by
//  CompanionPanelView to render the session transcript.
//

import Foundation

/// A single completed exchange between the user and Claude within the current app session.
/// Not persisted to disk — lives only as long as the app is running.
struct ConversationEntry: Identifiable {
    let id = UUID()
    let userTranscript: String
    let assistantResponse: String
    let timestamp: Date
}
