//
//  CompanionManager.swift
//  yardtalk
//
//  App-level state. Tracks the four permissions, owns the project + clip
//  stores, and hosts the SessionManager that drives hotkey-held recording.
//  The stores are `@Observable` rather than `@Published`, so SwiftUI views
//  that read their properties get tracked independently of CompanionManager.
//

import AVFoundation
import Combine
import Foundation
import Observation
import OSLog
import ScreenCaptureKit
import SwiftUI

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var isRequestingScreenContent = false

    let projectStore = ProjectStore()
    let clipStore = ClipStore()
    let sessionStore = SessionStore()
    let transcriptionService = TranscriptionService()
    let sessionManager: SessionManager
    let screenSelectionOverlay = ScreenSelectionOverlay()
    let cameraOverlayManager = CameraOverlayManager()
    /// Resolved at launch and whenever the user changes provider in
    /// Settings. First-launch resolution prefers Apple on-device when
    /// available (macOS 26 + Apple Intelligence) and falls back to
    /// Ollama. nil only if both providers are misconfigured at the same
    /// time, which surfaces in the UI as a "no synthesis provider"
    /// error rather than a crash. @Published so the Settings "Active
    /// provider" row updates immediately on refresh.
    @Published private(set) var synthesisProvider: SynthesisProvider?
    let synthesisService: SynthesisService
    /// `nil` until the user saves an NU PAT in Settings. Upload paths
    /// disable themselves with a "configure PAT" hint in that state.
    private(set) var nuClient: NUClient?

    private var permissionPollTimer: Timer?

    var allPermissionsGranted: Bool {
        hasAccessibilityPermission
            && hasScreenRecordingPermission
            && hasMicrophonePermission
            && hasScreenContentPermission
    }

    static let nuPATKeychainKey = "nu-pat"
    static let anthropicAPIKeyKeychainKey = "anthropic-api-key"
    static let synthesisProviderKindKey = "synthesisProviderKind"
    static let ollamaBaseURLKey = "ollamaBaseURL"
    static let ollamaModelKey = "ollamaModel"
    static let anthropicModelKey = "anthropicModel"

    init() {
        let resolvedProvider = Self.resolveSynthesisProvider()
        self.synthesisProvider = resolvedProvider
        self.synthesisService = SynthesisService(provider: resolvedProvider)
        self.nuClient = Self.buildNUClient()
        self.sessionManager = SessionManager(
            projectStore: projectStore,
            clipStore: clipStore,
            sessionStore: sessionStore,
            transcriptionService: transcriptionService
        )
        sessionManager.cameraOverlayWindowID = { [weak self] in
            guard let wn = self?.cameraOverlayManager.overlayWindowNumber else { return nil }
            return CGWindowID(wn)
        }
        registerAllProjectLocations()
        clipStore.setActiveProject(projectStore.activeProjectID)
        sessionStore.setActiveProject(projectStore.activeProjectID)
        sessionManager.migrateOrphanClipsForActiveProject()
        observeActiveProjectChanges()
        wireDisplaySelection()
        wireSynthesis()
    }

    func start() {
        refreshAllPermissions()
        promptForMicrophoneIfNotDetermined()
        startPermissionPolling()
        sessionManager.start()
        cameraOverlayManager.startIfEnabled()
        Logger.session.info("start — accessibility: \(self.hasAccessibilityPermission, privacy: .public), screen: \(self.hasScreenRecordingPermission, privacy: .public), mic: \(self.hasMicrophonePermission, privacy: .public), screenContent: \(self.hasScreenContentPermission, privacy: .public)")
    }

    func stop() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        sessionManager.stop()
        cameraOverlayManager.hideOverlay()
    }

    func refreshSynthesisProvider() {
        synthesisProvider = Self.resolveSynthesisProvider()
        synthesisService.provider = synthesisProvider
    }

    var hasSynthesisProvider: Bool {
        synthesisProvider != nil
    }

    /// Resolves the current synthesis provider from user preferences,
    /// falling back to first-launch defaults if nothing has been picked
    /// yet. Apple on-device is preferred when available (macOS 26 with
    /// Apple Intelligence enabled); otherwise Ollama is used. Both
    /// providers run entirely on the user's machine — nothing leaves
    /// the device during synthesis.
    private static func resolveSynthesisProvider() -> SynthesisProvider? {
        let stored = UserDefaults.standard.string(forKey: synthesisProviderKindKey)
            .flatMap(SynthesisProviderKind.init(rawValue:))

        if let stored {
            switch stored {
            case .apple:
                if let apple = makeAppleProvider() { return apple }
                // Stored preference is Apple but it's not available
                // anymore (e.g. Apple Intelligence was disabled).
                // Fall through to Ollama rather than refusing to
                // synthesize at all.
                return makeOllamaProvider()
            case .ollama:
                return makeOllamaProvider()
            case .anthropic:
                if let anthropic = makeAnthropicProvider() { return anthropic }
                // Stored preference is Claude but no key is saved.
                // Fall back to a local provider so synthesis still
                // runs; the Settings UI will surface the missing key.
                if let apple = makeAppleProvider() { return apple }
                return makeOllamaProvider()
            }
        }

        // First-launch resolution.
        if let apple = makeAppleProvider() { return apple }
        return makeOllamaProvider()
    }

    private static func makeAppleProvider() -> SynthesisProvider? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if AppleFoundationProvider.isAvailable {
                return AppleFoundationProvider()
            }
        }
        #endif
        return nil
    }

    private static func makeOllamaProvider() -> SynthesisProvider {
        let baseString = UserDefaults.standard.string(forKey: ollamaBaseURLKey)
            ?? OllamaProvider.defaultBaseURLString
        let baseURL = URL(string: baseString) ?? URL(string: OllamaProvider.defaultBaseURLString)!
        let model = UserDefaults.standard.string(forKey: ollamaModelKey)
            ?? OllamaProvider.defaultModel
        return OllamaProvider(baseURL: baseURL, model: model)
    }

    private static func makeAnthropicProvider() -> SynthesisProvider? {
        guard let key = KeychainService.read(key: anthropicAPIKeyKeychainKey),
              !key.isEmpty else {
            return nil
        }
        let model = UserDefaults.standard.string(forKey: anthropicModelKey)
            ?? AnthropicProvider.defaultModel
        return AnthropicProvider(apiKey: key, model: model)
    }

    func refreshNUClient() {
        nuClient = Self.buildNUClient()
    }

    var hasNUPAT: Bool {
        nuClient != nil
    }

    /// Performs the upload, mutating `session.uploadState` through its
    /// lifecycle and persisting after each transition so the timeline
    /// reflects progress live. The idempotency key is generated on the
    /// first attempt and persisted with the session — every retry
    /// reuses it so NU dedupes correctly.
    func uploadSession(_ initial: YardTalkSession) async {
        guard let client = nuClient else {
            Logger.nu.error("Upload requested with no NU PAT configured")
            var s = initial
            s.uploadState.kind = .failed
            s.uploadState.errorMessage = "NU PAT not configured. Add it in Settings."
            try? sessionStore.update(s)
            return
        }
        guard let payload = initial.synthesisResult else {
            Logger.nu.error("Upload requested for unsynthesized session \(initial.id.uuidString, privacy: .public)")
            return
        }

        var s = initial
        if s.uploadState.idempotencyKey == nil {
            s.uploadState.idempotencyKey = UUID()
        }
        s.uploadState.kind = .uploading
        s.uploadState.errorMessage = nil
        try? sessionStore.update(s)

        do {
            try await client.uploadSession(payload, idempotencyKey: s.uploadState.idempotencyKey!)
            s.uploadState.kind = .uploaded
            s.uploadState.uploadedAt = Date()
            s.uploadState.errorMessage = nil
            try? sessionStore.update(s)
        } catch {
            s.uploadState.kind = .failed
            s.uploadState.errorMessage = error.localizedDescription
            try? sessionStore.update(s)
        }
    }

    /// Marks a session as queued for later upload. M6 will surface
    /// these in the outbox and provide a manual "Upload all" trigger.
    func queueSession(_ session: YardTalkSession) {
        var s = session
        if s.uploadState.idempotencyKey == nil {
            s.uploadState.idempotencyKey = UUID()
        }
        s.uploadState.kind = .queued
        s.uploadState.errorMessage = nil
        try? sessionStore.update(s)
    }

    /// Moves a project's data to a new folder. When `moveFiles` is true,
    /// existing clips/ and sessions/ directories are relocated on disk.
    /// The project metadata, store registrations, and active-project
    /// caches are updated regardless.
    func relocateProject(_ projectID: UUID, to newLocation: URL, moveFiles: Bool) throws {
        guard var project = projectStore.projects.first(where: { $0.id == projectID }) else { return }
        let oldLocation = project.location

        if moveFiles {
            let fm = FileManager.default
            try fm.createDirectory(at: newLocation, withIntermediateDirectories: true)

            let subdirs = ["clips", "sessions"]
            for subdir in subdirs {
                let src = oldLocation.appendingPathComponent(subdir, isDirectory: true)
                let dst = newLocation.appendingPathComponent(subdir, isDirectory: true)
                guard fm.fileExists(atPath: src.path) else { continue }
                if fm.fileExists(atPath: dst.path) {
                    // Merge: move each file individually to avoid "already exists" error
                    let items = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? []
                    try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                    for item in items {
                        let target = dst.appendingPathComponent(item.lastPathComponent)
                        if !fm.fileExists(atPath: target.path) {
                            try fm.moveItem(at: item, to: target)
                        }
                    }
                } else {
                    try fm.moveItem(at: src, to: dst)
                }
            }
        }

        project.location = newLocation
        project.updatedAt = Date()
        try projectStore.updateProject(project)

        clipStore.registerLocation(newLocation, for: projectID)
        sessionStore.registerLocation(newLocation, for: projectID)

        if projectStore.activeProjectID == projectID {
            clipStore.setActiveProject(projectID)
            sessionStore.setActiveProject(projectID)
        }
    }

    private static func buildNUClient() -> NUClient? {
        guard let pat = KeychainService.read(key: nuPATKeychainKey),
              !pat.isEmpty else {
            return nil
        }
        // Allow Info.plist override for pointing at staging / prod
        // without rebuilding. Defaults to the dev azure container app
        // per CLAUDE.md.
        let urlString = AppBundleConfiguration.stringValue(forKey: "YardTalkNUBaseURL")
            ?? NUClient.defaultBaseURLString
        guard let url = URL(string: urlString) else {
            Logger.nu.error("NU base URL malformed: \(urlString, privacy: .public)")
            return nil
        }
        if urlString == NUClient.defaultBaseURLString {
            // The default is the Azure Container App staging deployment.
            // Once neighborhoodunited.org goes live this default should
            // change; until then, warn loudly so a user doesn't silently
            // ship sessions to staging thinking it's prod.
            Logger.nu.warning("NU base URL is the Azure staging default; override `YardTalkNUBaseURL` in Info.plist for production.")
        }
        return NUClient(pat: pat, baseURL: url)
    }

    private func wireSynthesis() {
        sessionManager.onSessionEnded = { [weak self] session, shouldSynthesize in
            guard let self else { return }
            guard shouldSynthesize else { return }
            // Capture the project + clips synchronously here — by the
            // time the async synthesis runs the user could have switched
            // projects, leaving `clipStore.clipsForActiveProject` stale
            // for the session we're synthesizing.
            guard let project = self.projectStore.projects.first(where: { $0.id == session.projectID }) else {
                Logger.synthesis.error("No project found for session \(session.id.uuidString, privacy: .public) — skipping synthesis")
                return
            }
            let clips = self.clipStore.clipsForActiveProject
                .filter { $0.sessionID == session.id }
                .sorted(by: { $0.recordedAt < $1.recordedAt })
            let context = SessionContext(project: project, session: session, clips: clips)
            Task { @MainActor [weak self] in
                await self?.runSynthesis(context: context)
            }
        }
    }

    func triggerSynthesis(for session: YardTalkSession) {
        guard let project = projectStore.projects.first(where: { $0.id == session.projectID }) else {
            Logger.synthesis.error("No project found for session \(session.id.uuidString, privacy: .public)")
            return
        }
        let clips = clipStore.clipsForActiveProject
            .filter { $0.sessionID == session.id }
            .sorted(by: { $0.recordedAt < $1.recordedAt })
        let context = SessionContext(project: project, session: session, clips: clips)
        Task { @MainActor in
            await self.runSynthesis(context: context)
        }
    }

    private func runSynthesis(context: SessionContext) async {
        guard !context.clips.isEmpty else {
            Logger.synthesis.info("Empty session — skipping synthesis")
            return
        }
        let template = DefaultTemplate.forProjectType(context.project.type)
        var session = context.session
        do {
            let payload = try await synthesisService.synthesize(context: context, template: template)
            session.synthesisResult = payload
            session.synthesisError = nil
            session.status = .synthesized
            try? sessionStore.update(session)
            Logger.synthesis.info("Persisted synthesis for session \(session.id.uuidString, privacy: .public)")
        } catch {
            session.synthesisError = error.localizedDescription
            try? sessionStore.update(session)
            Logger.synthesis.error("Synthesis persistence: error stored on session \(session.id.uuidString, privacy: .public)")
        }
    }

    private func wireDisplaySelection() {
        sessionManager.onDisplaySelectionNeeded = { [weak self] completion in
            guard let self else { return }
            self.screenSelectionOverlay.show(
                displays: self.sessionManager.availableDisplays,
                currentSelection: self.sessionManager.selectedDisplayID
            ) { [weak self] selectedID in
                self?.sessionManager.selectedDisplayID = selectedID
                completion()
            }
        }
    }

    private func registerAllProjectLocations() {
        for project in projectStore.projects {
            clipStore.registerLocation(project.location, for: project.id)
            sessionStore.registerLocation(project.location, for: project.id)
        }
    }

    private func observeActiveProjectChanges() {
        withObservationTracking {
            _ = projectStore.activeProjectID
            _ = projectStore.projects
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.registerAllProjectLocations()
                self.clipStore.setActiveProject(self.projectStore.activeProjectID)
                self.sessionStore.setActiveProject(self.projectStore.activeProjectID)
                self.sessionManager.migrateOrphanClipsForActiveProject()
                self.observeActiveProjectChanges()
            }
        }
    }

    func refreshAllPermissions() {
        let previouslyHadAll = allPermissionsGranted

        let previouslyHadAccessibility = hasAccessibilityPermission
        hasAccessibilityPermission = WindowPositionManager.hasAccessibilityPermission()
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            Analytics.trackPermissionGranted(permission: "accessibility")
        }

        let previouslyHadScreenRecording = hasScreenRecordingPermission
        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            Analytics.trackPermissionGranted(permission: "screen_recording")
        }

        let previouslyHadMicrophone = hasMicrophonePermission
        hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if !previouslyHadMicrophone && hasMicrophonePermission {
            Analytics.trackPermissionGranted(permission: "microphone")
        }

        // Screen content permission is persisted: once the SCShareableContent
        // picker has been approved, macOS won't re-prompt, so we cache the grant.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            Analytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker via a dummy screenshot capture.
    /// Once the user approves, the grant is persisted — macOS won't re-prompt.
    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { self.isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let didCapture = image.width > 0 && image.height > 0
                await MainActor.run {
                    self.isRequestingScreenContent = false
                    guard didCapture else { return }
                    self.hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    Analytics.trackPermissionGranted(permission: "screen_content")
                }
            } catch {
                Logger.session.error("Screen content permission request failed: \(error.localizedDescription, privacy: .private)")
                await MainActor.run { self.isRequestingScreenContent = false }
            }
        }
    }

    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    private func startPermissionPolling() {
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }
}
