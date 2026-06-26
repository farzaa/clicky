//
//  GroundingSensorFusionTiming.swift
//  leanring-buddy
//
//  Timing and latency-cutoff helpers for local sensor fusion.
//

import Foundation

enum GroundingSensorFusionTiming {
    struct MeasuredValue<Value> {
        let value: Value
        let latencyMs: Int
    }

    static func measureSignal(
        source _: GroundingAuxiliarySignalSource,
        cutoffMs: Int?,
        operation: () -> GroundingAuxiliarySignal
    ) -> GroundingAuxiliarySignal {
        let startedAt = Date()
        let signal = operation()
        let latencyMs = elapsedMilliseconds(since: startedAt)
        return signalAfterApplyingLatencyCutoff(
            signal,
            cutoffMs: cutoffMs,
            measuredLatencyMs: latencyMs
        )
    }

    static func measureValue<Value>(
        source _: GroundingAuxiliarySignalSource,
        cutoffMs _: Int?,
        operation: () -> Value
    ) -> MeasuredValue<Value> {
        let startedAt = Date()
        let value = operation()
        return MeasuredValue(value: value, latencyMs: elapsedMilliseconds(since: startedAt))
    }

    static func measureOptional<Value>(
        source _: GroundingAuxiliarySignalSource,
        cutoffMs _: Int?,
        operation: () -> Value?
    ) -> MeasuredValue<Value?> {
        let startedAt = Date()
        let value = operation()
        return MeasuredValue(value: value, latencyMs: elapsedMilliseconds(since: startedAt))
    }

    static func signalAfterApplyingLatencyCutoff(
        _ signal: GroundingAuxiliarySignal,
        cutoffMs: Int?,
        measuredLatencyMs: Int
    ) -> GroundingAuxiliarySignal {
        guard let cutoffMs,
              measuredLatencyMs > cutoffMs else {
            return signal.withLatency(measuredLatencyMs)
        }
        return .unavailable(signal.source, latencyMs: measuredLatencyMs)
    }

    static func elapsedMilliseconds(since startDate: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startDate) * 1000))
    }
}
