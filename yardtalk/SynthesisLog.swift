//
//  SynthesisLog.swift
//  yardtalk
//
//  Append-only JSONL log of every synthesis attempt — successes,
//  failures, and the raw Claude tool_use payload that came back. Lives
//  at:
//
//    ~/Library/Application Support/YardTalk/synthesis-log.jsonl
//
//  Purpose is product-improvement, not user-facing: when prompts feel
//  off or a template returns junk, this is the corpus you grep over
//  to see WHAT the model actually did across many runs. The app never
//  reads this back.
//
//  Rotation: at app launch, if the file is over `rotationThresholdBytes`
//  we keep only the last `keepLastEntries` lines and rewrite. Line
//  count rather than byte cap so history depth stays predictable
//  (entries vary in size by 5-10x depending on tool-input length).
//  Per-write checks would burn time in the synthesis hot path; once
//  per process is plenty.
//
//  `anomalies` captures the same conditions the permissive parser
//  silently recovered from — `null` arrays, mixed-type arrays,
//  missing summary, wrong-type fields. Pre-aggregated so you can
//  `jq -c '.outcome.anomalies' synthesis-log.jsonl | sort | uniq -c`
//  to see which prompts misbehave most often without parsing every
//  raw payload.
//

import Foundation
import OSLog

struct SynthesisLogEntry: Codable {
    let timestamp: Date
    let sessionID: UUID
    let projectName: String
    let projectType: String
    let templateID: String
    let clipCount: Int
    let nonEmptyTranscriptCount: Int
    let totalNarrationCharCount: Int
    let markerCount: Int
    let sessionDurationSeconds: TimeInterval
    let claudeCallDurationSeconds: TimeInterval?
    let outcome: Outcome

    struct Outcome: Codable {
        /// "success" or "error". Flat string instead of an associated-
        /// value enum so JSONL stays trivially `jq`-friendly.
        let kind: String
        /// Raw Claude tool_use input, JSON-serialized, present on
        /// success. The corpus you actually want to read.
        let toolInputJSON: String?
        /// Pre-computed parse anomalies — ["blockers: missing-or-null",
        /// "next_steps: mixed-types(1 non-string of 4)"], etc.
        let anomalies: [String]?
        /// Localized error message, present on failure.
        let errorMessage: String?
    }
}

@MainActor
final class SynthesisLog {
    static let shared = SynthesisLog()

    /// Rotate when the file crosses this. 5MB ~= 1000+ entries.
    private let rotationThresholdBytes: Int = 5 * 1024 * 1024
    /// Number of most-recent lines retained after rotation.
    private let keepLastEntries: Int = 500

    private let logFileURL: URL = {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("YardTalk", isDirectory: true)
            .appendingPathComponent("synthesis-log.jsonl")
    }()

    private let writeQueue = DispatchQueue(label: "com.yardtalk.synthlog", qos: .utility)

    private init() {
        rotateIfNeeded()
    }

    /// Read once at construction. If the file is over the byte cap,
    /// rewrite it with only the most recent `keepLastEntries` lines.
    /// Failures here are silent — a stale-but-large log is better
    /// than crashing on launch over a logging cleanup.
    ///
    /// The on-disk file is encrypted whole-file via `EncryptedStore`,
    /// so the byte-cap check is against ciphertext size. ChaChaPoly
    /// adds 16 bytes of tag + 12 bytes of nonce + 4 magic — call it
    /// 32 bytes overhead — so the threshold is effectively unchanged.
    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size > rotationThresholdBytes else {
            return
        }

        guard let plaintext = try? EncryptedStore.read(from: logFileURL),
              let content = String(data: plaintext, encoding: .utf8) else {
            return
        }

