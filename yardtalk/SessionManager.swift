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

import Foundation
import Observation

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
    }

    func stop() {
        hotkeyMonitor.stop()
    }

    // MARK: - Hotkey handlers

    private func handleHotkeyPress() {
        guard status == .idle else { return }
        guard let project = projectStore.activeProject else {
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
            status = .failed(message: "Could not prepare clips directory: \(error.localizedDescription)")
            return
        }

        let recorder = SessionRecorder(outputURL: outputURL)
        activeRecorder = recorder
        activeClipDraft = ClipDraft(id: clipID, projectID: project.id, fileName: fileName)
        status = .recording

        Task { @MainActor in
            do {
                try await recorder.start()
            } catch {
                self.activeRecorder = nil
                self.activeClipDraft = nil
                self.status = .failed(message: error.localizedDescription)
            }
        }
    }

    private func handleHotkeyRelease() {
        guard status == .recording else { return }
        guard let recorder = activeRecorder, let draft = activeClipDraft else {
            status = .idle
            return
        }
        status = .finishing

        Task { @MainActor in
            do {
                let (_, duration) = try await recorder.stop()
                self.activeRecorder = nil
                self.activeClipDraft = nil

                let clip = YardTalkClip(
                    id: draft.id,
                    projectID: draft.projectID,
                    fileName: draft.fileName,
                    durationSeconds: duration
                )
                try self.clipStore.add(clip)
                self.status = .idle
                self.transcribeInBackground(clip: clip)
            } catch {
                self.activeRecorder = nil
                self.activeClipDraft = nil
                self.status = .failed(message: error.localizedDescription)
            }
        }
    }

    private func transcribeInBackground(clip: YardTalkClip) {
        Task { @MainActor in
            let videoURL = clipStore.videoFileURL(for: clip)
            do {
                let transcript = try await transcriptionService.transcribe(fileAt: videoURL)
                var updated = clip
                updated.transcript = transcript
                try? clipStore.update(updated)
            } catch {
                var updated = clip
                updated.transcriptionError = error.localizedDescription
                try? clipStore.update(updated)
            }
        }
    }
}
