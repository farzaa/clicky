//
//  AdMissionDomain.swift
//  leanring-buddy
//
//  Local paid-ads mission state and sanitized snapshots shared with the Worker.
//

import Foundation

enum AdMissionStatus: String, Codable, Equatable {
    case draft
    case offerReview = "offer_review"
    case planning
    case guidedSetup = "guided_setup"
    case preflightNeeded = "preflight_needed"
    case fixBeforePublish = "fix_before_publish"
    case readyForManualPublish = "ready_for_manual_publish"
    case publishedManually = "published_manually"
    case reviewDue = "review_due"
    case decisionLogged = "decision_logged"
    case archived

    var displayTitle: String {
        switch self {
        case .draft:
            return "Draft"
        case .offerReview:
            return "Offer review"
        case .planning:
            return "Planning"
        case .guidedSetup:
            return "Guided setup"
        case .preflightNeeded:
            return "Preflight locked"
        case .fixBeforePublish:
            return "Fix before publishing"
        case .readyForManualPublish:
            return "Ready for manual publish"
        case .publishedManually:
            return "Published manually"
        case .reviewDue:
            return "72h Review locked"
        case .decisionLogged:
            return "Decision logged"
        case .archived:
            return "Archived"
        }
    }
}

struct CampaignDirection: Codable, Equatable {
    var recommendedObjective: String
    var whyThisObjective: String
    var whatNotToChoose: String
    var conversionEventSuggestion: String
    var audienceStartingPoint: String
    var creativeAngle: String
    var landingOrTrackingWarning: String
    var riskLevel: SpiderGuideRiskLevel
    var confidence: SpiderGuideConfidence
    var nextStep: String
}

struct AdMissionOfferDraft: Equatable {
    var offer: String
    var audience: String
    var ticket: String
    var country: String
    var language: String
    var budget: String
    var businessGoal: String
    var landingPageURL: String
    var experienceLevel: String
    var recommendedChannel: String
}

extension CampaignDirection {
    func sanitizedForLocalStorage() -> CampaignDirection {
        CampaignDirection(
            recommendedObjective: recommendedObjective.spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxProjectListItemCharacters),
            whyThisObjective: whyThisObjective.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            whatNotToChoose: whatNotToChoose.spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxProjectListItemCharacters),
            conversionEventSuggestion: conversionEventSuggestion.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            audienceStartingPoint: audienceStartingPoint.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            creativeAngle: creativeAngle.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            landingOrTrackingWarning: landingOrTrackingWarning.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            riskLevel: riskLevel,
            confidence: confidence,
            nextStep: nextStep.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxGuideNextStepCharacters)
        )
    }
}

enum AdMissionStoreError: Error {
    case adMissionFileTooLarge
}

struct AdMissionUpdate: Codable, Equatable {
    let offer: String?
    let targetAudience: String?
    let ticket: String?
    let country: String?
    let language: String?
    let budget: String?
    let businessObjective: String?
    let landingPageURL: String?
    let recommendedChannel: String?
    let campaignPlan: String?
    let decisions: [String]?
    let reviewSchedule: String?
}

extension AdMissionUpdate {
    func sanitizedForLocalStorage() -> AdMissionUpdate {
        AdMissionUpdate(
            offer: offer?.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            targetAudience: targetAudience?.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            ticket: ticket?.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            country: country?.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            language: language?.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            budget: budget?.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            businessObjective: businessObjective?.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            landingPageURL: landingPageURL?.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            recommendedChannel: recommendedChannel?.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            campaignPlan: campaignPlan?.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            decisions: decisions?.spiderSanitizedList(),
            reviewSchedule: reviewSchedule?.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters)
        )
    }
}

struct AdMission: Codable, Equatable {
    var id: UUID
    var status: AdMissionStatus?
    var offer: String
    var targetAudience: String
    var ticket: String
    var country: String
    var language: String
    var budget: String
    var businessObjective: String
    var landingPageURL: String
    var experienceLevel: String?
    var recommendedChannel: String
    var campaignDirection: CampaignDirection?
    var campaignPlan: String
    var decisions: [String]
    var reviewSchedule: String
    var artifacts: [SpiderArtifact]
    var updatedAt: Date

    static func empty() -> AdMission {
        AdMission(
            id: UUID(),
            status: .draft,
            offer: "",
            targetAudience: "",
            ticket: "",
            country: "",
            language: "",
            budget: "",
            businessObjective: "",
            landingPageURL: "",
            experienceLevel: "",
            recommendedChannel: "",
            campaignDirection: nil,
            campaignPlan: "",
            decisions: [],
            reviewSchedule: "",
            artifacts: [],
            updatedAt: Date()
        )
    }
}

struct AdMissionGuideSnapshot: Encodable, Equatable {
    struct ArtifactSummary: Encodable, Equatable {
        let kind: SpiderArtifact.Kind
        let title: String
    }

    let offer: String
    let status: AdMissionStatus?
    let targetAudience: String
    let ticket: String
    let country: String
    let language: String
    let budget: String
    let businessObjective: String
    let landingPageURL: String
    let experienceLevel: String?
    let recommendedChannel: String
    let campaignDirection: CampaignDirection?
    let campaignPlan: String
    let decisions: [String]
    let reviewSchedule: String
    let artifacts: [ArtifactSummary]
}

