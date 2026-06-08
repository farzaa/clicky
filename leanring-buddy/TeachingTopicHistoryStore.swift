//
//  TeachingTopicHistoryStore.swift
//  leanring-buddy
//
//  Persists lightweight teaching topic history under ~/.clicky/topic-history.json.
//

import Foundation

struct TeachingTopicHistoryEntry: Codable, Equatable {
    let topicTokens: [String]
    let bundleId: String?
    let timestamp: Date
    var skillId: String?
}

final class TeachingTopicHistoryStore {
    static var historyFileURL: URL {
        ClickyPaths.topicHistory
    }

    private(set) var entries: [TeachingTopicHistoryEntry] = []
    private let maxEntryCount = 200
    private let historyFileURL: URL

    init(historyFileURL: URL = TeachingTopicHistoryStore.historyFileURL) {
        self.historyFileURL = historyFileURL
    }

    func load() {
        guard FileManager.default.fileExists(atPath: historyFileURL.path),
              let data = try? Data(contentsOf: historyFileURL),
              let decoded = try? JSONDecoder().decode([TeachingTopicHistoryEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    func save() {
        let directory = historyFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: historyFileURL, options: .atomic)
    }

    func recordTopic(topic: String, bundleId: String?, skillId: String? = nil) {
        let topicTokens = SkillMatcher.meaningfulTokens(topic)
        guard !topicTokens.isEmpty else { return }

        entries.append(
            TeachingTopicHistoryEntry(
                topicTokens: topicTokens,
                bundleId: bundleId,
                timestamp: Date(),
                skillId: skillId
            )
        )

        if entries.count > maxEntryCount {
            entries.removeFirst(entries.count - maxEntryCount)
        }
        save()
    }

    func hasRepeatedTopic(
        topic: String,
        bundleId: String?,
        withinDays: Int = 7,
        now: Date = Date()
    ) -> Bool {
        Self.hasRepeatedTopic(
            topic: topic,
            bundleId: bundleId,
            withinDays: withinDays,
            in: entries,
            now: now
        )
    }

    static func hasRepeatedTopic(
        topic: String,
        bundleId: String?,
        withinDays: Int = 7,
        in entries: [TeachingTopicHistoryEntry],
        now: Date = Date()
    ) -> Bool {
        let topicTokens = Set(SkillMatcher.meaningfulTokens(topic))
        guard topicTokens.count >= 1 else { return false }

        let cutoff = Calendar.current.date(byAdding: .day, value: -withinDays, to: now) ?? .distantPast
        let matchingEntries = entries.filter { entry in
            entry.timestamp >= cutoff &&
            bundleIdsMatch(entry.bundleId, bundleId) &&
            tokenOverlapCount(Set(entry.topicTokens), topicTokens) >= 2
        }

        return matchingEntries.count >= 2
    }

    private static func bundleIdsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let left?, let right?):
            return left == right
        case (nil, _), (_, nil):
            return true
        }
    }

    private static func tokenOverlapCount(_ lhs: Set<String>, _ rhs: Set<String>) -> Int {
        lhs.intersection(rhs).count
    }
}
