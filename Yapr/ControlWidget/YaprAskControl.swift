//
//  YaprAskControl.swift
//  YaprControl (Control Center widget extension)
//
//  A single Control Center tile that, when tapped, runs `AskYaprIntent` —
//  setting the App Group "launched from Control Center" flag and opening
//  the Yapr app. The user takes a normal iPhone screenshot first
//  (Side button + Volume Up), pulls down Control Center, and taps this
//  button to ask about it without rummaging through the Home Screen.
//
//  This is a "static" Control Widget: there is no per-user configuration
//  surface, so we use `StaticControlConfiguration`. The system handles the
//  styling — we only provide the icon and label.
//
//  Requires iOS 18.0+. The `ControlWidget` API is unavailable on iOS 17.
//

import AppIntents
import SwiftUI
import WidgetKit

struct YaprAskControl: ControlWidget {
    static let kind: String = "com.tobi.yapr.AskControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: AskYaprIntent()) {
                Label("Ask Yapr", systemImage: "ear.badge.waveform")
            }
        }
        .displayName("Ask Yapr")
        .description("Hold and ask Yapr about your most recent screenshot.")
    }
}
