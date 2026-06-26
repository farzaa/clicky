//
//  CompanionOnboardingVideoController.swift
//  leanring-buddy
//
//  Owns onboarding video playback, observers, and audio fade-in timing.
//  CompanionManager keeps the published UI state; this controller keeps the
//  AVPlayer lifecycle out of the main orchestration object.
//

import AVFoundation
import Foundation

enum CompanionOnboardingVideoPolicy {
    static let streamURLString = "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8"
    static let mountDelaySeconds: TimeInterval = 0.2
    static let audioFadeTargetVolume: Float = 1.0
    static let audioFadeDurationSeconds: TimeInterval = 2.0
    static let audioFadeSteps = 20
    static let demoTriggerSeconds: TimeInterval = 40
    static let demoTriggerPreferredTimescale: CMTimeScale = 600
    static let videoFadeOutDurationSeconds: TimeInterval = 2.0
    static let promptDelayAfterVideoSeconds: TimeInterval = 0.3

    static var demoTriggerTime: CMTime {
        CMTime(seconds: demoTriggerSeconds, preferredTimescale: demoTriggerPreferredTimescale)
    }
}

@MainActor
final class CompanionOnboardingVideoController {
    struct Callbacks {
        let didPreparePlayer: (AVPlayer) -> Void
        let didBecomeVisible: () -> Void
        let didTriggerDemo: () -> Void
        let didCompleteVideo: () -> Void
        let didTearDown: () -> Void
        let didBecomeReadyForPrompt: () -> Void
    }

    private var player: AVPlayer?
    private var videoEndObserver: NSObjectProtocol?
    private var demoTimeObserver: Any?
    private var callbacks: Callbacks?

    func start(callbacks: Callbacks) {
        tearDown()
        self.callbacks = callbacks

        guard let videoURL = URL(string: CompanionOnboardingVideoPolicy.streamURLString) else {
            return
        }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.player = player
        callbacks.didPreparePlayer(player)

        player.play()
        scheduleFadeIn(for: player)
        scheduleDemoTrigger(for: player)
        observeVideoCompletion(for: player)
    }

    func tearDown() {
        if let demoTimeObserver {
            player?.removeTimeObserver(demoTimeObserver)
            self.demoTimeObserver = nil
        }

        if let videoEndObserver {
            NotificationCenter.default.removeObserver(videoEndObserver)
            self.videoEndObserver = nil
        }

        player?.pause()
        player = nil
        callbacks?.didTearDown()
        callbacks = nil
    }

    private func scheduleFadeIn(for player: AVPlayer) {
        DispatchQueue.main.asyncAfter(deadline: .now() + CompanionOnboardingVideoPolicy.mountDelaySeconds) { [weak self, weak player] in
            guard let self, let player else { return }
            self.callbacks?.didBecomeVisible()
            self.fadeInVideoAudio(player: player)
        }
    }

    private func scheduleDemoTrigger(for player: AVPlayer) {
        demoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CompanionOnboardingVideoPolicy.demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.callbacks?.didTriggerDemo()
            }
        }
    }

    private func observeVideoCompletion(for player: AVPlayer) {
        videoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleVideoCompleted()
            }
        }
    }

    private func handleVideoCompleted() {
        callbacks?.didCompleteVideo()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + CompanionOnboardingVideoPolicy.videoFadeOutDurationSeconds
        ) { [weak self] in
            guard let self else { return }
            let promptCallback = self.callbacks?.didBecomeReadyForPrompt
            self.tearDown()
            DispatchQueue.main.asyncAfter(
                deadline: .now() + CompanionOnboardingVideoPolicy.promptDelayAfterVideoSeconds
            ) {
                promptCallback?()
            }
        }
    }

    private func fadeInVideoAudio(player: AVPlayer) {
        let stepInterval = CompanionOnboardingVideoPolicy.audioFadeDurationSeconds
            / Double(CompanionOnboardingVideoPolicy.audioFadeSteps)
        let volumeIncrement = (CompanionOnboardingVideoPolicy.audioFadeTargetVolume - player.volume)
            / Float(CompanionOnboardingVideoPolicy.audioFadeSteps)
        var stepsRemaining = CompanionOnboardingVideoPolicy.audioFadeSteps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = CompanionOnboardingVideoPolicy.audioFadeTargetVolume
            }
        }
    }
}