extension AdMission {
    func sanitizedForLocalStorage() -> AdMission {
        var sanitizedMission = self
        sanitizedMission.offer = offer.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters)
        sanitizedMission.targetAudience = targetAudience.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters)
        sanitizedMission.ticket = ticket.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters)
        sanitizedMission.country = country.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters)
        sanitizedMission.language = language.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters)
        sanitizedMission.budget = budget.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters)
        sanitizedMission.businessObjective = businessObjective.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters)
        sanitizedMission.landingPageURL = landingPageURL.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters)
        sanitizedMission.experienceLevel = experienceLevel?.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters)
        sanitizedMission.recommendedChannel = recommendedChannel.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters)
        sanitizedMission.campaignDirection = campaignDirection?.sanitizedForLocalStorage()
        sanitizedMission.campaignPlan = campaignPlan.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters)
        sanitizedMission.decisions = decisions.spiderSanitizedList()
        sanitizedMission.reviewSchedule = reviewSchedule.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters)
        sanitizedMission.artifacts = artifacts
            .compactMap { $0.sanitizedForLocalStorage() }
            .suffix(SpiderContentLimits.maxArtifactsPerProject)
            .map { $0 }
        return sanitizedMission
    }

    func guideSnapshot() -> AdMissionGuideSnapshot {
        let sanitizedMission = sanitizedForLocalStorage()
        let artifactSummaries = sanitizedMission.artifacts
            .suffix(SpiderContentLimits.maxVisionProjectArtifactSummaries)
            .compactMap { artifact -> AdMissionGuideSnapshot.ArtifactSummary? in
                let title = artifact.title.spiderSanitizedSingleLine(
                    maxCharacters: SpiderContentLimits.maxArtifactTitleCharacters
                )
                guard !title.isEmpty else { return nil }
                return AdMissionGuideSnapshot.ArtifactSummary(kind: artifact.kind, title: title)
            }

        return AdMissionGuideSnapshot(
            offer: sanitizedMission.offer.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxVisionProjectTextFieldCharacters),
            status: sanitizedMission.status,
            targetAudience: sanitizedMission.targetAudience.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxVisionProjectTextFieldCharacters),
            ticket: sanitizedMission.ticket.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxVisionProjectTextFieldCharacters),
            country: sanitizedMission.country.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxVisionProjectTextFieldCharacters),
            language: sanitizedMission.language.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxVisionProjectTextFieldCharacters),
            budget: sanitizedMission.budget.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxVisionProjectTextFieldCharacters),
            businessObjective: sanitizedMission.businessObjective.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxVisionProjectTextFieldCharacters),
            landingPageURL: sanitizedMission.landingPageURL.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxVisionProjectTextFieldCharacters),
            experienceLevel: sanitizedMission.experienceLevel?.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxVisionProjectTextFieldCharacters),
            recommendedChannel: sanitizedMission.recommendedChannel.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxVisionProjectTextFieldCharacters),
            campaignDirection: sanitizedMission.campaignDirection?.sanitizedForLocalStorage(),
            campaignPlan: sanitizedMission.campaignPlan.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxVisionProjectTextFieldCharacters),
            decisions: sanitizedMission.decisions.spiderSanitizedList(
                maxItems: SpiderContentLimits.maxVisionProjectListItems,
                maxCharacters: SpiderContentLimits.maxVisionProjectListItemCharacters
            ),
            reviewSchedule: sanitizedMission.reviewSchedule.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxVisionProjectTextFieldCharacters),
            artifacts: artifactSummaries
        )
    }
}

enum AdMissionStore {
    private static let fileName = "AdMission.json"

    static func load() -> AdMission {
        let missionURL = adMissionFileURL()
        if let attributes = try? FileManager.default.attributesOfItem(atPath: missionURL.path),
           let fileSize = attributes[.size] as? NSNumber,
           fileSize.intValue > SpiderContentLimits.maxProjectFileBytes {
            return .empty()
        }

        guard let data = try? Data(contentsOf: missionURL),
              data.count <= SpiderContentLimits.maxProjectFileBytes else {
            return .empty()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AdMission.self, from: data).sanitizedForLocalStorage()) ?? .empty()
    }

    static func save(_ mission: AdMission) throws {
        var missionToSave = mission.sanitizedForLocalStorage()
        missionToSave.updatedAt = Date()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let directoryURL = applicationSupportDirectoryURL()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )

        let missionURL = adMissionFileURL()
        let encodedMission = try encoder.encode(missionToSave)
        guard encodedMission.count <= SpiderContentLimits.maxProjectFileBytes else {
            throw AdMissionStoreError.adMissionFileTooLarge
        }
        try encodedMission.write(to: missionURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: missionURL.path
        )
    }

    static func reset() throws -> AdMission {
        let emptyMission = AdMission.empty()
        try save(emptyMission)
        return emptyMission
    }

    private static func adMissionFileURL() -> URL {
        applicationSupportDirectoryURL().appendingPathComponent(fileName)
    }

    private static func applicationSupportDirectoryURL() -> URL {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            preconditionFailure("Application Support directory is unavailable.")
        }
        return baseURL.appendingPathComponent("Spider", isDirectory: true)
    }
}
