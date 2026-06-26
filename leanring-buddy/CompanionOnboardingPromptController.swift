//
//  CompanionOnboardingPromptController.swift
//  leanring-buddy
//
//  Owns the onboarding prompt typing and auto-dismiss timing. CompanionManager
//  keeps the published UI state; this controller keeps timer mechanics isolated.
//

import Foundation

enum CompanionOnboardingPromptPolicy {
    static let message = "tap control + option + space to show spider"
    static let fadeInDurationSeconds: TimeInterval = 0.4
    static let typingIntervalSeconds: TimeInterval = 0.03
    static let autoDismissDelaySeconds: TimeInterval = 10.0
    static let fadeOutDurationSeconds: TimeInterval = 0.3
    static let teardownDelaySeconds: TimeInterval = 0.35
}

@MainActor
final class CompanionOnboardingPromptController {
    struct Callbacks {
        let didStart: () -> Void
        let didAppendCharacter: (Character) -> Void
        let shouldAutoDismiss: () -> Bool
        let didBeginDismiss: () -> Void
        let didFinishDismiss: () -> Void
    }

    private var typingTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    func start(callbacks: Callbacks) {
        cancel()
        callbacks.didStart()

        typingTask = Task { [weak self] in
            for character in CompanionOnboardingPromptPolicy.message {
                try? await Task.sleep(
                    nanoseconds: Self.nanoseconds(from: CompanionOnboardingPromptPolicy.typingIntervalSeconds)
                )
                guard !Task.isCancelled else { return }
                callbacks.didAppendCharacter(character)
            }

            guard !Task.isCancelled else { return }
            try? await Task.sleep(
                nanoseconds: Self.nanoseconds(from: CompanionOnboardingPromptPolicy.typingIntervalSeconds)
            )
            guard !Task.isCancelled else { return }
            self?.scheduleAutoDismiss(callbacks: callbacks)
        }
    }

    func cancel() {
        typingTask?.cancel()
        dismissTask?.cancel()
        typingTask = nil
        dismissTask = nil
    }

    private func scheduleAutoDismiss(callbacks: Callbacks) {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(
                nanoseconds: Self.nanoseconds(from: CompanionOnboardingPromptPolicy.autoDismissDelaySeconds)
            )
            guard !Task.isCancelled, callbacks.shouldAutoDismiss() else { return }

            callbacks.didBeginDismiss()

            try? await Task.sleep(
                nanoseconds: Self.nanoseconds(from: CompanionOnboardingPromptPolicy.teardownDelaySeconds)
            )
            guard !Task.isCancelled else { return }

            callbacks.didFinishDismiss()
            dismissTask = nil
        }
    }

    private static func nanoseconds(from seconds: TimeInterval) -> UInt64 {
        UInt64(seconds * 1_000_000_000)
    }
}
