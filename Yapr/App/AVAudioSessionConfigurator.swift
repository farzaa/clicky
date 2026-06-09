//
//  AVAudioSessionConfigurator.swift
//  Yapr
//
//  iOS-specific audio session setup. The macOS Clicky app didn't need this
//  because macOS handles routing automatically, but on iOS every app that
//  records and plays audio must explicitly configure `AVAudioSession` first.
//
//  We configure once at app launch with `.playAndRecord` so that:
//    • Holding the orb captures from the mic.
//    • Releasing the orb plays back ElevenLabs TTS through the speaker
//      (not the tiny earpiece — that's what `.defaultToSpeaker` does).
//    • Bluetooth headsets work for both directions.
//    • Background music from Spotify / Apple Music ducks while we speak,
//      and unducks when we stop.
//

import AVFoundation
import Foundation

enum AVAudioSessionConfigurator {
    /// Configures the shared audio session for voice push-to-talk + TTS playback.
    /// Safe to call multiple times — `setCategory` and `setActive` are idempotent.
    static func configureForVoiceCompanion() {
        let audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [
                    // Route TTS to the loud speaker even when the user has
                    // a wired or Bluetooth device connected for the mic.
                    .defaultToSpeaker,
                    // Allow Bluetooth headsets/headphones for mic input.
                    .allowBluetooth,
                    // Lower other apps' audio while Yapr is speaking, then
                    // restore when we deactivate the session.
                    .duckOthers
                ]
            )

            try audioSession.setActive(true, options: [])
        } catch {
            print("⚠️ AVAudioSession configuration failed: \(error)")
        }
    }

    /// Deactivates the audio session so other apps' music returns to full
    /// volume after Yapr finishes speaking. Call after TTS playback ends.
    /// Failures are silently ignored — the OS handles cleanup eventually.
    static func deactivateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            // Common when audio is still draining — not user-actionable.
            print("ℹ️ AVAudioSession deactivate (non-fatal): \(error.localizedDescription)")
        }
    }
}
