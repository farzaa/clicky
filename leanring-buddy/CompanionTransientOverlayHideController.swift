//
//  CompanionTransientOverlayHideController.swift
//  leanring-buddy
//
//  Owns delayed overlay hiding for transient Spider cursor interactions.
//

import Foundation

@MainActor
final class CompanionTransientOverlayHideController {
    struct Timing: Equatable {
        let pollIntervalNanoseconds: UInt64
        let finalDelayNanoseconds: UInt64

        static let production = Timing(
            pollIntervalNanoseconds: 200_000_000,
            finalDelayNanoseconds: 1_000_000_000
        )
    }

    struct Callbacks {
        let isSystemSpeechSpeaking: () -> Bool
        let isPointAnimationActive: () -> Bool
        let hideOverlay: () -> Void
    }

    private let timing: Timing
    private var hideTask: Task<Void, Never>?

    init() {
        self.timing = .production
    }

    init(timing: Timing) {
        self.timing = timing
    }

    func cancelPendingHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    @discardableResult
    func scheduleIfNeeded(
        isSpiderCursorEnabled: Bool,
        isOverlayVisible: Bool,
        callbacks: Callbacks
    ) -> Task<Void, Never>? {
        guard !isSpiderCursorEnabled && isOverlayVisible else { return nil }

        cancelPendingHide()
        let task = Task {
            await waitWhile(callbacks.isSystemSpeechSpeaking)
            guard !Task.isCancelled else { return }

            await waitWhile(callbacks.isPointAnimationActive)
            guard !Task.isCancelled else { return }

            try? await Task.sleep(nanoseconds: timing.finalDelayNanoseconds)
            guard !Task.isCancelled else { return }

            callbacks.hideOverlay()
        }
        hideTask = task
        return task
    }

    private func waitWhile(_ condition: @escaping () -> Bool) async {
        while condition() {
            try? await Task.sleep(nanoseconds: timing.pollIntervalNanoseconds)
            guard !Task.isCancelled else { return }
        }
    }
}
