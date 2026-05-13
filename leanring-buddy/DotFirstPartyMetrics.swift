//
//  DotFirstPartyMetrics.swift
//  leanring-buddy
//
//  Sends low-cardinality product funnel events to vibe-id so /admin can answer
//  where users drop off. Never send transcript text, response text, screenshots,
//  file paths, window titles, or other user content here.
//

import Foundation

enum DotFirstPartyMetrics {
    private static let maxStringPropertyLength = 300

    static func record(
        _ eventName: String,
        dimension: String? = nil,
        properties: [String: Any] = [:]
    ) {
        guard let installToken = DotInstallTokenStore.currentInstallToken(),
              let url = URL(string: "\(AppBundleConfiguration.vibeIdBaseURLString())/client-events") else {
            return
        }

        var body: [String: Any] = [
            "event_name": eventName,
            "properties": sanitizedProperties(properties).merging(appVersionProperties()) { current, _ in current },
        ]
        if let dimension = normalizedDimension(dimension) {
            body["event_dimension"] = dimension
        }

        guard JSONSerialization.isValidJSONObject(body),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return
        }

        Task.detached(priority: .utility) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(installToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = bodyData

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    DotDebugLogger.log("metrics.first_party", "client event rejected", metadata: [
                        "eventName": eventName,
                        "statusCode": httpResponse.statusCode,
                    ])
                }
            } catch {
                DotDebugLogger.log("metrics.first_party", "client event failed", metadata: [
                    "eventName": eventName,
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    private static func appVersionProperties() -> [String: Any] {
        [
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "app_build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
        ]
    }

    private static func sanitizedProperties(_ properties: [String: Any]) -> [String: Any] {
        var output: [String: Any] = [:]
        for (key, value) in properties {
            guard key.range(of: #"^[A-Za-z0-9_.:-]{1,80}$"#, options: .regularExpression) != nil else {
                continue
            }
            switch value {
            case let stringValue as String:
                output[key] = String(stringValue.prefix(maxStringPropertyLength))
            case let integerValue as Int:
                output[key] = integerValue
            case let doubleValue as Double where doubleValue.isFinite:
                output[key] = doubleValue
            case let booleanValue as Bool:
                output[key] = booleanValue
            default:
                continue
            }
        }
        return output
    }

    private static func normalizedDimension(_ dimension: String?) -> String? {
        guard let dimension else { return nil }
        let trimmed = dimension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.:-")
        var normalized = ""
        for scalar in trimmed.unicodeScalars {
            if allowedCharacters.contains(scalar) {
                normalized.unicodeScalars.append(scalar)
            } else {
                normalized.append("_")
            }
        }
        return String(normalized.prefix(80))
    }
}
