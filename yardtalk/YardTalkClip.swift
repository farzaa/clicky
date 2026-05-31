//
//  YardTalkClip.swift
//  yardtalk
//
//  A single recorded clip belonging to a YardTalkProject and (in the
//  session model added in M1) to a YardTalkSession. A clip is either a
//  short MP4 (screen video + mic audio) or — when `audioOnly` is true — a
//  voice note: an M4A with mic audio and no screen capture. Both are saved
//  alongside their metadata JSON under the project's clips/ directory. The
//  transcript is filled in asynchronously by FluidAudio after recording
//  finishes; that path is identical for both kinds.
//

import Foundation

struct YardTalkClip: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let projectID: UUID
    /// Session this clip belongs to. `nil` for clips recorded before the
    /// session model existed; SessionManager migrates these on first launch
    /// into a synthetic "Imported" session per project.
    var sessionID: UUID?
    let fileName: String
    let recordedAt: Date
    var durationSeconds: Double
    /// `nil` while transcription is pending or running. Empty string means
    /// transcription completed but Parakeet returned no text (silence,
    /// non-speech audio). Non-empty is the actual transcript.
    var transcript: String?
    var transcriptionError: String?
    /// Timestamps (seconds, relative to clip start) where the user dropped
    /// a marker via ⌃⌥M during recording. Used downstream by video output
    /// templates (M8) — pen-test "proof moment" markers and HyperFrames
    /// B-roll cut lists both consume this directly.
    var markers: [TimeInterval]
    /// True when this clip is a voice-only note (mic audio, no screen
    /// capture) stored as M4A. Defaults to false so clips persisted before
    /// this field existed decode cleanly as ordinary screen clips.
    var audioOnly: Bool

    init(
        id: UUID = UUID(),
        projectID: UUID,
        sessionID: UUID? = nil,
        fileName: String,
        recordedAt: Date = Date(),
        durationSeconds: Double = 0,
        transcript: String? = nil,
        transcriptionError: String? = nil,
        markers: [TimeInterval] = [],
        audioOnly: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.sessionID = sessionID
        self.fileName = fileName
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.transcript = transcript
        self.transcriptionError = transcriptionError
        self.markers = markers
        self.audioOnly = audioOnly
    }

    // Custom decoder so clip JSONs written before later fields existed
    // (no `sessionID`, no `markers`, no `audioOnly`) still load. The
    // synthesized init(from:) would throw keyNotFound on the missing keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.projectID = try c.decode(UUID.self, forKey: .projectID)
        self.sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        self.fileName = try c.decode(String.self, forKey: .fileName)
        self.recordedAt = try c.decode(Date.self, forKey: .recordedAt)
        self.durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        self.transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        self.transcriptionError = try c.decodeIfPresent(String.self, forKey: .transcriptionError)
        self.markers = try c.decodeIfPresent([TimeInterval].self, forKey: .markers) ?? []
        self.audioOnly = try c.decodeIfPresent(Bool.self, forKey: .audioOnly) ?? false
    }
}
