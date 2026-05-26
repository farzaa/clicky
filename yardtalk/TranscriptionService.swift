//
//  TranscriptionService.swift
//  yardtalk
//
//  Wraps FluidAudio's Parakeet TDT v3 for local transcription. Models are
//  fetched from HuggingFace on first use (~600 MB) and cached. After load,
//  inference runs on the Apple Neural Engine — no network, no audio leaves
//  the device.
//

import AVFoundation
import FluidAudio
import Foundation
import Observation
import OSLog

extension Logger {
    static let transcription = Logger(subsystem: "com.yardtalk.app", category: "transcription")
}

@MainActor
@Observable
final class TranscriptionService {
    enum Status: Equatable {
        case idle
        case downloadingModels
        case ready
        case transcribing
        case failed(message: String)
    }

    private(set) var status: Status = .idle

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

    /// Transcribes the audio from a video/audio file. Tries FluidAudio
    /// directly first; if the codec is unsupported (AAC variants from
    /// ScreenCaptureKit), falls back to extracting a 16 kHz mono WAV
    /// via AVAssetReader and transcribing that.
    func transcribe(fileAt url: URL) async throws -> String {
        try await loadModelsIfNeeded()
        guard let asrManager else { throw TranscriptionError.modelsNotLoaded }
        status = .transcribing
        defer { status = .ready }

        do {
            Logger.transcription.info("attempting direct transcription of \(url.lastPathComponent, privacy: .public)")
            var decoderState = try TdtDecoderState()
            let result = try await asrManager.transcribe(url, decoderState: &decoderState)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            Logger.transcription.info("direct transcription succeeded (\(text.count, privacy: .public) chars)")
            if !text.isEmpty { return text }
            Logger.transcription.info("direct returned empty — trying WAV fallback")
        } catch {
            Logger.transcription.warning("direct failed: \(error.localizedDescription, privacy: .private) — trying WAV fallback")
        }

        let wavURL = try await Self.extractAudioToWAV(from: url)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        Logger.transcription.info("WAV extracted to \(wavURL.lastPathComponent, privacy: .public), transcribing")
        var decoderState = try TdtDecoderState()
        let result = try await asrManager.transcribe(wavURL, decoderState: &decoderState)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        Logger.transcription.info("WAV fallback result (\(text.count, privacy: .public) chars)")
        if text.isEmpty {
            throw TranscriptionError.emptyTranscript
        }
        return text
    }

    /// Extracts the first audio track from a media file into a 16 kHz
    /// mono Float32 WAV in the temp directory. Uses AVAssetReader so
    /// the codec conversion is handled by Core Audio, sidestepping
    /// FluidAudio's AudioConverter which chokes on some AAC variants.
    private static func extractAudioToWAV(from sourceURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscriptionError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        guard reader.canAdd(trackOutput) else {
            throw TranscriptionError.audioExtractionFailed("Cannot add track output to reader")
        }
        reader.add(trackOutput)

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        guard let outputFile = try? AVAudioFile(
            forWriting: wavURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        ) else {
            throw TranscriptionError.audioExtractionFailed("Cannot create output WAV file")
        }

        reader.startReading()

        while reader.status == .reading {
            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else { break }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            let sampleCount = length / MemoryLayout<Float>.size
            guard sampleCount > 0 else { continue }

            guard let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFile.processingFormat,
                frameCapacity: AVAudioFrameCount(sampleCount)
            ) else { continue }

            pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer)
            if let dataPointer, let channelData = pcmBuffer.floatChannelData?[0] {
                memcpy(channelData, dataPointer, length)
            }
            try outputFile.write(from: pcmBuffer)
        }

        if reader.status == .failed {
            try? FileManager.default.removeItem(at: wavURL)
            throw TranscriptionError.audioExtractionFailed(reader.error?.localizedDescription ?? "Unknown reader error")
        }

        Logger.transcription.info("Extracted WAV fallback: \(wavURL.lastPathComponent, privacy: .public)")
        return wavURL
    }
}

enum TranscriptionError: LocalizedError {
    case modelsNotLoaded
    case noAudioTrack
    case audioExtractionFailed(String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .modelsNotLoaded: return "FluidAudio models failed to load."
        case .noAudioTrack: return "Recording has no audio track."
        case .audioExtractionFailed(let m): return "Audio extraction failed: \(m)"
        case .emptyTranscript: return "No speech detected in recording."
        }
    }
}
