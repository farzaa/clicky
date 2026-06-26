//
//  CompanionSpeechPlaybackController.swift
//  leanring-buddy
//
//  Runs bounded guidance speech with OpenAI Realtime and local system fallback.
//

import Foundation

@MainActor
protocol CompanionRealtimeSpeechPlaying: AnyObject {
    func speak(_ text: String) async throws
    func stopActiveSpeech()
}

@MainActor
protocol CompanionSystemSpeechPlaying: AnyObject {
    var isSpeaking: Bool { get }

    func stop()
    func speak(_ text: String)
}

extension OpenAIRealtimeVoiceClient: CompanionRealtimeSpeechPlaying {}
extension CompanionSystemSpeechPlayer: CompanionSystemSpeechPlaying {}

@MainActor
final class CompanionSpeechPlaybackController {
    struct Callbacks {
        let setVoiceState: (CompanionVoiceState) -> Void
        let handleWorkerError: (SpiderWorkerClientError) -> Void
        let scheduleTransientHideIfNeeded: () -> Void
    }

    private let realtimeVoiceClient: CompanionRealtimeSpeechPlaying
    private let systemSpeechPlayer: CompanionSystemSpeechPlaying
    private var currentSpeechTask: Task<Void, Never>?

    init(
        realtimeVoiceClient: CompanionRealtimeSpeechPlaying,
        systemSpeechPlayer: CompanionSystemSpeechPlaying
    ) {
        self.realtimeVoiceClient = realtimeVoiceClient
        self.systemSpeechPlayer = systemSpeechPlayer
    }

    var isSystemSpeechSpeaking: Bool {
        systemSpeechPlayer.isSpeaking
    }

    func cancelGuidanceSpeech() {
        currentSpeechTask?.cancel()
        currentSpeechTask = nil
        realtimeVoiceClient.stopActiveSpeech()
    }

    func stopAllSpeech() {
        cancelGuidanceSpeech()
        systemSpeechPlayer.stop()
    }

    func speakSystemText(_ text: String, callbacks: Callbacks) {
        let compactText = CompanionSpeechPolicy.systemText(text)
        guard !compactText.isEmpty else { return }

        callbacks.setVoiceState(.responding)
        systemSpeechPlayer.speak(compactText)
    }

    @discardableResult
    func speakGuidanceText(_ text: String, callbacks: Callbacks) -> Task<Void, Never>? {
        let compactText = CompanionSpeechPolicy.guidanceText(text)
        guard !compactText.isEmpty else { return nil }

        cancelGuidanceSpeech()

        let speechTask = Task { [weak self] in
            guard let self else { return }

            callbacks.setVoiceState(.responding)
            do {
                try await realtimeVoiceClient.speak(compactText)
            } catch is CancellationError {
                return
            } catch let workerError as SpiderWorkerClientError {
                callbacks.handleWorkerError(workerError)
                SpiderDiagnostics.workerFailure("realtime speech", statusCode: workerError.statusCode)
                speakSystemText(compactText, callbacks: callbacks)
                await waitForSystemSpeechToFinish()
            } catch {
                SpiderDiagnostics.event("realtime speech failed")
                speakSystemText(compactText, callbacks: callbacks)
                await waitForSystemSpeechToFinish()
            }

            guard !Task.isCancelled else { return }
            callbacks.setVoiceState(.idle)
            currentSpeechTask = nil
            callbacks.scheduleTransientHideIfNeeded()
        }
        currentSpeechTask = speechTask
        return speechTask
    }

    private func waitForSystemSpeechToFinish() async {
        while systemSpeechPlayer.isSpeaking {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
        }
    }
}
