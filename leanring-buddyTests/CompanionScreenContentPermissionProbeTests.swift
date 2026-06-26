//
//  CompanionScreenContentPermissionProbeTests.swift
//  leanring-buddyTests
//
//  Tests for the privacy-safe screen-content permission probe boundary.
//

import Foundation
import Testing
@testable import Spider

@MainActor
struct CompanionScreenContentPermissionProbeTests {
    @Test func positiveDimensionsRepresentCapturedContent() async throws {
        let outcome = try await CompanionScreenContentPermissionProbe.run {
            .completed(CompanionScreenContentPermissionProbeResult(width: 320, height: 240))
        }

        guard case .completed(let result) = outcome else {
            Issue.record("Expected completed screen-content probe outcome")
            return
        }
        #expect(result.width == 320)
        #expect(result.height == 240)
        #expect(result.didCapture)
    }

    @Test func zeroSizedCaptureRepresentsDeniedOrEmptyContent() async throws {
        let outcome = try await CompanionScreenContentPermissionProbe.run {
            .completed(CompanionScreenContentPermissionProbeResult(width: 0, height: 240))
        }

        guard case .completed(let result) = outcome else {
            Issue.record("Expected completed screen-content probe outcome")
            return
        }
        #expect(!result.didCapture)
    }

    @Test func noDisplayOutcomeDoesNotRequireScreenshotContent() async throws {
        let outcome = try await CompanionScreenContentPermissionProbe.run {
            .noDisplayAvailable
        }

        #expect(outcome == .noDisplayAvailable)
    }
}
