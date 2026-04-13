//
//  TFTMetaContext.swift
//  leanring-buddy
//
//  Local, manually refreshed TFT patch/meta snapshot. This keeps the app fully
//  self-contained while still giving the assistant recent TFT context.
//

import Foundation

struct TFTMetaContextSnapshot: Equatable {
    let snapshotUpdatedOn: String
    let latestPatchTitle: String
    let latestPatchPublishedAt: String
    let latestPatchURL: String
    let dataDragonVersion: String
    let metaNotes: [String]
}

enum TFTMetaKnowledgeBase {
    // BEGIN_AUTOGEN_TFT_SNAPSHOT
    static let currentSnapshot = TFTMetaContextSnapshot(
        snapshotUpdatedOn: "2026-04-13",
        latestPatchTitle: "Teamfight Tactics patch 16.8",
        latestPatchPublishedAt: "2026-03-31T18:00:00.000Z",
        latestPatchURL: "https://teamfighttactics.leagueoflegends.com/en-ph/news/game-updates/teamfight-tactics-patch-16-8/",
        dataDragonVersion: "16.7.1",
        metaNotes: [
            "This is a manually maintained snapshot, not a live API feed. State confidence when meta calls are uncertain.",
            "Patch notes are the source of truth for current balance direction.",
            "Use the current board/shop/items shown on screen to make final recommendations.",
        ]
    )
    // END_AUTOGEN_TFT_SNAPSHOT
}

enum TFTMetaPromptBuilder {
    static func buildPromptContext() -> String {
        let snapshot = TFTMetaKnowledgeBase.currentSnapshot
        let notes = snapshot.metaNotes.enumerated().map { index, value in
            "\(index + 1). \(value)"
        }.joined(separator: "\n")

        return """
        TFT SNAPSHOT (manual)
        Snapshot last updated: \(snapshot.snapshotUpdatedOn)
        Latest official patch notes: \(snapshot.latestPatchTitle) (\(snapshot.latestPatchPublishedAt))
        Patch notes URL: \(snapshot.latestPatchURL)
        Latest Data Dragon version: \(snapshot.dataDragonVersion)
        Meta notes:
        \(notes)
        """
    }

    static func buildStatusMessage() -> String {
        let snapshot = TFTMetaKnowledgeBase.currentSnapshot
        return "Manual TFT snapshot: \(snapshot.latestPatchTitle), updated \(snapshot.snapshotUpdatedOn)"
    }
}
