//
//  WorkerConfiguration.swift
//  ClickyShared
//
//  Configuration for the Cloudflare Worker proxy that holds API keys
//  server-side. The same Worker is used by both the macOS Clicky app
//  and the iOS Yapr app — set this base URL once after deploying your
//  Worker (see worker/README.md at the repo root) and every API client
//  in this package will pick it up automatically.
//

import Foundation

/// Configuration for the Cloudflare Worker proxy that fronts the Anthropic,
/// AssemblyAI, and ElevenLabs APIs. The Worker holds the real API keys as
/// secrets so they never ship inside the app binary.
public enum WorkerConfiguration {
    /// Base URL of the deployed Cloudflare Worker. Set this once after running
    /// `npx wrangler deploy` from the `worker/` directory at the repo root.
    ///
    /// Example after deployment: `https://clicky-proxy.your-subdomain.workers.dev`
    ///
    /// IMPORTANT: Replace this placeholder before building. Until you do,
    /// the app will hit a non-existent host and every request will fail.
    public static let workerBaseURL: String = "https://your-worker-name.your-subdomain.workers.dev"

    /// Endpoint Claude vision + streaming chat requests are sent to.
    /// The Worker forwards to `https://api.anthropic.com/v1/messages` after
    /// attaching the secret `ANTHROPIC_API_KEY`.
    public static var chatProxyURL: String {
        return "\(workerBaseURL)/chat"
    }

    /// Endpoint ElevenLabs text-to-speech requests are sent to.
    /// The Worker forwards to `https://api.elevenlabs.io/v1/text-to-speech/{voiceId}`
    /// after attaching the secret `ELEVENLABS_API_KEY` and the configured voice ID.
    public static var ttsProxyURL: String {
        return "\(workerBaseURL)/tts"
    }

    /// Endpoint that returns a short-lived AssemblyAI streaming token.
    /// The Worker calls `https://streaming.assemblyai.com/v3/token` with the
    /// secret `ASSEMBLYAI_API_KEY` and forwards the temp token to the app.
    /// The app then opens the AssemblyAI websocket using only the temp token,
    /// so the real API key never leaves the server.
    public static var transcribeTokenProxyURL: String {
        return "\(workerBaseURL)/transcribe-token"
    }
}
