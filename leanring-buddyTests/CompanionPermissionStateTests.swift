//
//  CompanionPermissionStateTests.swift
//  leanring-buddyTests
//
//  Domain tests for companion permission transitions and analytics-safe names.
//

import Foundation
import Testing
@testable import Spider

struct CompanionPermissionStateTests {
    @Test func allRequiredGrantedRequiresEveryPermission() {
        let complete = CompanionPermissionState(
            hasAccessibility: true,
            hasScreenRecording: true,
            hasMicrophone: true,
            hasScreenContent: true
        )
        let missingScreenContent = CompanionPermissionState(
            hasAccessibility: true,
            hasScreenRecording: true,
            hasMicrophone: true,
            hasScreenContent: false
        )

        #expect(complete.allRequiredGranted)
        #expect(!missingScreenContent.allRequiredGranted)
    }

    @Test func transitionTracksOnlyPromptPermissionChangesForPromptDiagnostics() {
        let previous = CompanionPermissionState(
            hasAccessibility: false,
            hasScreenRecording: true,
            hasMicrophone: true,
            hasScreenContent: false
        )
        let current = CompanionPermissionState(
            hasAccessibility: false,
            hasScreenRecording: true,
            hasMicrophone: true,
            hasScreenContent: true
        )

        let transition = CompanionPermissionPolicy.transition(from: previous, to: current)

        #expect(!transition.didPromptPermissionStateChange)
        #expect(transition.newlyGrantedPromptPermissions.isEmpty)
        #expect(!transition.didBecomeFullyGranted)
    }

    @Test func transitionExposesTypedPromptPermissionGrantEvents() {
        let previous = CompanionPermissionState(
            hasAccessibility: false,
            hasScreenRecording: false,
            hasMicrophone: false,
            hasScreenContent: true
        )
        let current = CompanionPermissionState(
            hasAccessibility: true,
            hasScreenRecording: true,
            hasMicrophone: true,
            hasScreenContent: true
        )

        let transition = CompanionPermissionPolicy.transition(from: previous, to: current)

        #expect(transition.didPromptPermissionStateChange)
        #expect(transition.newlyGrantedPromptPermissions == [.accessibility, .screenRecording, .microphone])
        #expect(transition.newlyGrantedPromptPermissions.map(\.telemetryName) == [
            .accessibility,
            .screenRecording,
            .microphone
        ])
        #expect(transition.newlyGrantedPromptPermissions.map { $0.telemetryName.rawValue } == [
            "accessibility",
            "screen_recording",
            "microphone"
        ])
        #expect(CompanionPermissionPolicy.promptPermissionGrantTelemetryNames(for: transition) == [
            .accessibility,
            .screenRecording,
            .microphone
        ])
        #expect(transition.didBecomeFullyGranted)
    }

    @Test func diagnosticFlagsKeepPermissionKeysTypedAndOrdered() {
        #expect(CompanionPermissionKind.accessibility.diagnosticFlagKey.diagnosticName == "permission_accessibility")
        #expect(CompanionPermissionKind.screenRecording.diagnosticFlagKey.diagnosticName == "permission_screen_recording")
        #expect(CompanionPermissionKind.microphone.diagnosticFlagKey.diagnosticName == "permission_microphone")
        #expect(CompanionPermissionKind.screenContent.diagnosticFlagKey.diagnosticName == "permission_screen_content")

        let state = CompanionPermissionState(
            hasAccessibility: true,
            hasScreenRecording: false,
            hasMicrophone: true,
            hasScreenContent: false
        )
        let flags = CompanionPermissionPolicy.diagnosticFlags(for: state)

        #expect(flags.map { $0.key.diagnosticName } == [
            "permission_accessibility",
            "permission_screen_recording",
            "permission_microphone",
            "permission_screen_content"
        ])
        #expect(flags.map(\.value) == [true, false, true, false])
    }

    @Test func screenGuidancePermissionAllowsSessionLaunchExceptionForScreenRecording() {
        #expect(
            CompanionPermissionPolicy.screenGuidancePermissionsReady(
                hasScreenContentPermission: true,
                shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch: true
            )
        )
        #expect(
            !CompanionPermissionPolicy.screenGuidancePermissionsReady(
                hasScreenContentPermission: false,
                shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch: true
            )
        )
        #expect(
            !CompanionPermissionPolicy.screenGuidancePermissionsReady(
                hasScreenContentPermission: true,
                shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch: false
            )
        )
    }
}
