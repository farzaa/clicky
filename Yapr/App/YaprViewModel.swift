//
//  YaprViewModel.swift
//  Yapr
//
//  The central state machine for the iOS app. Equivalent in role to the
//  macOS app's `CompanionManager.swift`, but trimmed to what the iOS
//  push-to-talk-on-an-orb experience actually needs (no menu bar, no
//  cursor overlay, no multi-screen, no global hotkey, no onboarding video).
//
//  Pipeline driven by this view model:
//
//    user holds orb
//      → AVAudioSession activated (.playAndRecord, defaultToSpeaker)
//      → MicrophoneCaptureService starts AssemblyAI streaming session
//      → audio levels feed VoiceOrbView
//    user releases orb
//      → MicrophoneCaptureService.requestFinalTranscriptAndStop()
//      → final transcript arrives via callback
//      → most-recent screenshot already loaded → ClaudeAPI streaming call
//      → response text accumulates (we don't show it streaming, matching macOS)
//      → PointTagParser extracts [POINT:x,y:label]
//      → ElevenLabsTTSClient plays the spoken text
//      → ScreenshotPreviewView shows the pulsing dot at the parsed location
//    TTS finishes
//      → state returns to .idle
//

import AVFoundation
import Combine
import Foundation
import Photos
import SwiftUI
import UIKit

import ClickyShared

