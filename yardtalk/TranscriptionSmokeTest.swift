//
//  TranscriptionSmokeTest.swift
//  yardtalk
//
//  Debug helper that records 10 s of microphone audio to a temp WAV and
//  hands it to TranscriptionService. Lets you verify FluidAudio works on
//  this Mac before the real session-recording path (SCStream +
//  AVAssetWriter, mic baked into the video clip) lands.
//
//  Delete this file and the smoke-test UI in CompanionPanelView once
//  session recording is in place.
//

import AVFoundation
import Foundation

@MainActor
final class TranscriptionSmokeTest: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording(secondsRemaining: Int)
        case transcribing
        case done(text: String)
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle

    private let service: TranscriptionService
    private var recorder: AVAudioRecorder?
    private var countdownTimer: Timer?

    init(service: TranscriptionService = TranscriptionService()) {
        self.service = service
    }

    /// Records 10 seconds, transcribes, publishes the result on `phase`.
    /// Re-entry while a run is in flight is ignored.
    func runTenSecondTest() {
        switch phase {
        case .recording, .transcribing: return
        default: break
        }

        Task { @MainActor in
            do {
                let url = try await recordTenSeconds()
                phase = .transcribing
                let text = try await service.transcribe(fileAt: url)
                phase = .done(text: text)
                try? FileManager.default.removeItem(at: url)
            } catch {
                phase = .failed(message: error.localizedDescription)
                cleanup()
            }
        }
    }

    private func recordTenSeconds() async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yardtalk-smoke-\(UUID().uuidString).wav")

        // 16 kHz mono PCM matches what Parakeet expects, so FluidAudio's
        // AudioConverter has no resampling work to do.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let newRecorder = try AVAudioRecorder(url: outputURL, settings: settings)
        guard newRecorder.record() else {
            throw SmokeTestError.recordingFailed
        }
        self.recorder = newRecorder
        startCountdown()

        try await Task.sleep(nanoseconds: 10_000_000_000)

        newRecorder.stop()
        cleanup()
        return outputURL
    }

    private func startCountdown() {
        var remaining = 10
        phase = .recording(secondsRemaining: remaining)
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else { return }
                remaining -= 1
                if remaining > 0 {
                    self.phase = .recording(secondsRemaining: remaining)
                } else {
                    timer.invalidate()
                }
            }
        }
    }

    private func cleanup() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        recorder = nil
    }
}

enum SmokeTestError: LocalizedError {
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .recordingFailed: return "Audio recording failed — check microphone permission."
        }
    }
}
