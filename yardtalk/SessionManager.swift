//
//  SessionManager.swift
//  yardtalk
//
//  Wires HotkeyMonitor → SessionRecorder → ClipStore → TranscriptionService.
//  Hold ⌃⌥ to start recording into the active project's clips directory;
//  release to finalize. Transcription kicks off async after stop so back-
//  to-back recordings work without blocking on the previous clip's
//  transcript. There is no "session" concept yet — every clip is loose
//  metadata under its project. End-of-session synthesis lands later and
//  will group nearby clips.
//
//  The release handler awaits the start Task before tearing down. Without
//  that, a brief tap-and-release runs stop() concurrently with start()
//  and produces a 0-byte file. With it, very-short holds still complete
//  start() before stopping (so the file is at least structurally valid),
//  and we drop clips shorter than 0.5s as junk afterward.
//

import Foundation
import Observation
import OSLog

extension Logger {
    static let session = Logger(subsystem: "com.yardtalk.app", category: "session")
}

@MainActor
@Observable
final class SessionManager {
    enum Status: Equatable {
        case idle
        case recording
        case finishing
        case failed(message: String)
    }

    private(set) var status: Status = .idle
    /// Live mic level during recording, normalized 0...1. Stays at 0 when
    /// idle. A flat value during recording is a visible signal that the mic
    /// isn't capturing anything — the user can release the hotkey, fix the
    /// input, and try again rather than discovering the silence after the
    /// fact via an empty transcript.
    private(set) var audioLevel: Float = 0

    @ObservationIgnored
    private let hotkeyMonitor = HotkeyMonitor()

    @ObservationIgnored
    private let projectStore: ProjectStore

    @ObservationIgnored
    private let clipStore: ClipStore

    @ObservationIgnored
    private let transcriptionService: TranscriptionService

    @ObservationIgnored
    private var activeRecorder: SessionRecorder?

    @ObservationIgnored
    private var activeClipDraft: ClipDraft?

    @ObservationIgnored
    private var activeStartTask: Task<Void, Error>?

    /// Clips below this duration are discarded — usually a hotkey
    /// tap-and-release before the capture pipeline could meaningfully
    /// produce content.
    private let minimumClipDuration: TimeInterval = 0.5

    private struct ClipDraft {
        let id: UUID
        let projectID: UUID
        let fileName: String
    }

    init(
        projectStore: ProjectStore,
        clipStore: ClipStore,
        transcriptionService: TranscriptionService
    ) {
        self.projectStore = projectStore
        self.clipStore = clipStore
        self.transcriptionService = transcriptionService

        hotkeyMonitor.onPress = { [weak self] in
            self?.handleHotkeyPress()
        }
        hotkeyMonitor.onRelease = { [weak self] in
            self?.handleHotkeyRelease()
        }
    }

    func start() {
        hotkeyMonitor.start()
        Logger.session.info("SessionManager started — hotkey monitor armed")
    }

    func stop() {
        hotkeyMonitor.stop()
    }

    // MARK: - Hotkey handlers

    private func handleHotkeyPress() {
        switch status {
        case .recording, .finishing: return
        default: break
        }
        guard let project = projectStore.activeProject else {
            Logger.session.warning("Hotkey pressed with no active project")
            status = .failed(message: "Select a project before recording.")
            return
        }

        let clipID = UUID()
        let fileName = "\(clipID.uuidString).mp4"
        let outputURL = clipStore.clipsDirectory(for: project.id)
            .appendingPathComponent(fileName)

        do {
            try FileManager.default.createDirectory(
                at: clipStore.clipsDirectory(for: project.id),
                withIntermediateDirectories: true
            )
        } catch {
            Logger.session.error("Could not create clips directory: \(error.localizedDescription, privacy: .public)")
            status = .failed(message: "Could not prepare clips directory: \(error.localizedDescription)")
            return
        }

        let recorder = SessionRecorder(outputURL: outputURL)
        recorder.onAudioLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.audioLevel = level
            }
        }
        activeRecorder = recorder
        activeClipDraft = ClipDraft(id: clipID, projectID: project.id, fileName: fileName)
        // Hold the start Task so the release handler can await it before
        // calling stop(). Otherwise a fast tap-and-release races start
        // against stop and produces an unfinalized file.
        activeStartTask = Task<Void, Error> {
            try await recorder.start()
        }
        status = .recording
        Logger.session.info("Recording started for clip \(clipID.uuidString, privacy: .public) in project \(project.name, privacy: .public)")
    }

    private func handleHotkeyRelease() {
        guard status == .recording else { return }
        guard let recorder = activeRecorder, let draft = activeClipDraft else {
            status = .idle
            return
        }
        let startTask = activeStartTask
        status = .finishing

        Task { @MainActor in
            // Wait for start to complete (or fail) before tearing down,
            // otherwise a tap shorter than the capture-startup latency
            // would race start() against stop().
            if let startTask {
                do {
                    try await startTask.value
                } catch {
                    Logger.session.error("start() failed: \(error.localizedDescription, privacy: .public)")
                    self.cleanupAfterFailure(message: "Recording failed to start: \(error.localizedDescription)")
                    return
                }
            }

            do {
                let (_, duration) = try await recorder.stop()
                self.activeRecorder = nil
                self.activeClipDraft = nil
                self.activeStartTask = nil

                guard duration >= self.minimumClipDuration else {
                    Logger.session.info("Discarded short clip (\(duration, privacy: .public)s, threshold \(self.minimumClipDuration, privacy: .public)s)")
                    let videoURL = self.clipStore.clipsDirectory(for: draft.projectID)
                        .appendingPathComponent(draft.fileName)
                    try? FileManager.default.removeItem(at: videoURL)
                    self.status = .idle
                    return
                }

                let clip = YardTalkClip(
                    id: draft.id,
                    projectID: draft.projectID,
                    fileName: draft.fileName,
                    durationSeconds: duration
                )
                try self.clipStore.add(clip)
                Logger.session.info("Saved clip \(clip.id.uuidString, privacy: .public) (\(duration, privacy: .public)s)")
                self.status = .idle
                self.transcribeInBackground(clip: clip)
            } catch {
                Logger.session.error("stop() failed: \(error.localizedDescription, privacy: .public)")
                self.cleanupAfterFailure(message: error.localizedDescription)
            }
        }
    }

    private func cleanupAfterFailure(message: String) {
        self.activeRecorder = nil
        self.activeClipDraft = nil
        self.activeStartTask = nil
        self.status = .failed(message: message)
    }

    private func transcribeInBackground(clip: YardTalkClip) {
        Task { @MainActor in
            let videoURL = clipStore.videoFileURL(for: clip)
            do {
                let transcript = try await transcriptionService.transcribe(fileAt: videoURL)
                var updated = clip
                updated.transcript = transcript
                try? clipStore.update(updated)
                Logger.session.info("Transcribed clip \(clip.id.uuidString, privacy: .public): \(transcript.count, privacy: .public) chars")
            } catch {
                var updated = clip
                updated.transcriptionError = error.localizedDescription
                try? clipStore.update(updated)
                Logger.session.error("Transcription failed for \(clip.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
