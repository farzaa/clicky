//
//  TranscriptionService.swift
//  yardtalk
//
//  Wraps FluidAudio's Parakeet TDT v3 for local transcription. Models are
//  fetched from HuggingFace on first use (~600 MB) and cached. After load,
//  inference runs on the Apple Neural Engine — no network, no audio leaves
//  the device.
//

import FluidAudio
import Foundation

@MainActor
final class TranscriptionService: ObservableObject {
    enum Status: Equatable {
        case idle
        case downloadingModels
        case ready
        case transcribing
        case failed(message: String)
    }

    @Published private(set) var status: Status = .idle

    private var asrManager: AsrManager?

    /// Loads the multilingual Parakeet model (v3 — 25 European languages,
    /// strong English). Switch to `.v2` for English-only highest recall. First
    /// call downloads from HuggingFace; subsequent calls hit local cache.
    func loadModelsIfNeeded() async throws {
        if asrManager != nil { return }
        status = .downloadingModels
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asrManager = manager
            status = .ready
        } catch {
            status = .failed(message: "Model load failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Transcribes any audio file FluidAudio can read (WAV, M4A, MP3, FLAC).
    /// Format conversion to 16 kHz mono Float32 happens inside FluidAudio via
    /// `AudioConverter` — never decode WAV bytes by hand here, garbage
    /// values produce silently-empty transcripts.
    func transcribe(fileAt url: URL) async throws -> String {
        try await loadModelsIfNeeded()
        guard let asrManager else { throw TranscriptionError.modelsNotLoaded }
        status = .transcribing
        defer { status = .ready }
        let result = try await asrManager.transcribe(url, source: .system)
        return result.text
    }
}

enum TranscriptionError: LocalizedError {
    case modelsNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelsNotLoaded: return "FluidAudio models failed to load."
        }
    }
}
