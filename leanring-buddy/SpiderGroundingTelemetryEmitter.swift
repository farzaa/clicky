//
//  SpiderGroundingTelemetryEmitter.swift
//  leanring-buddy
//
//  Local-only grounding telemetry emission boundary. It keeps opt-in gating,
//  app-version sanitization, and metric serialization out of the typed event
//  construction APIs.
//

import Foundation

enum SpiderGroundingTelemetryEmitter {
    private static var groundingTelemetryEnabledDefaultsKey: String {
        "com.spider.groundingTelemetry.enabled"
    }

    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: groundingTelemetryEnabledDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: groundingTelemetryEnabledDefaultsKey)
    }

    static var safeAppVersion: String? {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let appVersion = [version, build]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "+")
        return SpiderGroundingTelemetrySanitizer.sanitizedIdentifier(
            appVersion,
            maxCharacters: SpiderGroundingTelemetrySanitizer.maxAppVersionCharacters
        )
    }

    static var groundingSchemaVersion: Int {
        SpiderGroundingTelemetrySanitizer.groundingSchemaVersion
    }

    static func emit(_ event: SpiderGroundingTelemetryEvent) {
        guard isEnabled else {
            return
        }

        let payload = event.sanitizedPayload
        let serializedPayload = payload.keys.sorted().map { key in
            "\(key)=\(payload[key] ?? "")"
        }.joined(separator: ":")
        SpiderAnalytics.logMetric("\(event.name.rawValue):\(serializedPayload)")
    }
}
