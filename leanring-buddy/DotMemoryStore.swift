//
//  DotMemoryStore.swift
//  leanring-buddy
//
//  Local file-backed implementation of Anthropic's memory tool
//  (memory_20250818). Claude issues view/create/str_replace/insert/delete/
//  rename commands scoped to a virtual /memories root; we map each to a real
//  file under ~/Library/Application Support/Dot/memories/ and return the
//  plain-text response shape the memory tool spec expects.
//

import Foundation

@MainActor
enum DotMemoryStore {

    struct MemoryToolDispatchResult {
        let toolResultText: String
        let isError: Bool
    }

    /// One entry in the user-facing memory inspector: a single file under
    /// /memories/ with enough metadata to render a clickable / deletable row.
    /// Pinned entries (under /memories/pinned/) are flagged so the UI can
    /// style them differently and the sleep-cycle hygiene job can skip them.
    struct MemoryEntrySummary: Identifiable, Equatable {
        let virtualPath: String
        let displayName: String
        let firstNonEmptyLineText: String
        let isPinnedEntry: Bool
        let modifiedAt: Date

        var id: String { virtualPath }
    }

    /// On-disk root that backs the virtual /memories namespace. Surfaced so
    /// the eventual "Memory" panel UI can show the user where files live.
    /// Settable so unit tests can swap in a temp directory; never reassigned
    /// in production code.
    static var onDiskMemoriesRootURL: URL = computeDefaultProductionMemoriesRootURL()

