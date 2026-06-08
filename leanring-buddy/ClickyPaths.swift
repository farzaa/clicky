//
//  ClickyPaths.swift
//  leanring-buddy
//
//  Centralizes Clicky data home, launch arguments, and isolated UserDefaults.
//  Enables parallel worktree testing via CLICKY_HOME / -CLICKY_HOME=.
//

import Foundation

enum ClickyLaunchArguments {
    static func value(forPrefix prefix: String) -> String? {
        ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    static func isPresent(_ flag: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }
}

enum ClickyPaths {
    /// Test-only override. Production never sets this.
    static var overrideHomeForTesting: URL?

    static var home: URL {
        if let overrideHomeForTesting {
            return overrideHomeForTesting
        }
        if let argumentPath = ClickyLaunchArguments.value(forPrefix: "-CLICKY_HOME=") {
            return URL(fileURLWithPath: argumentPath, isDirectory: true)
        }
        if let environmentPath = ProcessInfo.processInfo.environment["CLICKY_HOME"],
           !environmentPath.isEmpty {
            return URL(fileURLWithPath: environmentPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clicky", isDirectory: true)
    }

    static var skills: URL {
        home.appendingPathComponent("skills", isDirectory: true)
    }

    static var topicHistory: URL {
        home.appendingPathComponent("topic-history.json")
    }
}

enum ClickyDefaults {
    static let shared: UserDefaults = {
        if let suiteName = ClickyLaunchArguments.value(forPrefix: "-CLICKY_DEFAULTS_SUITE="),
           let suiteDefaults = UserDefaults(suiteName: suiteName) {
            return suiteDefaults
        }
        return .standard
    }()
}
