//
//  SessionManager.swift
//  yardtalk
//
//  Wires HotkeyMonitor → SessionRecorder → ClipStore → SessionStore →
//  TranscriptionService. Two hotkeys: ⌃⌥D toggles recording; ⌃⌥M drops a
//  marker on the active recording at the moment it's pressed.
//
//  Sessions are created lazily: the first clip that finalizes (≥ 0.5s) in
//  a project with no open session opens one. Subsequent clips attach to
//  the open session. The session ends explicitly via `endActiveSession()`
//  (UI button) or after `sessionIdleTimeoutSeconds` (default 30 min) of
//  no new clip starts. Orphan clips recorded before M1 (no `sessionID`)
//  get folded into a synthetic "Imported" session per project on first
//  load via `migrateOrphanClipsForActiveProject()`.
//
//  The release handler awaits the start Task before tearing down. Without
//  that, a brief tap-and-release runs stop() concurrently with start()
//  and produces a 0-byte file. With it, very-short holds still complete
//  start() before stopping (so the file is at least structurally valid),
//  and we drop clips shorter than 0.5s as junk afterward.
//

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Foundation
import Observation
import OSLog
import ScreenCaptureKit

extension Logger {
    static let session = Logger(subsystem: "com.yardtalk.app", category: "session")
}

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let width: Int
    let height: Int
    let name: String
}

struct AudioDeviceInfo: Identifiable, Equatable {
    let id: String
    let name: String
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
    private(set) var audioLevel: Float = 0
    private(set) var audioWarning: String?
    private(set) var inFlightMarkerCount: Int = 0
    private(set) var availableDisplays: [DisplayInfo] = []
    var selectedDisplayID: CGDirectDisplayID?

    private(set) var availableAudioDevices: [AudioDeviceInfo] = []
    var selectedAudioDeviceID: String? {
        didSet { UserDefaults.standard.set(selectedAudioDeviceID, forKey: "selectedAudioDeviceID") }
    }

    /// Called when the hotkey fires but no display has been selected yet.
    /// The closure receives a completion — call it after the user picks a
    /// screen to resume recording.
    @ObservationIgnored
    var onDisplaySelectionNeeded: ((@escaping () -> Void) -> Void)?

    /// Provides the camera overlay window ID so the recorder can include
    /// it in the capture via `exceptingWindows`. Set by CompanionManager.
    @ObservationIgnored
    var cameraOverlayWindowID: (() -> CGWindowID?)?

    @ObservationIgnored
    private let recordingHotkey = HotkeyMonitor()  // ⌃⌥D, toggle

    @ObservationIgnored
    private let markerHotkey = HotkeyMonitor(
        mode: .tap,
        modifiers: [.control, .option],
        keyCode: UInt16(kVK_ANSI_M)
    )

    @ObservationIgnored
    private let projectStore: ProjectStore

    @ObservationIgnored
    private let clipStore: ClipStore

    @ObservationIgnored
    private let sessionStore: SessionStore

    @ObservationIgnored
    private let transcriptionService: TranscriptionService

    @ObservationIgnored
    private var activeRecorder: SessionRecorder?

    @ObservationIgnored
    private var activeClipDraft: ClipDraft?

    @ObservationIgnored
    private var activeStartTask: Task<Void, Error>?

    @ObservationIgnored
    private var activeMarkers: [TimeInterval] = []

    @ObservationIgnored
    private var recordingStartedAt: Date?

    @ObservationIgnored
    private var idleTimer: Timer?

    private static let fileNameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Clips below this duration are discarded — usually a hotkey
    /// tap-and-release before the capture pipeline could meaningfully
    /// produce content.
    private let minimumClipDuration: TimeInterval = 0.5

    /// Locked at 30min for v1; per-project override is a later milestone.
    /// Pen-test sessions can have long idle gaps (waiting on scans), so
    /// this floor will need to be configurable before pen-test ships.
    private let sessionIdleTimeoutSeconds: TimeInterval = 30 * 60

    private struct ClipDraft {
        let id: UUID
        let projectID: UUID
        let fileName: String
    }

