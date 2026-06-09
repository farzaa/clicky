//
//  YaprControlBundle.swift
//  YaprControl (Control Center widget extension)
//
//  The extension's `@main` entry point. iOS instantiates this bundle in a
//  separate process, asks it for the list of `ControlWidget`s it offers,
//  and renders the corresponding tile inside Control Center.
//
//  We expose a single tile, `YaprAskControl`, that opens the Yapr app via
//  `AskYaprIntent` (defined in `Yapr/Shared/AskYaprIntent.swift`, compiled
//  into both this extension and the main app target).
//

import SwiftUI
import WidgetKit

@main
struct YaprControlBundle: WidgetBundle {
    var body: some Widget {
        YaprAskControl()
    }
}
