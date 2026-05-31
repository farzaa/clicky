//
//  VoiceNoteClipTests.swift
//  yardtalkTests
//
//  Coverage for the voice-note feature's data model. These avoid anything
//  that needs a live mic or capture session — they exercise YardTalkClip's
//  `audioOnly` flag and its Codable back-compatibility, which is where a
//  regression would silently mislabel clips or fail to load old sidecars.
//

import Foundation
import Testing
@testable import YardTalk

struct VoiceNoteClipTests {

    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    @Test func audioOnlyDefaultsToFalse() {
        let clip = YardTalkClip(projectID: UUID(), fileName: "clip.mp4")
        #expect(clip.audioOnly == false)
    }

    @Test func audioOnlyRoundTripsThroughCodable() throws {
        // Use a whole-second date: the .iso8601 strategy drops sub-second
        // precision, so a Date() with fractional seconds would not survive the
        // round-trip and the full-struct equality below would fail spuriously.
        let original = YardTalkClip(
            projectID: UUID(),
            sessionID: UUID(),
            fileName: "note.m4a",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 12.5,
            markers: [1.0, 4.5],
            audioOnly: true
        )

        let data = try makeEncoder().encode(original)
        let decoded = try makeDecoder().decode(YardTalkClip.self, from: data)

        #expect(decoded.audioOnly == true)
        #expect(decoded.fileName == "note.m4a")
        #expect(decoded.markers == [1.0, 4.5])
        #expect(decoded == original)
    }

    /// A clip sidecar written before `audioOnly` existed must still decode —
    /// the custom decoder defaults the missing key to false rather than
    /// throwing keyNotFound. This is the path every pre-existing screen clip
    /// on disk takes after the user updates.
    @Test func legacyJSONWithoutAudioOnlyDecodesAsScreenClip() throws {
        let id = UUID()
        let projectID = UUID()
        let legacyJSON = """
        {
            "id": "\(id.uuidString)",
            "projectID": "\(projectID.uuidString)",
            "fileName": "old-clip.mp4",
            "recordedAt": "2026-01-01T00:00:00Z",
            "durationSeconds": 30
        }
        """

        let decoded = try makeDecoder().decode(
            YardTalkClip.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(decoded.audioOnly == false)
        #expect(decoded.markers == [])
        #expect(decoded.sessionID == nil)
        #expect(decoded.id == id)
    }
}

@MainActor
struct HotkeyMonitorResetTests {

    /// `reset()` clears toggle state without firing onPress/onRelease, so a
    /// press the manager rejects (the other recorder is busy) doesn't leave
    /// the toggle "on" — the next press starts fresh instead of toggling off.
    @Test func resetClearsToggleWithoutFiringCallbacks() {
        let monitor = HotkeyMonitor(mode: .toggle)
        var presses = 0
        var releases = 0
        monitor.onPress = { presses += 1 }
        monitor.onRelease = { releases += 1 }

        monitor.reset()

        #expect(monitor.isActive == false)
        #expect(presses == 0)
        #expect(releases == 0)
    }
}