    init(
        projectStore: ProjectStore,
        clipStore: ClipStore,
        sessionStore: SessionStore,
        transcriptionService: TranscriptionService
    ) {
        self.projectStore = projectStore
        self.clipStore = clipStore
        self.sessionStore = sessionStore
        self.transcriptionService = transcriptionService

        recordingHotkey.onPress = { [weak self] in
            self?.handleRecordingHotkeyPress()
        }
        recordingHotkey.onRelease = { [weak self] in
            self?.handleRecordingHotkeyRelease()
        }
        markerHotkey.onPress = { [weak self] in
            self?.handleMarkerHotkey()
        }
    }

    @ObservationIgnored
    private var deviceObservers: [NSObjectProtocol] = []

    func start() {
        recordingHotkey.start()
        markerHotkey.start()
        Logger.session.info("SessionManager started — recording (⌃⌥D) and marker (⌃⌥M) hotkeys armed")
        selectedAudioDeviceID = UserDefaults.standard.string(forKey: "selectedAudioDeviceID")
        refreshAudioDevices()
        Task { await refreshDisplays() }
        observeDeviceChanges()
    }

    func refreshDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let screens = NSScreen.screens
            availableDisplays = content.displays.map { scDisplay in
                let cgID = scDisplay.displayID
                let screenName = screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == cgID
                })?.localizedName ?? "Display \(cgID)"
                return DisplayInfo(
                    id: cgID,
                    width: scDisplay.width,
                    height: scDisplay.height,
                    name: screenName
                )
            }
            if selectedDisplayID == nil || !availableDisplays.contains(where: { $0.id == selectedDisplayID }) {
                selectedDisplayID = availableDisplays.first?.id
            }
        } catch {
            Logger.session.error("Failed to enumerate displays: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshAudioDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        availableAudioDevices = discovery.devices.map {
            AudioDeviceInfo(id: $0.uniqueID, name: $0.localizedName)
        }
        if selectedAudioDeviceID == nil ||
            !availableAudioDevices.contains(where: { $0.id == selectedAudioDeviceID }) {
            selectedAudioDeviceID = availableAudioDevices.first?.id
        }
    }

    func stop() {
        recordingHotkey.stop()
        markerHotkey.stop()
        idleTimer?.invalidate()
        idleTimer = nil
        for observer in deviceObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        deviceObservers.removeAll()
    }

    private func observeDeviceChanges() {
        let nc = NotificationCenter.default
        let audioConnected = nc.addObserver(
            forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.object as? AVCaptureDevice)?.hasMediaType(.audio) == true else { return }
            guard let self else { return }
            Task { @MainActor in self.refreshAudioDevices() }
        }
        let audioDisconnected = nc.addObserver(
            forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.object as? AVCaptureDevice)?.hasMediaType(.audio) == true else { return }
            guard let self else { return }
            Task { @MainActor in self.refreshAudioDevices() }
        }
        let screenChanged = nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refreshDisplays() }
        }
        deviceObservers = [audioConnected, audioDisconnected, screenChanged]
    }

    /// Whether a session for the active project is currently `.open` and
    /// accepting new clips. UI uses this to show the "End Session" button.
    var hasOpenSessionForActiveProject: Bool {
        sessionStore.openSessionForActiveProject() != nil
    }

    /// Fired after a session transitions to `.ended` and is persisted.
    /// `shouldSynthesize` is true when the user explicitly ended the
    /// session and false when the idle timer auto-ended it — gives
    /// CompanionManager the policy hook for the locked decision: only
    /// auto-synthesize on user-initiated ends, not on idle timeouts.
    @ObservationIgnored
    var onSessionEnded: ((_ session: YardTalkSession, _ shouldSynthesize: Bool) -> Void)?

    /// Closes the open session for the active project, if any. Idempotent.
    /// Called from the panel's "End Session" button (synthesize: true) and
    /// from the idle timer (synthesize: false).
    func endActiveSession(synthesize: Bool = true) {
        guard var session = sessionStore.openSessionForActiveProject() else { return }
        session.status = .ended
        session.endedAt = Date()
        do {
            try sessionStore.update(session)
            Logger.session.info("Ended session \(session.id.uuidString, privacy: .public) (\(session.clipIDs.count, privacy: .public) clips, synthesize=\(synthesize, privacy: .public))")
        } catch {
            Logger.session.error("Failed to persist session end: \(error.localizedDescription, privacy: .public)")
        }
        idleTimer?.invalidate()
        idleTimer = nil
        onSessionEnded?(session, synthesize)
    }

    /// Folds any clips for the active project that have no `sessionID`
    /// into one synthetic `.ended` session. Idempotent — does nothing once
    /// every clip has a sessionID. Call after switching the active project
    /// (and after `clipStore.setActiveProject`).
    func migrateOrphanClipsForActiveProject() {
        guard let projectID = projectStore.activeProjectID else { return }
        let orphans = clipStore.clipsForActiveProject.filter { $0.sessionID == nil }
        guard !orphans.isEmpty else { return }

        let ordered = orphans.sorted(by: { $0.recordedAt < $1.recordedAt })
        let earliest = ordered.first!.recordedAt
        let latest = ordered.last!
        let endedAt = latest.recordedAt.addingTimeInterval(latest.durationSeconds)

        let synthetic = YardTalkSession(
            projectID: projectID,
            startedAt: earliest,
            endedAt: endedAt,
            clipIDs: ordered.map { $0.id },
            status: .ended
        )

        do {
            try sessionStore.add(synthetic)
            for var clip in ordered {
                clip.sessionID = synthetic.id
                try clipStore.update(clip)
            }
            Logger.session.info("Migrated \(ordered.count, privacy: .public) orphan clips into session \(synthetic.id.uuidString, privacy: .public)")
        } catch {
            Logger.session.error("Orphan migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Recording hotkey

    private func handleRecordingHotkeyPress() {
        switch status {
        case .recording, .finishing: return
        default: break
        }

        if let onDisplaySelectionNeeded {
            onDisplaySelectionNeeded { [weak self] in
                self?.startRecording()
            }
            return
        }

        startRecording()
    }

    private func startRecording() {
        guard let project = projectStore.activeProject else {
            Logger.session.warning("Hotkey pressed with no active project")
            status = .failed(message: "Select a project before recording.")
            return
        }

        let clipID = UUID()
        let safeName = project.name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()
            .prefix(40)
        let stamp = Self.fileNameDateFormatter.string(from: Date())
        let fileName = "\(safeName)_\(stamp).mp4"
        guard let clipsDir = clipStore.clipsDirectory(for: project.id) else {
            Logger.session.error("No location registered for project \(project.id.uuidString, privacy: .public)")
            status = .failed(message: "Project location not configured.")
            return
        }
        let outputURL = clipsDir.appendingPathComponent(fileName)

        do {
            try FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        } catch {
            Logger.session.error("Could not create clips directory: \(error.localizedDescription, privacy: .public)")
            status = .failed(message: "Could not prepare clips directory: \(error.localizedDescription)")
            return
        }

        let recorder = SessionRecorder(outputURL: outputURL, displayID: selectedDisplayID, micDeviceUniqueID: selectedAudioDeviceID, cameraOverlayWindowID: cameraOverlayWindowID?(), includeSelfInRecording: UserDefaults.standard.bool(forKey: "includeSelfInRecording"))
        recorder.onAudioLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.audioLevel = level
            }
        }
        recorder.onAudioNotDetected = { [weak self] in
            Task { @MainActor [weak self] in
                self?.audioWarning = "No audio detected — check your mic input"
            }
        }
        recorder.onStreamStoppedExternally = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                Logger.session.info("Stream stopped externally — finalizing clip")
                self.finalizeRecording()
            }
        }
        activeRecorder = recorder
        activeClipDraft = ClipDraft(id: clipID, projectID: project.id, fileName: fileName)
        activeMarkers = []
        inFlightMarkerCount = 0
        recordingStartedAt = Date()
        // Hold the start Task so the release handler can await it before
        // calling stop(). Otherwise a fast tap-and-release races start
        // against stop and produces an unfinalized file.
        activeStartTask = Task<Void, Error> {
            try await recorder.start()
        }
        status = .recording
        Logger.session.info("Recording started for clip \(clipID.uuidString, privacy: .public) in project \(project.name, privacy: .public)")
    }

    private func handleRecordingHotkeyRelease() {
        finalizeRecording()
    }

    private func finalizeRecording() {
        guard status == .recording else { return }
        guard let recorder = activeRecorder, let draft = activeClipDraft else {
            status = .idle
            return
        }
        let startTask = activeStartTask
        let markersAtStop = activeMarkers
        status = .finishing

        Task { @MainActor in
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
                self.activeMarkers = []
                self.inFlightMarkerCount = 0
                self.recordingStartedAt = nil
                self.audioWarning = nil

                guard duration >= self.minimumClipDuration else {
                    Logger.session.info("Discarded short clip (\(duration, privacy: .public)s, threshold \(self.minimumClipDuration, privacy: .public)s)")
                    if let dir = self.clipStore.clipsDirectory(for: draft.projectID) {
                        try? FileManager.default.removeItem(at: dir.appendingPathComponent(draft.fileName))
                    }
                    self.status = .idle
                    return
                }

                let validMarkers = markersAtStop.filter { $0 <= duration }

                let sessionID = self.attachToOrCreateSession(forProject: draft.projectID, clipID: draft.id)
                let clip = YardTalkClip(
                    id: draft.id,
                    projectID: draft.projectID,
                    sessionID: sessionID,
                    fileName: draft.fileName,
                    durationSeconds: duration,
                    markers: validMarkers
                )
                try self.clipStore.add(clip)
                Logger.session.info("Saved clip \(clip.id.uuidString, privacy: .public) (\(duration, privacy: .public)s, \(validMarkers.count, privacy: .public) markers)")
                self.scheduleIdleTimer()
                self.status = .idle
                self.transcribeInBackground(clip: clip)
            } catch {
                Logger.session.error("stop() failed: \(error.localizedDescription, privacy: .public)")
                self.cleanupAfterFailure(message: error.localizedDescription)
            }
        }
    }

    // MARK: - Marker hotkey

    private func handleMarkerHotkey() {
        guard status == .recording else { return }
        guard let startedAt = recordingStartedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed >= 0 else { return }
        activeMarkers.append(elapsed)
        inFlightMarkerCount = activeMarkers.count
        Logger.session.info("Marker dropped at \(elapsed, privacy: .public)s (#\(self.inFlightMarkerCount, privacy: .public))")
    }

    // MARK: - Session lifecycle

    /// Attaches `clipID` to the active project's open session, creating a
    /// new session if none is open. Returns the session id so the caller
    /// can stamp it onto the clip before persisting.
    private func attachToOrCreateSession(forProject projectID: UUID, clipID: UUID) -> UUID {
        if var session = sessionStore.openSessionForActiveProject() {
            session.clipIDs.append(clipID)
            do {
                try sessionStore.update(session)
            } catch {
                Logger.session.error("Failed to append clip to session: \(error.localizedDescription, privacy: .public)")
            }
            return session.id
        }

        let session = YardTalkSession(
            projectID: projectID,
            clipIDs: [clipID]
        )
        do {
            try sessionStore.add(session)
            Logger.session.info("Opened session \(session.id.uuidString, privacy: .public) for project \(projectID.uuidString, privacy: .public)")
        } catch {
            Logger.session.error("Failed to open session: \(error.localizedDescription, privacy: .public)")
        }
        return session.id
    }

    private func scheduleIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(
            withTimeInterval: sessionIdleTimeoutSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                Logger.session.info("Idle timeout fired — auto-ending session (no synthesis)")
                self.endActiveSession(synthesize: false)
            }
        }
    }

    private func cleanupAfterFailure(message: String) {
        self.activeRecorder = nil
        self.activeClipDraft = nil
        self.activeStartTask = nil
        self.activeMarkers = []
        self.inFlightMarkerCount = 0
        self.recordingStartedAt = nil
        self.audioWarning = nil
        self.status = .failed(message: message)
    }

    func retryTranscription(for clip: YardTalkClip) {
        Logger.session.info("retryTranscription called for clip \(clip.id.uuidString, privacy: .public)")
        var updated = clip
        updated.transcriptionError = nil
        updated.transcript = nil
        do {
            try clipStore.update(updated)
            Logger.session.info("retry: cleared error, starting transcription")
        } catch {
            Logger.session.error("retry: clipStore.update failed: \(error.localizedDescription, privacy: .private)")
        }
        transcribeInBackground(clip: updated)
    }

    private func transcribeInBackground(clip: YardTalkClip) {
        Task { @MainActor in
            guard let videoURL = clipStore.videoFileURL(for: clip) else {
                Logger.session.error("No video URL for clip \(clip.id.uuidString, privacy: .public)")
                return
            }
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? UInt64) ?? 0
            guard fileSize > 0 else {
                Logger.session.warning("skipping empty/missing file for clip \(clip.id.uuidString, privacy: .public)")
                var updated = clip
                updated.transcriptionError = "Recording file is empty — no audio was captured."
                try? clipStore.update(updated)
                return
            }
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
                Logger.session.error("Transcription failed for \(clip.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}
