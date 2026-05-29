//
//  NicheClassifier.swift
//  leanring-buddy
//
//  Scores inferred user niches from local foreground app usage.
//

import Foundation

struct NicheClassificationResult {
    let nicheScores: [NicheDiscoveryManager.Niche: Double]
    let primaryNiche: NicheDiscoveryManager.Niche?
    let confidence: Double
    let profileIsStable: Bool
    let trackedSeconds: TimeInterval
}

final class NicheClassifier {
    static let profileConfidenceThreshold = 0.60
    static let minimumTrackedSeconds: TimeInterval = 7200

    static let minimumTrackedSecondsForAppRanking: TimeInterval = 120
    static let minimumTrackedSecondsForExplicitNicheAppRanking: TimeInterval = 30

    private struct BundleNicheEntry: Decodable {
        struct NicheWeights: Decodable {
            let developer: Double?
            let designer: Double?
            let contentCreator: Double?
            let student: Double?
            let general: Double?

            enum CodingKeys: String, CodingKey {
                case developer
                case designer
                case contentCreator = "content-creator"
                case student
                case general
            }
        }

        let niches: NicheWeights?
        let displayName: String?
        let neutral: Bool?
        let excludeFromProfile: Bool?
    }

    private let bundleMap: [String: BundleNicheEntry]

    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "bundle-niche-map", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: BundleNicheEntry].self, from: data) else {
            bundleMap = [:]
            return
        }
        bundleMap = decoded
    }

    func classify(weightedSecondsByBundleId: [String: TimeInterval]) -> NicheClassificationResult {
        var nicheTotals: [NicheDiscoveryManager.Niche: Double] = [:]
        var trackedSeconds: TimeInterval = 0

        for (bundleId, seconds) in weightedSecondsByBundleId {
            guard let entry = bundleMap[bundleId], entry.excludeFromProfile != true else { continue }
            guard let weights = entry.niches else { continue }

            let nicheWeights = normalizedWeights(from: weights)
            guard !nicheWeights.isEmpty else { continue }

            trackedSeconds += seconds
            for (niche, weight) in nicheWeights {
                nicheTotals[niche, default: 0] += seconds * weight
            }
        }

        let scoreSum = nicheTotals.values.reduce(0, +)
        guard scoreSum > 0 else {
            return NicheClassificationResult(
                nicheScores: [:],
                primaryNiche: nil,
                confidence: 0,
                profileIsStable: false,
                trackedSeconds: trackedSeconds
            )
        }

        var nicheScores: [NicheDiscoveryManager.Niche: Double] = [:]
        for niche in NicheDiscoveryManager.Niche.allCases {
            nicheScores[niche] = (nicheTotals[niche] ?? 0) / scoreSum
        }

        let sortedScores = nicheScores.values.sorted(by: >)
        let topScore = sortedScores.first ?? 0
        let secondScore = sortedScores.dropFirst().first ?? 0
        let confidence = topScore == 0 ? 0 : (topScore - secondScore) / topScore
        let primaryNiche = nicheScores.max(by: { $0.value < $1.value })?.key
        let profileIsStable = trackedSeconds >= Self.minimumTrackedSeconds
            && topScore >= Self.profileConfidenceThreshold

        return NicheClassificationResult(
            nicheScores: nicheScores,
            primaryNiche: primaryNiche,
            confidence: confidence,
            profileIsStable: profileIsStable,
            trackedSeconds: trackedSeconds
        )
    }

    func isNeutralApp(bundleId: String) -> Bool {
        bundleMap[bundleId]?.neutral == true
    }

    func nicheAffinity(bundleId: String, for niche: NicheDiscoveryManager.Niche) -> Double {
        guard let entry = bundleMap[bundleId], let weights = entry.niches else { return 0 }
        let normalizedWeights = normalizedWeights(from: weights)
        return normalizedWeights[niche] ?? 0
    }

    func appMatchesNiche(
        bundleId: String,
        niche: NicheDiscoveryManager.Niche,
        minimumAffinity: Double = 0.35
    ) -> Bool {
        nicheAffinity(bundleId: bundleId, for: niche) >= minimumAffinity
    }

    func rankedBundleIdsMatchingNiche(
        niche: NicheDiscoveryManager.Niche,
        weightedSecondsByBundleId: [String: TimeInterval],
        minimumAffinity: Double = 0.35,
        minimumTrackedSeconds: TimeInterval = NicheClassifier.minimumTrackedSecondsForAppRanking
    ) -> [String] {
        weightedSecondsByBundleId
            .filter { bundleId, trackedSeconds in
                trackedSeconds >= minimumTrackedSeconds
                    && appMatchesNiche(bundleId: bundleId, niche: niche, minimumAffinity: minimumAffinity)
                    && NicheAppSuggestionMapping.appSpecificSuggestions(bundleId: bundleId) != nil
            }
            .sorted { lhs, rhs in lhs.value > rhs.value }
            .map(\.key)
    }

    private func normalizedWeights(from weights: BundleNicheEntry.NicheWeights) -> [NicheDiscoveryManager.Niche: Double] {
        var result: [NicheDiscoveryManager.Niche: Double] = [:]

        if let developer = weights.developer { result[.developer] = developer }
        if let designer = weights.designer { result[.designer] = designer }
        if let contentCreator = weights.contentCreator { result[.contentCreator] = contentCreator }
        if let student = weights.student { result[.student] = student }
        if let general = weights.general {
            result[.other] = (result[.other] ?? 0) + general
        }

        return result
    }
}
