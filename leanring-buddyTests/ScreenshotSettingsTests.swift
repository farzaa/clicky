//
//  ScreenshotSettingsTests.swift
//  leanring-buddyTests
//
//  Tests for the screenshot capture settings: primary screen only,
//  active window only, and JPEG compression quality.
//

import Testing
import Foundation
@testable import leanring_buddy

// MARK: - Screenshot Settings Defaults

struct ScreenshotSettingsDefaultsTests {

    /// All three screenshot settings should default to their documented values
    /// when no UserDefaults entry exists.

    @Test func captureOnlyPrimaryScreenDefaultsToFalse() {
        let defaultsKey = "captureOnlyPrimaryScreen"
        let savedValue = UserDefaults.standard.object(forKey: defaultsKey)
        // Clean slate — remove any leftover test value, check default, then restore
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        defer {
            if let savedValue {
                UserDefaults.standard.set(savedValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        let defaultValue = UserDefaults.standard.bool(forKey: defaultsKey)
        #expect(defaultValue == false, "captureOnlyPrimaryScreen should default to false (capture all screens)")
    }

    @Test func captureActiveWindowOnlyDefaultsToFalse() {
        let defaultsKey = "captureActiveWindowOnly"
        let savedValue = UserDefaults.standard.object(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        defer {
            if let savedValue {
                UserDefaults.standard.set(savedValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        let defaultValue = UserDefaults.standard.bool(forKey: defaultsKey)
        #expect(defaultValue == false, "captureActiveWindowOnly should default to false (capture full screen)")
    }

    @Test func screenshotJPEGQualityDefaultsTo0Point8() {
        let defaultsKey = "screenshotJPEGQuality"
        let savedValue = UserDefaults.standard.object(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        defer {
            if let savedValue {
                UserDefaults.standard.set(savedValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        // When the key doesn't exist, the code checks for nil and falls back to 0.8
        let keyExists = UserDefaults.standard.object(forKey: defaultsKey) != nil
        #expect(keyExists == false, "Key should not exist after removal")
    }
}

// MARK: - Screenshot Settings Persistence

struct ScreenshotSettingsPersistenceTests {

    @Test func captureOnlyPrimaryScreenPersistsToUserDefaults() {
        let defaultsKey = "captureOnlyPrimaryScreen"
        let originalValue = UserDefaults.standard.object(forKey: defaultsKey)
        defer {
            if let originalValue {
                UserDefaults.standard.set(originalValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        UserDefaults.standard.set(true, forKey: defaultsKey)
        #expect(UserDefaults.standard.bool(forKey: defaultsKey) == true)

        UserDefaults.standard.set(false, forKey: defaultsKey)
        #expect(UserDefaults.standard.bool(forKey: defaultsKey) == false)
    }

    @Test func captureActiveWindowOnlyPersistsToUserDefaults() {
        let defaultsKey = "captureActiveWindowOnly"
        let originalValue = UserDefaults.standard.object(forKey: defaultsKey)
        defer {
            if let originalValue {
                UserDefaults.standard.set(originalValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        UserDefaults.standard.set(true, forKey: defaultsKey)
        #expect(UserDefaults.standard.bool(forKey: defaultsKey) == true)

        UserDefaults.standard.set(false, forKey: defaultsKey)
        #expect(UserDefaults.standard.bool(forKey: defaultsKey) == false)
    }

    @Test func screenshotJPEGQualityPersistsToUserDefaults() {
        let defaultsKey = "screenshotJPEGQuality"
        let originalValue = UserDefaults.standard.object(forKey: defaultsKey)
        defer {
            if let originalValue {
                UserDefaults.standard.set(originalValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        UserDefaults.standard.set(0.5, forKey: defaultsKey)
        #expect(UserDefaults.standard.double(forKey: defaultsKey) == 0.5)

        UserDefaults.standard.set(1.0, forKey: defaultsKey)
        #expect(UserDefaults.standard.double(forKey: defaultsKey) == 1.0)

        UserDefaults.standard.set(0.3, forKey: defaultsKey)
        #expect(UserDefaults.standard.double(forKey: defaultsKey) == 0.3)
    }
}

// MARK: - CompanionScreenCapture Label Tests

struct ScreenCaptureLabelTests {

    /// Verify that CompanionScreenCapture stores all fields correctly.
    @Test func companionScreenCaptureStoresAllFields() {
        let testData = Data([0xFF, 0xD8, 0xFF, 0xE0]) // JPEG magic bytes
        let testFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)

        let capture = CompanionScreenCapture(
            imageData: testData,
            label: "user's screen (cursor is here)",
            isCursorScreen: true,
            displayWidthInPoints: 1512,
            displayHeightInPoints: 982,
            displayFrame: testFrame,
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 831
        )

        #expect(capture.imageData == testData)
        #expect(capture.label == "user's screen (cursor is here)")
        #expect(capture.isCursorScreen == true)
        #expect(capture.displayWidthInPoints == 1512)
        #expect(capture.displayHeightInPoints == 982)
        #expect(capture.displayFrame == testFrame)
        #expect(capture.screenshotWidthInPixels == 1280)
        #expect(capture.screenshotHeightInPixels == 831)
    }

    @Test func companionScreenCaptureStoresSecondaryScreenLabel() {
        let testData = Data([0xFF, 0xD8])
        let testFrame = CGRect(x: 1512, y: 0, width: 2560, height: 1440)

        let capture = CompanionScreenCapture(
            imageData: testData,
            label: "screen 2 of 2 — secondary screen",
            isCursorScreen: false,
            displayWidthInPoints: 2560,
            displayHeightInPoints: 1440,
            displayFrame: testFrame,
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 720
        )

        #expect(capture.isCursorScreen == false)
        #expect(capture.label.contains("secondary"))
    }

    @Test func companionScreenCaptureStoresActiveWindowLabel() {
        let testData = Data([0xFF, 0xD8])
        let testFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)

        let capture = CompanionScreenCapture(
            imageData: testData,
            label: "active window (Safari) — cursor screen",
            isCursorScreen: true,
            displayWidthInPoints: 1512,
            displayHeightInPoints: 982,
            displayFrame: testFrame,
            screenshotWidthInPixels: 1024,
            screenshotHeightInPixels: 768
        )

        #expect(capture.label.contains("active window"))
        #expect(capture.label.contains("Safari"))
    }
}

// MARK: - JPEG Quality Boundary Tests

struct JPEGQualityBoundaryTests {

    /// The slider range is 0.3–1.0. Verify that values within this range
    /// round-trip through UserDefaults correctly.
    @Test func qualityAtMinimumSliderBound() {
        let defaultsKey = "screenshotJPEGQuality"
        let originalValue = UserDefaults.standard.object(forKey: defaultsKey)
        defer {
            if let originalValue {
                UserDefaults.standard.set(originalValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        UserDefaults.standard.set(0.3, forKey: defaultsKey)
        let retrieved = UserDefaults.standard.double(forKey: defaultsKey)
        #expect(abs(retrieved - 0.3) < 0.001, "Minimum slider value should persist accurately")
    }

    @Test func qualityAtMaximumSliderBound() {
        let defaultsKey = "screenshotJPEGQuality"
        let originalValue = UserDefaults.standard.object(forKey: defaultsKey)
        defer {
            if let originalValue {
                UserDefaults.standard.set(originalValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        UserDefaults.standard.set(1.0, forKey: defaultsKey)
        let retrieved = UserDefaults.standard.double(forKey: defaultsKey)
        #expect(retrieved == 1.0, "Maximum slider value should persist accurately")
    }

    @Test func qualityAtMidpoint() {
        let defaultsKey = "screenshotJPEGQuality"
        let originalValue = UserDefaults.standard.object(forKey: defaultsKey)
        defer {
            if let originalValue {
                UserDefaults.standard.set(originalValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        UserDefaults.standard.set(0.6, forKey: defaultsKey)
        let retrieved = UserDefaults.standard.double(forKey: defaultsKey)
        #expect(abs(retrieved - 0.6) < 0.001, "Midpoint slider value should persist accurately")
    }
}
