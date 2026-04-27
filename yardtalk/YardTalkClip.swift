//
//  YardTalkClip.swift
//  yardtalk
//
//  A single recorded clip belonging to a YardTalkProject. The clip is a
//  short MP4 (screen video + mic audio) saved alongside its metadata JSON
//  under the project's clips/ directory. The transcript is filled in
//  asynchronously by FluidAudio after recording finishes.
//

import Foundation

struct YardTalkClip: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let projectID: UUID
    let fileName: String
    let recordedAt: Date
    var durationSeconds: Double
    /// `nil` while transcription is pending or running. Empty string means
    /// transcription completed but Parakeet returned no text (silence,
    /// non-speech audio). Non-empty is the actual transcript.
    var transcript: String?
    var transcriptionError: String?

    init(
        id: UUID = UUID(),
        projectID: UUID,
        fileName: String,
        recordedAt: Date = Date(),
        durationSeconds: Double = 0,
        transcript: String? = nil,
        transcriptionError: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.fileName = fileName
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.transcript = transcript
        self.transcriptionError = transcriptionError
    }
}
