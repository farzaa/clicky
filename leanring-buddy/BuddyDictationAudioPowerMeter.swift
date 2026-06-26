//
//  BuddyDictationAudioPowerMeter.swift
//  leanring-buddy
//
//  Pure audio-level helpers for the push-to-talk waveform.
//

import AVFoundation
import CoreGraphics
import Foundation

enum BuddyDictationAudioPowerMeter {
    static let historyLength = 44
    static let baselineLevel: CGFloat = 0.02
    static let sampleIntervalSeconds: TimeInterval = 0.07

    static func baselineHistory() -> [CGFloat] {
        Array(repeating: baselineLevel, count: historyLength)
    }

    static func boostedLevel(from audioBuffer: AVAudioPCMBuffer) -> CGFloat? {
        guard let channelData = audioBuffer.floatChannelData else { return nil }

        let channelSamples = channelData[0]
        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return nil }

        var summedSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = channelSamples[sampleIndex]
            summedSquares += sample * sample
        }

        let rootMeanSquare = sqrt(summedSquares / Float(frameCount))
        return CGFloat(min(max(rootMeanSquare * 10.2, 0), 1))
    }

    static func smoothedLevel(currentLevel: CGFloat, boostedLevel: CGFloat) -> CGFloat {
        max(boostedLevel, currentLevel * 0.72)
    }

    static func shouldRecordSample(lastSampledAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastSampledAt) >= sampleIntervalSeconds
    }

    static func history(afterAppending audioPowerSample: CGFloat, to history: [CGFloat]) -> [CGFloat] {
        var updatedHistory = history
        updatedHistory.append(audioPowerSample)

        if updatedHistory.count > historyLength {
            updatedHistory.removeFirst(updatedHistory.count - historyLength)
        }

        return updatedHistory
    }
}