    private static func computeDefaultProductionMemoriesRootURL() -> URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupportURL
            .appendingPathComponent("Dot", isDirectory: true)
            .appendingPathComponent("memories", isDirectory: true)
    }

    /// Top-level dispatch for one memory tool_use block. Always returns a
    /// result — failures come back as `isError: true` plain-text payloads so
    /// the model can self-correct on the next step.
    static func dispatch(toolInput: [String: Any]) -> MemoryToolDispatchResult {
        ensureMemoriesRootExistsOnDisk()

        guard let commandName = toolInput["command"] as? String else {
            return errorResult("missing required field: command")
        }
        switch commandName {
        case "view":        return runViewCommand(toolInput: toolInput)
        case "create":      return runCreateCommand(toolInput: toolInput)
        case "str_replace": return runStrReplaceCommand(toolInput: toolInput)
        case "insert":      return runInsertCommand(toolInput: toolInput)
        case "delete":      return runDeleteCommand(toolInput: toolInput)
        case "rename":      return runRenameCommand(toolInput: toolInput)
        default:            return errorResult("unknown memory command: \(commandName)")
        }
    }

    // MARK: - Commands

    private static func runViewCommand(toolInput: [String: Any]) -> MemoryToolDispatchResult {
        guard let virtualPath = toolInput["path"] as? String else {
            return errorResult("missing required field: path")
        }
        guard let resolvedURL = resolveVirtualPathToOnDiskURL(virtualPath) else {
            return errorResult("path must be inside /memories and contain no .. segments")
        }
        var isDirectoryFlag: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectoryFlag) else {
            return errorResult("not found: \(virtualPath)")
        }
        if isDirectoryFlag.boolValue {
            return formatDirectoryListing(resolvedDirectoryURL: resolvedURL, virtualPath: virtualPath)
        }
        return formatFileContents(resolvedFileURL: resolvedURL, viewRange: toolInput["view_range"])
    }

    private static func runCreateCommand(toolInput: [String: Any]) -> MemoryToolDispatchResult {
        guard let virtualPath = toolInput["path"] as? String else {
            return errorResult("missing required field: path")
        }
        guard let fileText = toolInput["file_text"] as? String else {
            return errorResult("missing required field: file_text")
        }
        guard let resolvedURL = resolveVirtualPathToOnDiskURL(virtualPath) else {
            return errorResult("path must be inside /memories and contain no .. segments")
        }
        if FileManager.default.fileExists(atPath: resolvedURL.path) {
            return errorResult("already exists: \(virtualPath) — use str_replace or delete + create")
        }
        do {
            try FileManager.default.createDirectory(
                at: resolvedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileText.write(to: resolvedURL, atomically: true, encoding: .utf8)
        } catch {
            return errorResult("write failed: \(error.localizedDescription)")
        }
        return successResult("created \(virtualPath) (\(fileText.utf8.count) bytes)")
    }

    private static func runStrReplaceCommand(toolInput: [String: Any]) -> MemoryToolDispatchResult {
        guard let virtualPath = toolInput["path"] as? String,
              let oldString = toolInput["old_str"] as? String,
              let newString = toolInput["new_str"] as? String else {
            return errorResult("missing required field(s): path, old_str, new_str")
        }
        guard let resolvedURL = resolveVirtualPathToOnDiskURL(virtualPath) else {
            return errorResult("path must be inside /memories and contain no .. segments")
        }
        guard let originalContents = try? String(contentsOf: resolvedURL, encoding: .utf8) else {
            return errorResult("cannot read file: \(virtualPath)")
        }
        let occurrenceCount = originalContents.components(separatedBy: oldString).count - 1
        if occurrenceCount == 0 {
            return errorResult("old_str not found in \(virtualPath)")
        }
        if occurrenceCount > 1 {
            return errorResult("old_str matched \(occurrenceCount) times in \(virtualPath); make it unique")
        }
        let replacedContents = originalContents.replacingOccurrences(of: oldString, with: newString)
        do {
            try replacedContents.write(to: resolvedURL, atomically: true, encoding: .utf8)
        } catch {
            return errorResult("write failed: \(error.localizedDescription)")
        }
        return successResult("replaced 1 occurrence in \(virtualPath)")
    }

    private static func runInsertCommand(toolInput: [String: Any]) -> MemoryToolDispatchResult {
        guard let virtualPath = toolInput["path"] as? String,
              let insertText = toolInput["insert_text"] as? String else {
            return errorResult("missing required field(s): path, insert_text")
        }
        guard let insertLineNumber = decodeIntField(toolInput["insert_line"]) else {
            return errorResult("missing or invalid field: insert_line")
        }
        guard let resolvedURL = resolveVirtualPathToOnDiskURL(virtualPath) else {
            return errorResult("path must be inside /memories and contain no .. segments")
        }
        guard let originalContents = try? String(contentsOf: resolvedURL, encoding: .utf8) else {
            return errorResult("cannot read file: \(virtualPath)")
        }
        var contentLines = originalContents.components(separatedBy: "\n")
        // Anthropic spec: insert_line=0 inserts at top, =N inserts after the Nth line.
        guard insertLineNumber >= 0 && insertLineNumber <= contentLines.count else {
            return errorResult("insert_line \(insertLineNumber) out of range (file has \(contentLines.count) lines)")
        }
        contentLines.insert(insertText, at: insertLineNumber)
        do {
            try contentLines.joined(separator: "\n").write(to: resolvedURL, atomically: true, encoding: .utf8)
        } catch {
            return errorResult("write failed: \(error.localizedDescription)")
        }
        return successResult("inserted at line \(insertLineNumber) in \(virtualPath)")
    }

    private static func runDeleteCommand(toolInput: [String: Any]) -> MemoryToolDispatchResult {
        guard let virtualPath = toolInput["path"] as? String else {
            return errorResult("missing required field: path")
        }
        guard let resolvedURL = resolveVirtualPathToOnDiskURL(virtualPath) else {
            return errorResult("path must be inside /memories and contain no .. segments")
        }
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return errorResult("not found: \(virtualPath)")
        }
        do {
            try FileManager.default.removeItem(at: resolvedURL)
        } catch {
            return errorResult("delete failed: \(error.localizedDescription)")
        }
        return successResult("deleted \(virtualPath)")
    }

    private static func runRenameCommand(toolInput: [String: Any]) -> MemoryToolDispatchResult {
        guard let oldVirtualPath = toolInput["old_path"] as? String,
              let newVirtualPath = toolInput["new_path"] as? String else {
            return errorResult("missing required field(s): old_path, new_path")
        }
        guard let oldResolvedURL = resolveVirtualPathToOnDiskURL(oldVirtualPath),
              let newResolvedURL = resolveVirtualPathToOnDiskURL(newVirtualPath) else {
            return errorResult("paths must be inside /memories and contain no .. segments")
        }
        guard FileManager.default.fileExists(atPath: oldResolvedURL.path) else {
            return errorResult("not found: \(oldVirtualPath)")
        }
        if FileManager.default.fileExists(atPath: newResolvedURL.path) {
            return errorResult("already exists: \(newVirtualPath)")
        }
        do {
            try FileManager.default.createDirectory(
                at: newResolvedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: oldResolvedURL, to: newResolvedURL)
        } catch {
            return errorResult("rename failed: \(error.localizedDescription)")
        }
        return successResult("renamed \(oldVirtualPath) -> \(newVirtualPath)")
    }

    // MARK: - Path resolution

    /// Maps a /memories-rooted virtual path to a real on-disk URL inside
    /// `onDiskMemoriesRootURL`. Returns nil if the path doesn't start with
    /// /memories, contains traversal segments (.., .), or — after
    /// standardization — would escape the root. This is the only place the
    /// virtual-to-real mapping happens; every command must go through it.
    private static func resolveVirtualPathToOnDiskURL(_ rawVirtualPath: String) -> URL? {
        let trimmedRawPath = rawVirtualPath.hasSuffix("/") && rawVirtualPath != "/"
            ? String(rawVirtualPath.dropLast())
            : rawVirtualPath
        guard trimmedRawPath == "/memories" || trimmedRawPath.hasPrefix("/memories/") else {
            return nil
        }
        let relativePath = trimmedRawPath == "/memories"
            ? ""
            : String(trimmedRawPath.dropFirst("/memories/".count))
        let pathSegments = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        for segment in pathSegments {
            if segment == ".." || segment == "." || segment.contains("\0") {
                return nil
            }
        }
        var resolvedURL = onDiskMemoriesRootURL
        for segment in pathSegments {
            resolvedURL = resolvedURL.appendingPathComponent(String(segment))
        }
        // Belt-and-suspenders: standardize and confirm we didn't escape root.
        let standardizedResolvedPath = resolvedURL.standardizedFileURL.path
        let standardizedRootPath = onDiskMemoriesRootURL.standardizedFileURL.path
        guard standardizedResolvedPath == standardizedRootPath
                || standardizedResolvedPath.hasPrefix(standardizedRootPath + "/") else {
            return nil
        }
        return resolvedURL
    }

    private static func ensureMemoriesRootExistsOnDisk() {
        try? FileManager.default.createDirectory(
            at: onDiskMemoriesRootURL,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Inspector / management API (for the panel UI + sleep-cycle job)

    /// Reserved virtual subdirectory whose entries are protected from the
    /// sleep-cycle hygiene job. The model writes here when the user asks
    /// for an explicit "remember this forever" instead of inferring a fact.
    static let pinnedSubdirectoryVirtualPathPrefix = "/memories/pinned/"

    /// Recursively enumerate every file under /memories/. Returned in
    /// stable alphabetical order so the panel UI doesn't reshuffle on
    /// every tick. Hidden files (.DS_Store, etc.) are skipped.
    static func listAllMemoryEntries() -> [MemoryEntrySummary] {
        ensureMemoriesRootExistsOnDisk()
        guard let recursiveEnumerator = FileManager.default.enumerator(
            at: onDiskMemoriesRootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var collectedSummaries: [MemoryEntrySummary] = []
        for case let fileURL as URL in recursiveEnumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard resourceValues?.isRegularFile == true else { continue }
            guard let virtualPath = onDiskURLToVirtualPath(fileURL) else { continue }
            let firstNonEmptyLine = readFirstNonEmptyLine(of: fileURL) ?? "(empty)"
            collectedSummaries.append(MemoryEntrySummary(
                virtualPath: virtualPath,
                displayName: fileURL.lastPathComponent,
                firstNonEmptyLineText: firstNonEmptyLine,
                isPinnedEntry: virtualPath.hasPrefix(pinnedSubdirectoryVirtualPathPrefix),
                modifiedAt: resourceValues?.contentModificationDate ?? Date.distantPast
            ))
        }
        return collectedSummaries.sorted { $0.virtualPath < $1.virtualPath }
    }

    /// Read the raw text of one entry. Returns nil if the path is invalid
    /// or unreadable. Used by the inspector's "view full text" affordance.
    static func readFullTextOfEntry(virtualPath: String) -> String? {
        guard let resolvedURL = resolveVirtualPathToOnDiskURL(virtualPath) else { return nil }
        return try? String(contentsOf: resolvedURL, encoding: .utf8)
    }

    /// Delete one entry by virtual path. Wraps the same path-traversal
    /// validation the model goes through; safe to call from the panel UI
    /// without re-checking. Refuses to delete the /memories root itself
    /// (use `wipeAllMemoriesIncludingPinned` for that) so a toast-undo on
    /// a sentinel-path notification can't accidentally nuke everything.
    /// Returns true on success.
    @discardableResult
    static func deleteEntry(virtualPath: String) -> Bool {
        let normalizedVirtualPath = virtualPath.hasSuffix("/") && virtualPath != "/"
            ? String(virtualPath.dropLast())
            : virtualPath
        guard normalizedVirtualPath != "/memories" else {
            DotDebugLogger.log("memory.tool", "deleteEntry refused root /memories path", metadata: [
                "virtualPath": virtualPath
            ])
            return false
        }
        guard let resolvedURL = resolveVirtualPathToOnDiskURL(virtualPath),
              FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: resolvedURL)
            return true
        } catch {
            DotDebugLogger.log("memory.tool", "deleteEntry failed", metadata: [
                "virtualPath": virtualPath,
                "error": error.localizedDescription
            ])
            return false
        }
    }

    /// Wipe all of /memories/ (including pinned). Wired up to the panel's
    /// "Forget everything" button; user gets a confirmation dialog before
    /// this fires. Returns true on success.
    @discardableResult
    static func wipeAllMemoriesIncludingPinned() -> Bool {
        do {
            if FileManager.default.fileExists(atPath: onDiskMemoriesRootURL.path) {
                try FileManager.default.removeItem(at: onDiskMemoriesRootURL)
            }
            ensureMemoriesRootExistsOnDisk()
            return true
        } catch {
            DotDebugLogger.log("memory.tool", "wipeAllMemoriesIncludingPinned failed", metadata: [
                "error": error.localizedDescription
            ])
            return false
        }
    }

    /// Inverse of `resolveVirtualPathToOnDiskURL` — returns the
    /// /memories-rooted virtual path for a file under the on-disk root, or
    /// nil if the URL is somehow outside the root (defensive — should not
    /// happen since enumerator is rooted at it).
    private static func onDiskURLToVirtualPath(_ onDiskFileURL: URL) -> String? {
        let standardizedFilePath = onDiskFileURL.standardizedFileURL.path
        let standardizedRootPath = onDiskMemoriesRootURL.standardizedFileURL.path
        guard standardizedFilePath.hasPrefix(standardizedRootPath) else { return nil }
        let relativeSuffix = String(standardizedFilePath.dropFirst(standardizedRootPath.count))
        let trimmedSuffix = relativeSuffix.hasPrefix("/") ? String(relativeSuffix.dropFirst()) : relativeSuffix
        return trimmedSuffix.isEmpty ? "/memories" : "/memories/\(trimmedSuffix)"
    }

    private static func readFirstNonEmptyLine(of fileURL: URL) -> String? {
        guard let fileContents = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        for rawLine in fileContents.components(separatedBy: "\n") {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedLine.isEmpty {
                return trimmedLine
            }
        }
        return nil
    }

    // MARK: - View formatting

    private static func formatDirectoryListing(
        resolvedDirectoryURL: URL,
        virtualPath: String
    ) -> MemoryToolDispatchResult {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: resolvedDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return errorResult("cannot read directory: \(virtualPath)")
        }
        if entries.isEmpty {
            return successResult("(empty directory)")
        }
        let sortedEntries = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var listingLines: [String] = []
        for entryURL in sortedEntries {
            let resourceValues = try? entryURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            let isDirectoryEntry = resourceValues?.isDirectory ?? false
            let entrySizeColumn = isDirectoryEntry ? "-" : "\(resourceValues?.fileSize ?? 0)"
            let entryDisplayName = isDirectoryEntry
                ? entryURL.lastPathComponent + "/"
                : entryURL.lastPathComponent
            listingLines.append("\(entrySizeColumn)\t\(entryDisplayName)")
        }
        return successResult(listingLines.joined(separator: "\n"))
    }

    private static func formatFileContents(
        resolvedFileURL: URL,
        viewRange: Any?
    ) -> MemoryToolDispatchResult {
        guard let fileContents = try? String(contentsOf: resolvedFileURL, encoding: .utf8) else {
            return errorResult("cannot read file (or not utf8)")
        }
        let allLines = fileContents.components(separatedBy: "\n")
        var firstLineNumber = 1
        var lastLineNumber = allLines.count
        if let rangeArray = viewRange as? [Any], rangeArray.count == 2 {
            if let parsedFirst = decodeIntField(rangeArray[0]) {
                firstLineNumber = max(1, parsedFirst)
            }
            if let parsedLast = decodeIntField(rangeArray[1]) {
                lastLineNumber = min(allLines.count, parsedLast)
            }
        }
        guard firstLineNumber <= lastLineNumber else {
            return errorResult("invalid view_range")
        }
        var renderedLines: [String] = []
        for lineIndex in firstLineNumber...lastLineNumber {
            let lineNumberColumn = String(format: "%6d", lineIndex)
            renderedLines.append("\(lineNumberColumn)\t\(allLines[lineIndex - 1])")
        }
        return successResult(renderedLines.joined(separator: "\n"))
    }

    // MARK: - Helpers

    private static func decodeIntField(_ rawValue: Any?) -> Int? {
        if let intValue = rawValue as? Int { return intValue }
        if let doubleValue = rawValue as? Double { return Int(doubleValue) }
        if let stringValue = rawValue as? String, let parsed = Int(stringValue) {
            return parsed
        }
        return nil
    }

    private static func successResult(_ message: String) -> MemoryToolDispatchResult {
        return MemoryToolDispatchResult(toolResultText: message, isError: false)
    }

    private static func errorResult(_ message: String) -> MemoryToolDispatchResult {
        return MemoryToolDispatchResult(toolResultText: "error: \(message)", isError: true)
    }
}
