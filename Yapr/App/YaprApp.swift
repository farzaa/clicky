//
//  YaprApp.swift
//  Yapr
//
//  Entry point for the iOS app. SwiftUI lifecycle, single window scene,
//  dark color scheme everywhere. The actual screen layout lives in
//  `RootView`.
//

import SwiftUI

@main
struct YaprApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}
