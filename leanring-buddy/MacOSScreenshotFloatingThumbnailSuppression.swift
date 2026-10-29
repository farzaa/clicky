//
//  MacOSScreenshotFloatingThumbnailSuppression.swift
//  leanring-buddy
//
//  Keeps macOS from showing screenshot floating thumbnails while Clicky is
//  running. Restores the user's prior preference when the app quits.
//

import CoreFoundation
import Foundation

enum MacOSScreenshotFloatingThumbnailSuppression {
  private static let screencapturePreferenceDomain = "com.apple.screencapture" as CFString
  private static let screencaptureUIPreferenceDomain = "com.apple.screencaptureui" as CFString
  private static let showThumbnailPreferenceKey = "show-thumbnail" as CFString
  private static let thumbnailExpirationPreferenceKey = "thumbnailExpiration" as CFString
  private static var savedShowThumbnailPreference: CFPropertyList?
  private static var savedThumbnailExpirationPreference: CFPropertyList?
  private static var isSuppressingForAppLifetime = false

  static func enableForAppLifetime() {
    guard !isSuppressingForAppLifetime else { return }

    savedShowThumbnailPreference = CFPreferencesCopyAppValue(
      showThumbnailPreferenceKey,
      screencapturePreferenceDomain
    )
    savedThumbnailExpirationPreference = CFPreferencesCopyAppValue(
      thumbnailExpirationPreferenceKey,
      screencaptureUIPreferenceDomain
    )

    CFPreferencesSetValue(
      showThumbnailPreferenceKey,
      kCFBooleanFalse,
      screencapturePreferenceDomain,
      kCFPreferencesAnyUser,
      kCFPreferencesCurrentHost
    )
    CFPreferencesSetValue(
      thumbnailExpirationPreferenceKey,
      0.001 as CFPropertyList,
      screencaptureUIPreferenceDomain,
      kCFPreferencesAnyUser,
      kCFPreferencesCurrentHost
    )

    CFPreferencesSynchronize(
      screencapturePreferenceDomain,
      kCFPreferencesAnyUser,
      kCFPreferencesCurrentHost
    )
    CFPreferencesSynchronize(
      screencaptureUIPreferenceDomain,
      kCFPreferencesAnyUser,
      kCFPreferencesCurrentHost
    )

    isSuppressingForAppLifetime = true
    MacOSScreenshotFloatingThumbnailDismisser.dismissIfNeeded()
  }

  static func restoreAfterAppTermination() {
    guard isSuppressingForAppLifetime else { return }

    if let savedShowThumbnailPreference {
      CFPreferencesSetValue(
        showThumbnailPreferenceKey,
        savedShowThumbnailPreference,
        screencapturePreferenceDomain,
        kCFPreferencesAnyUser,
        kCFPreferencesCurrentHost
      )
    } else {
      CFPreferencesSetValue(
        showThumbnailPreferenceKey,
        nil,
        screencapturePreferenceDomain,
        kCFPreferencesAnyUser,
        kCFPreferencesCurrentHost
      )
    }

    if let savedThumbnailExpirationPreference {
      CFPreferencesSetValue(
        thumbnailExpirationPreferenceKey,
        savedThumbnailExpirationPreference,
        screencaptureUIPreferenceDomain,
        kCFPreferencesAnyUser,
        kCFPreferencesCurrentHost
      )
    } else {
      CFPreferencesSetValue(
        thumbnailExpirationPreferenceKey,
        nil,
        screencaptureUIPreferenceDomain,
        kCFPreferencesAnyUser,
        kCFPreferencesCurrentHost
      )
    }

    CFPreferencesSynchronize(
      screencapturePreferenceDomain,
      kCFPreferencesAnyUser,
      kCFPreferencesCurrentHost
    )
    CFPreferencesSynchronize(
      screencaptureUIPreferenceDomain,
      kCFPreferencesAnyUser,
      kCFPreferencesCurrentHost
    )

    savedShowThumbnailPreference = nil
    savedThumbnailExpirationPreference = nil
    isSuppressingForAppLifetime = false
  }
}
