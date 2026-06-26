//
//  SpiderProductFeatures.swift
//  leanring-buddy
//
//  Central product availability contract for MVP-gated features.
//

import Foundation

enum SpiderProductFeature: String, CaseIterable, Hashable {
    case firstStepGuidedSetup = "first_step_guided_setup"
    case preflightAudit = "preflight_audit"
    case review72h = "review_72h"
}

enum SpiderProductFeatureAvailability: Equatable {
    case available
    case locked
}

struct SpiderProductFeatureDescriptor: Equatable {
    let feature: SpiderProductFeature
    let availability: SpiderProductFeatureAvailability
    let planLineCopyKey: String
    let lockedStatusText: String
    let lockedVoiceText: String
    let transcriptionKeyterms: [String]

    nonisolated var isAvailable: Bool {
        switch availability {
        case .available:
            return true
        case .locked:
            return false
        }
    }
}

enum SpiderProductFeatures {
    nonisolated static let mvpLockedReviewSchedule = "Stop before publishing. Preflight and 72h Review are locked in this MVP."
    nonisolated static let postLaunchReviewLockedSchedule = "Post-launch review is locked in this MVP."

    nonisolated static let planFeatureDescriptors: [SpiderProductFeatureDescriptor] = [
        descriptor(for: .firstStepGuidedSetup),
        descriptor(for: .preflightAudit),
        descriptor(for: .review72h),
    ]

    nonisolated static var availableTranscriptionKeyterms: [String] {
        SpiderProductFeature.allCases
            .map(descriptor(for:))
            .filter(\.isAvailable)
            .flatMap(\.transcriptionKeyterms)
    }

    nonisolated static func isAvailable(_ feature: SpiderProductFeature) -> Bool {
        descriptor(for: feature).isAvailable
    }

    nonisolated static func descriptor(for feature: SpiderProductFeature) -> SpiderProductFeatureDescriptor {
        switch feature {
        case .firstStepGuidedSetup:
            return SpiderProductFeatureDescriptor(
                feature: feature,
                availability: .available,
                planLineCopyKey: "First-step guided setup",
                lockedStatusText: "Guided setup locked",
                lockedVoiceText: "Guided setup is locked.",
                transcriptionKeyterms: [
                    "Guided Setup",
                    "Build from Scratch",
                    "campaign direction",
                    "Ad Mission",
                ]
            )
        case .preflightAudit:
            return SpiderProductFeatureDescriptor(
                feature: feature,
                availability: .locked,
                planLineCopyKey: "Preflight locked",
                lockedStatusText: "Preflight locked",
                lockedVoiceText: "Preflight is locked in this MVP.",
                transcriptionKeyterms: []
            )
        case .review72h:
            return SpiderProductFeatureDescriptor(
                feature: feature,
                availability: .locked,
                planLineCopyKey: "72h Review locked",
                lockedStatusText: "72h Review locked",
                lockedVoiceText: "72h Review is locked in this MVP.",
                transcriptionKeyterms: []
            )
        }
    }
}
