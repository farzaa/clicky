//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Foundation
import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func pipAtlasLayoutMatchesTheBundledSpriteSheet() {
        #expect(LearningPetAnimation.atlasColumnCount == 8)
        #expect(LearningPetAnimation.atlasRowCount == 11)
        #expect(LearningPetAnimation.atlasCellWidth == 192)
        #expect(LearningPetAnimation.atlasCellHeight == 208)

        #expect(LearningPetAnimation.idle.rowIndex == 0)
        #expect(LearningPetAnimation.runningRight.rowIndex == 1)
        #expect(LearningPetAnimation.runningLeft.rowIndex == 2)
        #expect(LearningPetAnimation.looking(directionIndex: 0).rowIndex == 9)
        #expect(LearningPetAnimation.looking(directionIndex: 8).rowIndex == 10)
        #expect(LearningPetAnimation.looking(directionIndex: 15).firstFrameColumn == 7)
    }

    @Test func pipAnimationTimingIsDeterministicAndLoops() {
        let startedAt = Date(timeIntervalSince1970: 0)
        let running = LearningPetAnimation.runningRight

        #expect(running.frameColumn(
            at: startedAt,
            animationStartedAt: startedAt,
            reduceMotion: false
        ) == 0)
        #expect(running.frameColumn(
            at: startedAt.addingTimeInterval(0.13),
            animationStartedAt: startedAt,
            reduceMotion: false
        ) == 1)
        #expect(running.frameColumn(
            at: startedAt.addingTimeInterval(1.07),
            animationStartedAt: startedAt,
            reduceMotion: false
        ) == 0)
        #expect(running.frameColumn(
            at: startedAt.addingTimeInterval(0.5),
            animationStartedAt: startedAt,
            reduceMotion: true
        ) == running.reducedMotionFrameColumn)
    }

    @Test func pipDirectionResolverUsesSixteenClockwiseDirections() {
        #expect(LearningPetDirectionResolver.directionIndex(toward: CGVector(dx: 0, dy: -10)) == 0)
        #expect(LearningPetDirectionResolver.directionIndex(toward: CGVector(dx: 10, dy: 0)) == 4)
        #expect(LearningPetDirectionResolver.directionIndex(toward: CGVector(dx: 0, dy: 10)) == 8)
        #expect(LearningPetDirectionResolver.directionIndex(toward: CGVector(dx: -10, dy: 0)) == 12)
        #expect(LearningPetDirectionResolver.directionIndex(toward: CGVector(dx: 0.1, dy: 0.1)) == nil)
    }

    @Test func pipPresentationMirrorsClickysExistingState() {
        #expect(LearningPetPresentationResolver.animation(
            voiceState: .idle,
            navigationMode: .navigatingToTarget,
            isMovingHorizontally: false,
            isMovingRight: true
        ) == .runningRight)
        #expect(LearningPetPresentationResolver.animation(
            voiceState: .responding,
            navigationMode: .pointingAtTarget,
            isMovingHorizontally: false,
            isMovingRight: false
        ) == .jumping)
        #expect(LearningPetPresentationResolver.animation(
            voiceState: .responding,
            navigationMode: .pointingAtTarget,
            isMovingHorizontally: false,
            isMovingRight: true,
            pointingDirection: CGVector(dx: 10, dy: 0)
        ) == .looking(directionIndex: 4))
        #expect(LearningPetPresentationResolver.animation(
            voiceState: .listening,
            navigationMode: .followingCursor,
            isMovingHorizontally: false,
            isMovingRight: true
        ) == .waiting)
        #expect(LearningPetPresentationResolver.animation(
            voiceState: .processing,
            navigationMode: .followingCursor,
            isMovingHorizontally: false,
            isMovingRight: true
        ) == .working)
        #expect(LearningPetPresentationResolver.animation(
            voiceState: .responding,
            navigationMode: .followingCursor,
            isMovingHorizontally: false,
            isMovingRight: true
        ) == .review)
    }

    @Test func kidFriendlyPromptAddsGuidanceWithoutChangingPointingContract() {
        let standardPrompt = CompanionManager.companionVoiceResponseSystemPrompt(
            kidsModeEnabled: false
        )
        let kidFriendlyPrompt = CompanionManager.companionVoiceResponseSystemPrompt(
            kidsModeEnabled: true
        )

        #expect(!standardPrompt.contains("kid-friendly reply mode"))
        #expect(kidFriendlyPrompt.contains("kid-friendly reply mode"))
        #expect(kidFriendlyPrompt.contains("never ask for personal information"))
        #expect(kidFriendlyPrompt.contains("[POINT:x,y:label]"))
        #expect(kidFriendlyPrompt.hasPrefix(standardPrompt))
    }

}
