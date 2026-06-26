//
//  GuidedSetupPollScheduler.swift
//  leanring-buddy
//
//  Owns the delayed task used by automatic guided setup polling.
//

import Foundation

@MainActor
final class GuidedSetupPollScheduler {
    private var pendingTask: Task<Void, Never>?

    func cancelPendingPoll() {
        pendingTask?.cancel()
        pendingTask = nil
    }

    @discardableResult
    func schedule(
        after delayNanoseconds: UInt64,
        action: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        cancelPendingPoll()
        let task = Task {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                action()
            }
        }
        pendingTask = task
        return task
    }
}
