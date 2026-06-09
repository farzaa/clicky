//
//  BuddyAudioConversionSupport.swift
//  ClickyShared
//
//  Audio conversion helpers shared by transcription providers. Lifted from
//  the open-source Clicky macOS app — works identically on iOS and macOS
//  because AVFoundation's PCM conversion APIs are cross-platform.
//

import AVFoundation
import Foundation

/// Converts live microphone PCM buffers (any input format) into mono PCM16
/// at a fixed target sample rate. AssemblyAI's streaming endpoint expects
/// mono PCM16 at 16 kHz, so we convert on every buffer before sending.
public final class BuddyPCM16AudioConverter {
    private let targetAudioFormat: AVAudioFormat
    private var audioConverter: AVAudioConverter?
    private var currentInputFormatDescription: String?

    public init(targetSampleRate: Double) {
        self.targetAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        )!
    }

    public func convertToPCM16Data(from audioBuffer: AVAudioPCMBuffer) -> Data? {
        let inputFormatDescription = audioBuffer.format.settings.description

        // Lazily rebuild the converter when the input format changes, e.g. if
        // the system mic switches between built-in and Bluetooth.
        if currentInputFormatDescription != inputFormatDescription {
            audioConverter = AVAudioConverter(from: audioBuffer.format, to: targetAudioFormat)
            currentInputFormatDescription = inputFormatDescription
        }

        guard let audioConverter else { return nil }

        let sampleRateRatio = targetAudioFormat.sampleRate / audioBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            (Double(audioBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetAudioFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var hasProvidedSourceBuffer = false
        var conversionError: NSError?

        let conversionStatus = audioConverter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if hasProvidedSourceBuffer {
                outStatus.pointee = .noDataNow
                return nil
            }

            hasProvidedSourceBuffer = true
            outStatus.pointee = .haveData
            return audioBuffer
        }

        guard conversionStatus != .error else { return nil }
        guard let pcmDataPointer = outputBuffer.audioBufferList.pointee.mBuffers.mData else { return nil }

        let bytesPerFrame = Int(targetAudioFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(outputBuffer.frameLength) * bytesPerFrame
        guard byteCount > 0 else { return nil }

        return Data(bytes: pcmDataPointer, count: byteCount)
    }
}
