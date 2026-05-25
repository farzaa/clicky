//
//  NicheDiscoveryManager.swift
//  leanring-buddy
//
//  Loads niche suggestion packs and swaps examples based on user niche and frontmost app.
//

import AppKit
import Combine
import Foundation

@MainActor
final class NicheDiscoveryManager: ObservableObject {
    static let selectedUserNicheDefaultsKey = "selectedUserNiche"
    static let hasSelectedUserNicheDefaultsKey = "hasSelectedUserNiche"

    @Published private(set) var currentSuggestions: [String] = []
    @Published private(set) var frontmostApplicationBundleID: String?

    private var simulatedFrontmostBundleIDForE2E: String?
    private var bundledExamples: [String: NicheSuggestionPack] = [:]
    private var bundledAppSuggestions: [String: NicheSuggestionPack] = [:]
    private var workspaceActivationObserver: NSObjectProtocol?

    var selectedUserNiche: UserNiche {
        get {
            guard hasSelectedUserNiche else { return .general }
            let rawValue = UserDefaults.standard.string(forKey: Self.selectedUserNicheDefaultsKey) ?? UserNiche.general.rawValue
            return UserNiche(rawValue: rawValue) ?? .general
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.selectedUserNicheDefaultsKey)
            UserDefaults.standard.set(true, forKey: Self.hasSelectedUserNicheDefaultsKey)
            refreshCurrentSuggestions()
        }
    }

    var hasSelectedUserNiche: Bool {
        UserDefaults.standard.bool(forKey: Self.hasSelectedUserNicheDefaultsKey)
    }

    init() {
        loadBundledExamples()
        startObservingFrontmostApplication()
        refreshCurrentSuggestions()
    }

    deinit {
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
    }

    func selectUserNiche(_ userNiche: UserNiche) {
        selectedUserNiche = userNiche
        ClickyAnalytics.trackNicheSelected(niche: userNiche.rawValue)
        if ClickyE2EConfiguration.isEnabled {
            ClickyE2EConfiguration.writeSelectedNicheForE2E(userNiche.rawValue)
        }
    }

    func skipNicheSelection() {
        selectUserNiche(.general)
    }

    func handleSuggestionTapped(_ suggestion: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(suggestion, forType: .string)
        ClickyAnalytics.trackNicheSuggestionTapped(
            suggestion: suggestion,
            niche: selectedUserNiche.rawValue,
            bundleID: effectiveFrontmostApplicationBundleID
        )
    }

    func setSimulatedFrontmostBundleIDForE2E(_ bundleID: String?) {
        simulatedFrontmostBundleIDForE2E = bundleID
        refreshCurrentSuggestions()
    }

    var effectiveFrontmostApplicationBundleID: String? {
        if let simulatedFrontmostBundleIDForE2E {
            return simulatedFrontmostBundleIDForE2E
        }
        return frontmostApplicationBundleID
    }

    func refreshCurrentSuggestions() {
        let suggestions = resolveSuggestions(
            forNiche: selectedUserNiche,
            bundleID: effectiveFrontmostApplicationBundleID
        )
        currentSuggestions = Array(suggestions.prefix(5))

        if ClickyE2EConfiguration.isEnabled {
            ClickyE2EConfiguration.writeLastSuggestionsForE2E(currentSuggestions)
            ClickyE2EConfiguration.writeSelectedNicheForE2E(selectedUserNiche.rawValue)
        }
    }

    private struct NicheSuggestionPack: Decodable {
        let suggestions: [String]
    }

    private struct BundledNicheExamples: Decodable {
        let general: NicheSuggestionPack?
        let contentCreator: NicheSuggestionPack?
        let developer: NicheSuggestionPack?
        let student: NicheSuggestionPack?
        let designer: NicheSuggestionPack?
        let appSuggestions: [String: NicheSuggestionPack]?
    }

    private func loadBundledExamples() {
        guard let url = Bundle.main.url(forResource: "niche-examples", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(BundledNicheExamples.self, from: data) else {
            bundledExamples = [:]
            bundledAppSuggestions = [:]
            return
        }

        var loadedExamples: [String: NicheSuggestionPack] = [:]
        if let general = decoded.general { loadedExamples[UserNiche.general.jsonKey] = general }
        if let contentCreator = decoded.contentCreator { loadedExamples[UserNiche.contentCreator.jsonKey] = contentCreator }
        if let developer = decoded.developer { loadedExamples[UserNiche.developer.jsonKey] = developer }
        if let student = decoded.student { loadedExamples[UserNiche.student.jsonKey] = student }
        if let designer = decoded.designer { loadedExamples[UserNiche.designer.jsonKey] = designer }
        bundledExamples = loadedExamples
        bundledAppSuggestions = decoded.appSuggestions ?? [:]
    }

    private func resolveSuggestions(forNiche userNiche: UserNiche, bundleID: String?) -> [String] {
        if let bundleID,
           let localAppSuggestions = loadLocalOverrideSuggestions(forNiche: userNiche, bundleID: bundleID),
           !localAppSuggestions.isEmpty {
            return localAppSuggestions
        }

        if let bundleID,
           let appSuggestions = bundledAppSuggestions[bundleID]?.suggestions,
           !appSuggestions.isEmpty {
            return appSuggestions
        }

        if let localNicheSuggestions = loadLocalOverrideSuggestions(forNiche: userNiche, bundleID: nil),
           !localNicheSuggestions.isEmpty {
            return localNicheSuggestions
        }

        return bundledExamples[userNiche.jsonKey]?.suggestions
            ?? bundledExamples[UserNiche.general.jsonKey]?.suggestions
            ?? []
    }

    private func loadLocalOverrideSuggestions(forNiche userNiche: UserNiche, bundleID: String?) -> [String]? {
        let nicheDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clicky/niches/\(userNiche.jsonKey)", isDirectory: true)

        let overrideFileName = bundleID == nil ? "examples.json" : "app-\(bundleID!.replacingOccurrences(of: ".", with: "-")).json"
        let overrideURL = nicheDirectory.appendingPathComponent(overrideFileName)

        guard let data = try? Data(contentsOf: overrideURL),
              let decoded = try? JSONDecoder().decode(NicheSuggestionPack.self, from: data) else {
            if bundleID != nil {
                let fallbackURL = nicheDirectory.appendingPathComponent("examples.json")
                if let data = try? Data(contentsOf: fallbackURL),
                   let decoded = try? JSONDecoder().decode(NicheSuggestionPack.self, from: data) {
                    return decoded.suggestions
                }
            }
            return nil
        }

        return decoded.suggestions
    }

    private func startObservingFrontmostApplication() {
        frontmostApplicationBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.frontmostApplicationBundleID = activatedApplication?.bundleIdentifier
            self.refreshCurrentSuggestions()
        }
    }
}
