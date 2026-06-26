//
//  CompanionGuidanceStatusBubbleController.swift
//  leanring-buddy
//
//  Owns transient guidance status bubble text and hide timing.
//

import Foundation

enum CompanionGuidanceStatusBubblePolicy {
    static let maxCharacters = 64
    static let maxWords = 8
    static let maxSentences = 1
    static let hideDelaySeconds: TimeInterval = 2.4

    static func sanitizedText(_ text: String) -> String {
        text.spiderSanitizedShortDialogue(
            maxCharacters: maxCharacters,
            maxWords: maxWords,
            maxSentences: maxSentences
        )
    }
}

@MainActor
final class CompanionGuidanceStatusBubbleController {
    struct Callbacks {
        let didRequestCursorVisible: () -> Void
        let didShow: (String) -> Void
        let didHide: () -> Void
    }

    private var hideTask: Task<Void, Never>?

    func show(_ text: String, callbacks: Callbacks) {
        let sanitizedText = CompanionGuidanceStatusBubblePolicy.sanitizedText(text)
        guard !sanitizedText.isEmpty else { return }

        callbacks.didRequestCursorVisible()
        hideTask?.cancel()
        callbacks.didShow(sanitizedText)
        hideTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: Self.nanoseconds(from: CompanionGuidanceStatusBubblePolicy.hideDelaySeconds)
            )
            guard !Task.isCancelled else { return }
            callbacks.didHide()
            self?.hideTask = nil
        }
    }

    func clear(callbacks: Callbacks) {
        hideTask?.cancel()
        hideTask = nil
        callbacks.didHide()
    }

    private static func nanoseconds(from seconds: TimeInterval) -> UInt64 {
        UInt64(seconds * 1_000_000_000)
    }
}
