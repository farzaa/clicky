//
//  AppUsageCollector.swift
//  leanring-buddy
//
//  Tracks foreground app sessions locally for implicit niche inference.
//

import AppKit
import Foundation

struct AppUsageSession: Codable, Equatable {
    let bundleId: String
    let startedAt: Date
    var endedAt: Date?

    var durationSeconds: TimeInterval {
        guard let endedAt else { return 0 }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}

struct AppUsageStoreFile: Codable {
    var sessions: [AppUsageSession]
}

final class AppUsageCollector {
    static let usageFileURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clicky/app-usage.json")
    }()

    static let rollingWindowDays = 7

    private let usageFileURL: URL
    private var sessions: [AppUsageSession] = []
    private var activeSession: AppUsageSession?
    private var flushTimer: Timer?

    init(usageFileURL: URL = AppUsageCollector.usageFileURL) {
        self.usageFileURL = usageFileURL
    }

    func start() {
        load()
        pruneExpiredSessions()
        beginSession(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        startFlushTimer()
    }

    func stop() {
        flushTimer?.invalidate()
        flushTimer = nil
        endActiveSession(at: Date())
        save()
    }

    func recordFrontmostApplicationChange(to bundleId: String?) {
        endActiveSession(at: Date())
        beginSession(for: bundleId)
        pruneExpiredSessions()
        save()
    }

    func weightedSecondsByBundleId(now: Date = Date()) -> [String: TimeInterval] {
        pruneExpiredSessions(now: now)
        var totals: [String: TimeInterval] = [:]

        for session in sessions {
            let endDate = session.endedAt ?? now
            let duration = max(0, endDate.timeIntervalSince(session.startedAt))
            guard duration > 0 else { continue }
            totals[session.bundleId, default: 0] += duration
        }

        if let activeSession {
            let duration = max(0, now.timeIntervalSince(activeSession.startedAt))
            if duration > 0 {
                totals[activeSession.bundleId, default: 0] += duration
            }
        }

        return totals
    }

    private func beginSession(for bundleId: String?) {
        guard let bundleId, !bundleId.isEmpty else {
            activeSession = nil
            return
        }
        activeSession = AppUsageSession(bundleId: bundleId, startedAt: Date(), endedAt: nil)
    }

    private func endActiveSession(at endDate: Date) {
        guard var activeSession else { return }
        activeSession.endedAt = endDate
        sessions.append(activeSession)
        self.activeSession = nil
    }

    private func pruneExpiredSessions(now: Date = Date()) {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -Self.rollingWindowDays,
            to: now
        ) ?? .distantPast
        sessions.removeAll { session in
            let sessionEnd = session.endedAt ?? now
            return sessionEnd < cutoff
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: usageFileURL.path),
              let data = try? Data(contentsOf: usageFileURL),
              let decoded = try? JSONDecoder().decode(AppUsageStoreFile.self, from: data) else {
            sessions = []
            return
        }
        sessions = decoded.sessions
    }

    private func save() {
        let directory = usageFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = AppUsageStoreFile(sessions: sessions)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: usageFileURL, options: .atomic)
    }

    private func startFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.endActiveSession(at: Date())
            self?.beginSession(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            self?.save()
        }
    }
}