enum YaprVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class YaprViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var voiceState: YaprVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var streamingResponseText: String = ""

    /// The most recent screenshot pulled from the Photos library, or nil
    /// if Photos access is missing or the user has no screenshots.
    @Published private(set) var currentScreenshot: RecentScreenshotProvider.FetchedScreenshot?

    /// `nil` while we haven't asked yet, otherwise the most recent value
    /// from `RecentScreenshotProvider.currentAuthorizationStatus()`.
    @Published private(set) var photosAuthorizationStatus: RecentScreenshotProvider.AccessStatus = .notDetermined

    /// `nil` until the first permission probe completes. Mirrors `AVCaptureDevice`
    /// authorization status so the UI knows when to show the permissions gate.
    @Published private(set) var microphoneAuthorizationStatus: AVAuthorizationStatus = .notDetermined

    /// Pixel coordinate (in `currentScreenshot`'s coordinate space) where
    /// Claude wants to point. Drives the pulsing dot on `ScreenshotPreviewView`.
    @Published private(set) var pointingTarget: PointingParseResult?

    /// Surfaced to the UI when the AI pipeline fails (network, no credits,
    /// etc.) so we can show a small toast instead of silently failing.
    @Published var lastErrorMessage: String?

    // MARK: - Internal State

    private let microphoneCaptureService: MicrophoneCaptureService
    private let claudeAPI: ClaudeAPI
    private let elevenLabsTTSClient: ElevenLabsTTSClient

    /// Conversation history so Claude remembers prior exchanges within a
    /// session. Each entry is the user's transcript + Claude's response
    /// (with the `[POINT:...]` tag stripped). Capped at 10 exchanges.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, cancelled when the user
    /// presses the orb again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    /// Audio-power-level published from the mic service, mirrored here so
    /// the orb view can observe a single source of truth.
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    private var audioPowerLevelObservation: AnyCancellable?

    // MARK: - Init

    init() {
        let assemblyAIProvider = AssemblyAIStreamingTranscriptionProvider()
        self.microphoneCaptureService = MicrophoneCaptureService(transcriptionProvider: assemblyAIProvider)

        self.claudeAPI = ClaudeAPI(
            proxyURL: WorkerConfiguration.chatProxyURL,
            model: "claude-sonnet-4-6"
        )
        self.elevenLabsTTSClient = ElevenLabsTTSClient(
            proxyURL: WorkerConfiguration.ttsProxyURL
        )

        self.audioPowerLevelObservation = microphoneCaptureService.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    // MARK: - Lifecycle

    /// Called from the root view's `.onAppear`. Refreshes permission state
    /// (so the gate shows/hides correctly), pulls the latest screenshot if
    /// the user has authorized Photos, and configures the audio session.
    func bootstrap() async {
        AVAudioSessionConfigurator.configureForVoiceCompanion()
        refreshMicrophoneAuthorizationStatus()
        photosAuthorizationStatus = RecentScreenshotProvider.currentAuthorizationStatus()

        if photosAuthorizationStatus == .authorized || photosAuthorizationStatus == .limited {
            await loadMostRecentScreenshot()
        }
    }

    /// Called when the app comes back to the foreground (e.g. after the
    /// user took a new screenshot). Re-fetches so the preview is always
    /// the freshest screenshot.
    func refreshOnForeground() async {
        refreshMicrophoneAuthorizationStatus()
        photosAuthorizationStatus = RecentScreenshotProvider.currentAuthorizationStatus()

        if photosAuthorizationStatus == .authorized || photosAuthorizationStatus == .limited {
            await loadMostRecentScreenshot()
        }
    }

    /// Pulls the most recent screenshot from Photos and surfaces it for
    /// preview + Claude. Safe to call repeatedly.
    func loadMostRecentScreenshot() async {
        let fetchedScreenshot = await RecentScreenshotProvider.fetchMostRecentScreenshot()
        self.currentScreenshot = fetchedScreenshot
    }

    // MARK: - Permissions

    func requestMicrophonePermission() async {
        let alreadyAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        guard !alreadyAuthorized else {
            refreshMicrophoneAuthorizationStatus()
            return
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        refreshMicrophoneAuthorizationStatus()
    }

    func requestPhotosPermission() async {
        photosAuthorizationStatus = await RecentScreenshotProvider.requestAuthorizationIfNeeded()

        if photosAuthorizationStatus == .authorized || photosAuthorizationStatus == .limited {
            await loadMostRecentScreenshot()
        }
    }

    private func refreshMicrophoneAuthorizationStatus() {
        microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    var hasAllRequiredPermissions: Bool {
        let micGranted = microphoneAuthorizationStatus == .authorized
        let photosGranted = photosAuthorizationStatus == .authorized || photosAuthorizationStatus == .limited
        return micGranted && photosGranted
    }

    // MARK: - Push-to-Talk

    /// Called when the user begins pressing the voice orb. Opens the
    /// AssemblyAI streaming session and starts the mic engine. If the
    /// session fails to open, the error is surfaced to the UI and the
    /// state machine returns to `.idle`.
    func startListening() async {
        guard voiceState == .idle else { return }
        guard hasAllRequiredPermissions else { return }

        // Cancel any in-flight response from a prior turn so a new one
        // can begin immediately when the user releases.
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        pointingTarget = nil
        streamingResponseText = ""
        lastErrorMessage = nil

        voiceState = .listening

        do {
            try await microphoneCaptureService.startCapturing(
                keyterms: ["Yapr", "Clicky", "Claude", "Anthropic", "iPhone", "iOS"],
                onTranscriptUpdate: { [weak self] _ in
                    // Partial transcripts are intentionally not surfaced — the
                    // orb's waveform is the entire listening UI, matching the
                    // macOS app's "no streaming text in the listening state".
                    _ = self
                },
                onFinalTranscriptReady: { [weak self] finalTranscript in
                    self?.handleFinalTranscript(finalTranscript)
                },
                onError: { [weak self] error in
                    self?.handleMicrophoneError(error)
                }
            )
        } catch {
            handleMicrophoneError(error)
        }
    }

    /// Called when the user releases the orb. Stops the mic and asks the
    /// AssemblyAI session to deliver a final transcript. Once the
    /// transcript arrives, `handleFinalTranscript(_:)` kicks off the
    /// Claude → TTS pipeline.
    func stopListening() {
        guard voiceState == .listening else { return }

        voiceState = .processing
        microphoneCaptureService.requestFinalTranscriptAndStop()
    }

    // MARK: - AI Response Pipeline

    private func handleFinalTranscript(_ finalTranscript: String) {
        let trimmedTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            voiceState = .idle
            return
        }

        lastTranscript = trimmedTranscript
        sendTranscriptToClaudeWithScreenshot(transcript: trimmedTranscript)
    }

    private func handleMicrophoneError(_ error: Error) {
        print("⚠️ Microphone capture error: \(error)")
        lastErrorMessage = "couldn't hear you. try again."
        Task { await microphoneCaptureService.cancelCurrentCapture() }
        voiceState = .idle
    }

    /// Sends the current screenshot + transcript to Claude, parses any
    /// `[POINT:...]` tag, and plays the response via ElevenLabs.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        currentResponseTask = Task { [weak self] in
            guard let self else { return }

            voiceState = .processing

            do {
                // Refresh the screenshot in case the user took a new one
                // since launch.
                if currentScreenshot == nil {
                    await loadMostRecentScreenshot()
                }

                guard let fetchedScreenshot = currentScreenshot else {
                    // No screenshot available — answer the question directly,
                    // without an image. Claude will see only the transcript.
                    try await respondToQuestionWithoutScreenshot(transcript: transcript)
                    return
                }

                let imageLabel = "user's most recent iphone screenshot (image dimensions: \(fetchedScreenshot.pixelWidth)x\(fetchedScreenshot.pixelHeight) pixels)"

                let conversationHistoryForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: [(data: fetchedScreenshot.jpegData, label: imageLabel)],
                    systemPrompt: SystemPrompts.companionVoiceResponseSystemPrompt,
                    conversationHistory: conversationHistoryForAPI,
                    userPrompt: transcript,
                    onTextChunk: { _ in
                        // Streaming chunks aren't surfaced live in v1 — matches
                        // the macOS app's "spinner stays until TTS plays" behavior.
                    }
                )

                guard !Task.isCancelled else { return }

                let parseResult = PointTagParser.parse(from: fullResponseText)
                let spokenText = parseResult.spokenText

                if parseResult.coordinate != nil {
                    pointingTarget = parseResult
                } else {
                    pointingTarget = nil
                }

                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    streamingResponseText = spokenText
                    do {
                        try await elevenLabsTTSClient.speakText(spokenText)
                        voiceState = .responding
                    } catch {
                        lastErrorMessage = "couldn't play the response. \(error.localizedDescription)"
                    }
                }

                // Wait for TTS playback to finish before returning to idle so
                // the UI shows .responding for the entire spoken duration.
                while elevenLabsTTSClient.isPlaying {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if Task.isCancelled { return }
                }

                voiceState = .idle
            } catch is CancellationError {
                // User pressed the orb again — let the new turn take over.
            } catch {
                print("⚠️ AI response error: \(error)")
                lastErrorMessage = "something went wrong. \(error.localizedDescription)"
                voiceState = .idle
            }
        }
    }

    /// Fallback path when no screenshot is available. Calls Claude with
    /// just the transcript so we still get a useful voice answer.
    private func respondToQuestionWithoutScreenshot(transcript: String) async throws {
        let conversationHistoryForAPI = conversationHistory.map { entry in
            (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
        }

        let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
            images: [],
            systemPrompt: SystemPrompts.companionVoiceResponseSystemPrompt,
            conversationHistory: conversationHistoryForAPI,
            userPrompt: transcript,
            onTextChunk: { _ in }
        )

        let parseResult = PointTagParser.parse(from: fullResponseText)
        let spokenText = parseResult.spokenText

        conversationHistory.append((
            userTranscript: transcript,
            assistantResponse: spokenText
        ))
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }

        streamingResponseText = spokenText

        do {
            try await elevenLabsTTSClient.speakText(spokenText)
            voiceState = .responding
        } catch {
            lastErrorMessage = "couldn't play the response. \(error.localizedDescription)"
        }

        while elevenLabsTTSClient.isPlaying {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
        }

        voiceState = .idle
    }

    /// Called by `RootView` if the app was launched via the Control Center
    /// Yapr tile. Reads + clears the App Group flag and refreshes the
    /// screenshot so the user can hold the orb and start talking immediately.
    func handleControlCenterLaunchIfApplicable() async {
        guard let sharedDefaults = AppGroupKeys.sharedDefaults else { return }
        let didLaunchFromControlCenter = sharedDefaults.bool(
            forKey: AppGroupKeys.didLaunchFromControlCenter
        )
        guard didLaunchFromControlCenter else { return }

        sharedDefaults.set(false, forKey: AppGroupKeys.didLaunchFromControlCenter)
        await loadMostRecentScreenshot()
    }
}
