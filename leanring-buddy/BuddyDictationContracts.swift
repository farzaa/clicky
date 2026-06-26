//
//  BuddyDictationContracts.swift
//  leanring-buddy
//
//  Small state contracts used by the push-to-talk dictation manager.
//

enum BuddyDictationPermissionProblem {
    case microphoneAccessDenied
    case speechRecognitionDenied
}

enum BuddyDictationStartSource {
    case microphoneButton
    case keyboardShortcut
}

struct BuddyDictationDraftCallbacks {
    let updateDraftText: (String) -> Void
    let submitDraftText: (String) -> Void
}
