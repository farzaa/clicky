//
//  ClickyDebugLogger.swift
//  leanring-buddy
//
//  Lightweight file-backed logging for local development diagnostics.
//

import Foundation

enum ClickyDebugLogger {
    private static let logDirectoryURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Clicky Dev", isDirectory: true)
    private static let logFileURL = logDirectoryURL.appendingPathComponent("clicky-dev.log")
    private static let rotatedLogFileURL = logDirectoryURL.appendingPathComponent("clicky-dev.log.1")
    private static let maximumLogFileSizeInBytes: UInt64 = 5 * 1024 * 1024
    private static let writeQueue = DispatchQueue(label: "com.mark.clicky-dev.debug-log")

    static var currentLogFilePath: String {
        logFileURL.path
    }

    static func log(
        _ category: String,
        _ message: String,
        metadata: [String: Any] = [:]
    ) {
        let timestampText = Self.timestampText(for: Date())
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        let metadataText = Self.metadataText(from: metadata)
        let line = "\(timestampText) pid=\(processIdentifier) [\(category)] \(message)\(metadataText)\n"

        print("ClickyDebug [\(category)] \(message)\(metadataText)")

        writeQueue.async {
            writeLineToLogFile(line)
        }
    }

    static func markLaunch() {
        log("app", "launch", metadata: [
            "logFile": currentLogFilePath,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown"
        ])
    }

    private static func writeLineToLogFile(_ line: String) {
        do {
            try FileManager.default.createDirectory(
                at: logDirectoryURL,
                withIntermediateDirectories: true
            )
            try rotateLogFileIfNeeded()

            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
            }

            let fileHandle = try FileHandle(forWritingTo: logFileURL)
            defer {
                try? fileHandle.close()
            }

            try fileHandle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try fileHandle.write(contentsOf: data)
            }
        } catch {
            print("ClickyDebug [logger] failed to write log: \(error.localizedDescription)")
        }
    }

    private static func rotateLogFileIfNeeded() throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let fileSize = attributes[.size] as? UInt64,
              fileSize >= maximumLogFileSizeInBytes else {
            return
        }

        if FileManager.default.fileExists(atPath: rotatedLogFileURL.path) {
            try FileManager.default.removeItem(at: rotatedLogFileURL)
        }
        try FileManager.default.moveItem(at: logFileURL, to: rotatedLogFileURL)
        FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
    }

    private static func timestampText(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
            .withTimeZone
        ]
        return formatter.string(from: date)
    }

    private static func metadataText(from metadata: [String: Any]) -> String {
        guard !metadata.isEmpty else { return "" }

        let pairs = metadata
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key)=\(sanitizeMetadataValue(value))"
            }

        return " " + pairs.joined(separator: " ")
    }

    private static func sanitizeMetadataValue(_ value: Any) -> String {
        String(describing: value)
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
