//
//  CompanionOnboardingMusicController.swift
//  leanring-buddy
//
//  Owns onboarding music playback and fade timing. CompanionManager should
//  start the onboarding experience, not manage AVAudioPlayer lifecycle.
//

import AVFoundation
import Foundation

enum CompanionOnboardingMusicPolicy {
    static let resourceName = "ff"
    static let resourceExtension = "mp3"
    static let initialVolume: Float = 0.3
    static let fadeDelayNanoseconds: UInt64 = 90_000_000_000
    static let fadeDurationNanoseconds: UInt64 = 3_000_000_000
    static let fadeSteps = 30

    static var fadeStepNanoseconds: UInt64 {
        fadeDurationNanoseconds / UInt64(fadeSteps)
    }
}

@MainActor
final class CompanionOnboardingMusicController {
    private var player: AVAudioPlayer?
    private var fadeTask: Task<Void, Never>?

    func start() {
        stop()

        guard let musicURL = Bundle.main.url(
            forResource: CompanionOnboardingMusicPolicy.resourceName,
            withExtension: CompanionOnboardingMusicPolicy.resourceExtension
        ) else {
            SpiderDiagnostics.event("onboarding music file missing")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = CompanionOnboardingMusicPolicy.initialVolume
            player.play()
            self.player = player
            scheduleFadeOut()
        } catch {
            SpiderDiagnostics.event("onboarding music playback failed")
        }
    }

    func stop() {
        fadeTask?.cancel()
        fadeTask = nil
        player?.stop()
        player = nil
    }

    private func scheduleFadeOut() {
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: CompanionOnboardingMusicPolicy.fadeDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.fadeOut()
        }
    }

    private func fadeOut() async {
        let volumeDecrement = (player?.volume ?? 0) / Float(CompanionOnboardingMusicPolicy.fadeSteps)

        for _ in 0..<CompanionOnboardingMusicPolicy.fadeSteps {
            try? await Task.sleep(nanoseconds: CompanionOnboardingMusicPolicy.fadeStepNanoseconds)
            guard !Task.isCancelled else { return }
            player?.volume = max(0, (player?.volume ?? 0) - volumeDecrement)
        }

        player?.stop()
        player = nil
        fadeTask = nil
    }
}
