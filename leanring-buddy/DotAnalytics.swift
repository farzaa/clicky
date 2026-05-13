//
//  DotAnalytics.swift
//  leanring-buddy
//
//  Centralized PostHog analytics wrapper. All event names and properties
//  are defined here so instrumentation is consistent and easy to audit.
//

import Foundation

#if canImport(PostHog)
import PostHog
#endif

enum DotAnalytics {

    // MARK: - Setup

    static func configure() {
        #if canImport(PostHog)
        let config = PostHogConfig(
            apiKey: "phc_xcQPygmhTMzzYh8wNW92CCwoXmnzqyChAixh8zgpqC3C",
            host: "https://us.i.posthog.com"
        )
        PostHogSDK.shared.setup(config)
        #endif
    }

    // MARK: - App Lifecycle

    /// Fired once on every app launch in applicationDidFinishLaunching.
    static func trackAppOpened() {
        #if canImport(PostHog)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        PostHogSDK.shared.capture("app_opened", properties: [
            "app_version": version
        ])
        #endif
    }

    // MARK: - Onboarding

    /// User clicked the Start button to begin onboarding for the first time.
    static func trackOnboardingStarted() {
        #if canImport(PostHog)
        PostHogSDK.shared.capture("onboarding_started")
        #endif
    }

    /// User clicked "Watch Onboarding Again" from the panel footer.
    static func trackOnboardingReplayed() {
        #if canImport(PostHog)
        PostHogSDK.shared.capture("onboarding_replayed")
        #endif
    }

    /// The onboarding video finished playing to the end.
    static func trackOnboardingVideoCompleted() {
        #if canImport(PostHog)
        PostHogSDK.shared.capture("onboarding_video_completed")
        #endif
    }

    /// The 40s onboarding demo interaction where Dot points at something.
    static func trackOnboardingDemoTriggered() {
        #if canImport(PostHog)
        PostHogSDK.shared.capture("onboarding_demo_triggered")
        #endif
    }

    // MARK: - Permissions

    /// All three permissions (accessibility, screen recording, mic) are granted.
    static func trackAllPermissionsGranted() {
        #if canImport(PostHog)
        PostHogSDK.shared.capture("all_permissions_granted")
        #endif
    }

    /// A single permission was granted. Called when polling detects a change.
    static func trackPermissionGranted(permission: String) {
        #if canImport(PostHog)
        PostHogSDK.shared.capture("permission_granted", properties: [
            "permission": permission
        ])
        #endif
    }

    // MARK: - Voice Interaction

    /// User pressed the push-to-talk shortcut (control+option) to start talking.
    static func trackPushToTalkStarted() {
        #if canImport(PostHog)
        PostHogSDK.shared.capture("push_to_talk_started")
        #endif
    }

    /// User released the shortcut — transcript is being finalized.
    static func trackPushToTalkReleased() {
        #if canImport(PostHog)
        PostHogSDK.shared.capture("push_to_talk_released")
        #endif
    }

    /// Transcription completed and the user's message is being sent to the AI.
    /// We deliberately log only the character count, never the transcript text —
    /// users say sensitive things to Dot and that should not leave their machine
    /// outside the inference path itself.
    static func trackUserMessageSent(transcript: String) {
        #if canImport(PostHog)
        PostHogSDK.shared.capture("user_message_sent", properties: [
            "character_count": transcript.count
        ])
        #endif
    }

    /// Claude responded and the response is being spoken via TTS.
    /// Logs response length only — the response text itself is never sent to
    /// analytics for the same privacy reason as transcripts.
    static func trackAIResponseReceived(response: String) {
        #if canImport(PostHog)
        PostHogSDK.shared.capture("ai_response_received", properties: [
            "character_count": response.count
        ])
        #endif
    }

    /// Claude's response included a [POINT:x,y:label] coordinate tag,
    /// so the buddy is flying to point at a UI element.
    static func trackElementPointed(elementLabel: String?) {
        #if canImport(PostHog)
        PostHogSDK.shared.capture("element_pointed", properties: [
            "element_label": elementLabel ?? "unknown"
        ])
        #endif
    }

    // MARK: - Errors

    /// An error occurred during the AI response pipeline.
    static func trackResponseError(error: String) {
        #if canImport(PostHog)
        PostHogSDK.shared.capture("response_error", properties: [
            "error": error
        ])
        #endif
    }

    /// An error occurred during TTS playback.
    static func trackTTSError(error: String) {
        #if canImport(PostHog)
        PostHogSDK.shared.capture("tts_error", properties: [
            "error": error
        ])
        #endif
    }

    static func trackInferenceEndpointResult(
        endpoint: String,
        statusCode: Int,
        durationMs: Int,
        provider: String,
        model: String? = nil
    ) {
        #if canImport(PostHog)
        var properties: [String: Any] = [
            "endpoint": endpoint,
            "status_code": statusCode,
            "status_class": "\(statusCode / 100)xx",
            "duration_ms": durationMs,
            "provider": provider,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "app_build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
        ]
        if let model {
            properties["model"] = model
        }
        PostHogSDK.shared.capture("inference_endpoint_result", properties: properties)
        #endif
    }
}