        // `split` with omittingEmptySubsequences: false preserves the
        // trailing empty after the final "\n", so we can drop it
        // explicitly and rejoin without doubling newlines.
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }

        guard lines.count > keepLastEntries else { return }

        let kept = lines.suffix(keepLastEntries)
        let rewritten = kept.joined(separator: "\n") + "\n"
        guard let rewrittenData = rewritten.data(using: .utf8) else { return }
        do {
            try EncryptedStore.write(rewrittenData, to: logFileURL)
            Logger.synthesis.info("SynthesisLog rotated: kept \(self.keepLastEntries, privacy: .public) of \(lines.count, privacy: .public) lines")
        } catch {
            Logger.synthesis.error("SynthesisLog rotation failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func appendSuccess(
        context: SessionContext,
        template: NUPayloadTemplate,
        toolInput: [String: Any],
        claudeDurationSeconds: TimeInterval
    ) {
        let toolInputJSON: String = {
            guard let data = try? JSONSerialization.data(
                withJSONObject: toolInput,
                options: [.sortedKeys]
            ) else { return "{}" }
            return String(data: data, encoding: .utf8) ?? "{}"
        }()
        let anomalies = Self.detectAnomalies(toolInput: toolInput)
        let entry = SynthesisLogEntry(
            timestamp: Date(),
            sessionID: context.session.id,
            projectName: context.project.name,
            projectType: context.project.type.rawValue,
            templateID: template.id,
            clipCount: context.clips.count,
            nonEmptyTranscriptCount: context.clips.filter { ($0.transcript?.isEmpty == false) }.count,
            totalNarrationCharCount: context.clips.compactMap { $0.transcript }.reduce(0) { $0 + $1.count },
            markerCount: context.clips.reduce(0) { $0 + $1.markers.count },
            sessionDurationSeconds: (context.session.endedAt ?? Date()).timeIntervalSince(context.session.startedAt),
            claudeCallDurationSeconds: claudeDurationSeconds,
            outcome: .init(
                kind: "success",
                toolInputJSON: toolInputJSON,
                anomalies: anomalies,
                errorMessage: nil
            )
        )
        write(entry)
    }

    func appendError(
        context: SessionContext,
        template: NUPayloadTemplate,
        error: Error
    ) {
        let entry = SynthesisLogEntry(
            timestamp: Date(),
            sessionID: context.session.id,
            projectName: context.project.name,
            projectType: context.project.type.rawValue,
            templateID: template.id,
            clipCount: context.clips.count,
            nonEmptyTranscriptCount: context.clips.filter { ($0.transcript?.isEmpty == false) }.count,
            totalNarrationCharCount: context.clips.compactMap { $0.transcript }.reduce(0) { $0 + $1.count },
            markerCount: context.clips.reduce(0) { $0 + $1.markers.count },
            sessionDurationSeconds: (context.session.endedAt ?? Date()).timeIntervalSince(context.session.startedAt),
            claudeCallDurationSeconds: nil,
            outcome: .init(
                kind: "error",
                toolInputJSON: nil,
                anomalies: nil,
                errorMessage: error.localizedDescription
            )
        )
        write(entry)
    }

    private static func detectAnomalies(toolInput: [String: Any]) -> [String] {
        var anomalies: [String] = []

        let summary = toolInput["summary"]
        if summary == nil {
            anomalies.append("summary: missing")
        } else if summary is NSNull {
            anomalies.append("summary: null")
        } else if let s = summary as? String, s.isEmpty {
            anomalies.append("summary: empty-string")
        } else if !(summary is String) {
            anomalies.append("summary: wrong-type")
        }

        for field in ["accomplishments", "blockers", "next_steps"] {
            let value = toolInput[field]
            if value == nil {
                anomalies.append("\(field): missing")
            } else if value is NSNull {
                anomalies.append("\(field): null")
            } else if let array = value as? [Any] {
                let nonStrings = array.filter { !($0 is String) }
                if !nonStrings.isEmpty {
                    anomalies.append("\(field): mixed-types(\(nonStrings.count) non-string of \(array.count))")
                }
            } else {
                anomalies.append("\(field): wrong-type")
            }
        }

        return anomalies
    }

    private func write(_ entry: SynthesisLogEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entry) else { return }
        let line = data + Data("\n".utf8)
        let url = logFileURL
        // Whole-file AEAD doesn't support byte-range appends, so each
        // write reads, decrypts, appends, and rewrites encrypted. The
        // rotation cap (5MB / ~1000 entries) keeps the work bounded;
        // serial dispatch on writeQueue keeps concurrent appends from
        // racing the read-modify-write cycle.
        writeQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                var combined: Data
                if FileManager.default.fileExists(atPath: url.path) {
                    combined = (try? EncryptedStore.read(from: url)) ?? Data()
                } else {
                    combined = Data()
                }
                combined.append(line)
                try EncryptedStore.write(combined, to: url)
            } catch {
                Logger.synthesis.error("SynthesisLog write failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}
