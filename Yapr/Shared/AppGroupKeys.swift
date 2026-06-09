//
//  AppGroupKeys.swift
//  Yapr (compiled into both the app and the Control Center widget extension)
//
//  Centralizes the App Group identifier and shared `UserDefaults` keys used
//  to coordinate state between the main app and the Control Center widget
//  extension. The `AskYaprIntent` invoked by the Control Center button
//  writes a "did launch from Control Center" flag here, and the main app
//  reads/clears it on launch so it knows to auto-fetch the latest screenshot
//  and pre-arm the voice orb.
//

import Foundation

enum AppGroupKeys {
    /// App Group identifier — must match the entitlement on both targets.
    /// If you change the bundle ID prefix, update this string AND both
    /// `Yapr.entitlements` files (app + extension).
    static let identifier = "group.com.tobi.yapr"

    /// Bool flag set by `AskYaprIntent` immediately before iOS opens the app.
    /// Read and cleared by the main app on launch — if true, the app fetches
    /// the most recent screenshot and arms the voice orb without requiring
    /// the user to tap anything.
    static let didLaunchFromControlCenter = "didLaunchFromControlCenter"

    /// Shared `UserDefaults` instance backed by the App Group container.
    static let sharedDefaults: UserDefaults? = UserDefaults(suiteName: identifier)
}
