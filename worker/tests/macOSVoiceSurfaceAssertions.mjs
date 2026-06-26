import { readFileSync } from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

export function registerMacOSVoiceSurfaceAssertions({ test, workerRoot }) {
  test("macOS voice dictation keeps pure policies outside the manager", () => {
    const managerSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "BuddyDictationManager.swift"),
      "utf8"
    );
    const shortcutSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "BuddyPushToTalkShortcut.swift"),
      "utf8"
    );
    const contractsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "BuddyDictationContracts.swift"),
      "utf8"
    );
    const keytermSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "BuddyDictationKeytermBuilder.swift"),
      "utf8"
    );
    const draftComposerSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "BuddyDictationDraftComposer.swift"),
      "utf8"
    );
    const audioPowerMeterSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "BuddyDictationAudioPowerMeter.swift"),
      "utf8"
    );
    const errorPolicySource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "BuddyDictationErrorPresentationPolicy.swift"),
      "utf8"
    );

    assert.match(managerSource, /final class BuddyDictationManager: NSObject, ObservableObject/);
    assert.match(managerSource, /AVAudioEngine\(\)/);
    assert.match(managerSource, /transcriptionProvider\.startStreamingSession/);
    assert.match(managerSource, /BuddyDictationKeytermBuilder\.build\(contextualKeyterms: contextualKeyterms\)/);
    assert.match(managerSource, /BuddyDictationDraftComposer\.compose/);
    assert.match(managerSource, /BuddyDictationAudioPowerMeter\.boostedLevel/);
    assert.match(managerSource, /BuddyDictationErrorPresentationPolicy\.voiceInputFailureMessage/);
    assert.doesNotMatch(managerSource, /enum BuddyPushToTalkShortcut/);
    assert.doesNotMatch(managerSource, /enum BuddyDictationPermissionProblem/);
    assert.doesNotMatch(managerSource, /private func buildTranscriptionKeyterms/);
    assert.doesNotMatch(managerSource, /rootMeanSquare/);
    assert.doesNotMatch(managerSource, /private func voiceInputFailureMessage/);

    assert.match(shortcutSource, /enum BuddyPushToTalkShortcut/);
    assert.match(shortcutSource, /static let currentShortcutOption: ShortcutOption = \.controlOptionSpace/);
    assert.match(shortcutSource, /static let modifierOnlyFallbackShortcutOption: ShortcutOption = \.controlOption/);
    assert.match(shortcutSource, /static func shortcutTransition/);
    assert.match(contractsSource, /enum BuddyDictationPermissionProblem/);
    assert.match(contractsSource, /enum BuddyDictationStartSource/);
    assert.match(contractsSource, /struct BuddyDictationDraftCallbacks/);
    assert.match(keytermSource, /enum BuddyDictationKeytermBuilder/);
    assert.match(keytermSource, /SpiderProductFeatures\.availableTranscriptionKeyterms/);
    assert.match(draftComposerSource, /enum BuddyDictationDraftComposer/);
    assert.match(draftComposerSource, /existingDraftText\.hasSuffix\(" "\)/);
    assert.match(audioPowerMeterSource, /enum BuddyDictationAudioPowerMeter/);
    assert.match(audioPowerMeterSource, /static let baselineLevel: CGFloat = 0\.02/);
    assert.match(errorPolicySource, /enum BuddyDictationErrorPresentationPolicy/);
    assert.match(errorPolicySource, /sign in again before using voice\./);
    assert.match(errorPolicySource, /voice usage limit reached\. try again later\./);
    assert.match(errorPolicySource, /that voice request was too long\. try a shorter ask\./);
  });
}
