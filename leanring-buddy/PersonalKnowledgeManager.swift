//
//  PersonalKnowledgeManager.swift
//  leanring-buddy
//
//  Connects to user vault folders, persists security-scoped bookmarks,
//  and searches markdown notes on demand.
//

import Foundation

struct PersonalKnowledgeChunk: Equatable {
    let sourcePath: String
    let sourceLabel: String
    let excerpt: String
    let score: Int
}

struct ConnectedVault: Codable, Equatable, Identifiable {
    let id: UUID
    var label: String
    var path: String
    var connectedAt: Date
    var bookmarkData: Data?

    var folderURL: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}

private struct ConnectedVaultsFile: Codable {
    var vaults: [ConnectedVault]
}

final class PersonalKnowledgeManager {
    static let defaultBrainRootURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clicky/brain", isDirectory: true)
    }()

    static var brainRootURL: URL {
        defaultBrainRootURL
    }

    static var sourcesFileURL: URL {
        defaultBrainRootURL.appendingPathComponent("sources.json")
    }

    private static let excludedPathComponents: Set<String> = [
        ".git",
        ".obsidian",
        "node_modules",
        ".trash",
        "Trash"
    ]

    private static let searchStopWords: Set<String> = [
        "tell", "what", "whats", "when", "where", "which", "about", "from", "that", "this",
        "have", "with", "your", "mine", "the", "and", "for", "are", "was", "were", "can",
        "you", "how", "does", "did", "will", "would", "should", "could", "ask", "show",
        "give", "read", "look", "into", "note", "notes", "vault", "obsidian", "clicky"
    ]

    private static let maxMarkdownFilesToScan = 120
    private static let maxMarkdownFileBytesToRead = 65_536
    private static let maxVaultOverviewNotes = 12

    private let brainRootURL: URL
    private let sourcesFileURL: URL

    private(set) var connectedVaults: [ConnectedVault] = []

    private let excludedFileNamePatterns: [String] = [
        ".env",
        "id_rsa",
        ".pem"
    ]

    init(brainRootURL: URL? = nil) {
        self.brainRootURL = brainRootURL ?? Self.defaultBrainRootURL
        self.sourcesFileURL = self.brainRootURL.appendingPathComponent("sources.json")
        loadConnectedVaults()
    }

    var hasConnectedVault: Bool {
        !connectedVaults.isEmpty
    }

    func loadConnectedVaults() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: brainRootURL, withIntermediateDirectories: true)

        guard let data = try? Data(contentsOf: sourcesFileURL) else {
            connectedVaults = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let sourcesFile = try? decoder.decode(ConnectedVaultsFile.self, from: data) else {
            connectedVaults = []
            return
        }

        connectedVaults = sourcesFile.vaults.filter { vault in
            fileManager.fileExists(atPath: vault.path)
        }
    }

    @discardableResult
    func connectVault(at folderURL: URL, label: String? = nil) throws -> ConnectedVault {
        guard FileManager.default.fileExists(atPath: folderURL.path),
              (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw PersonalKnowledgeError.invalidVaultFolder
        }

        let standardizedPath = (folderURL.path as NSString).standardizingPath
        if connectedVaults.contains(where: { ($0.path as NSString).standardizingPath == standardizedPath }) {
            throw PersonalKnowledgeError.vaultAlreadyConnected
        }

        let resolvedLabel = label ?? folderURL.lastPathComponent

        _ = folderURL.startAccessingSecurityScopedResource()
        let bookmarkData = try folderURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        guard FileManager.default.isReadableFile(atPath: standardizedPath) else {
            throw PersonalKnowledgeError.vaultFolderNotReadable
        }

        let connectedVault = ConnectedVault(
            id: UUID(),
            label: resolvedLabel,
            path: standardizedPath,
            connectedAt: Date(),
            bookmarkData: bookmarkData
        )

        connectedVaults.append(connectedVault)
        try saveConnectedVaults()
        return connectedVault
    }

    func disconnectVault(id: UUID) throws {
        connectedVaults.removeAll { $0.id == id }
        try saveConnectedVaults()
    }

    func disconnectAllVaults() throws {
        connectedVaults = []
        try saveConnectedVaults()
    }

    func countSearchableMarkdownFiles() -> Int {
        var markdownFileCount = 0

        for vault in connectedVaults {
            markdownFileCount += countMarkdownFiles(in: vault.folderURL)
        }

        markdownFileCount += countBrainMarkdownFiles()
        return markdownFileCount
    }

    /// Runs vault search off the main thread so large Obsidian vaults cannot freeze the UI.
    func search(query: String, maxChunks: Int = 4) async -> [PersonalKnowledgeChunk] {
        let connectedVaultsSnapshot = connectedVaults
        let brainRootURLSnapshot = brainRootURL

        return await Task.detached(priority: .userInitiated) {
            Self.searchVaultContents(
                query: query,
                connectedVaults: connectedVaultsSnapshot,
                brainRootURL: brainRootURLSnapshot,
                maxChunks: maxChunks
            )
        }.value
    }

    private static func searchVaultContents(
        query: String,
        connectedVaults: [ConnectedVault],
        brainRootURL: URL,
        maxChunks: Int
    ) -> [PersonalKnowledgeChunk] {
        if isVaultOverviewQuery(query) {
            return buildVaultOverviewChunks(
                connectedVaults: connectedVaults,
                brainRootURL: brainRootURL,
                maxChunks: maxChunks
            )
        }

        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        var scoredChunks: [PersonalKnowledgeChunk] = []

        for vault in connectedVaults {
            guard let resolvedURL = resolveVaultURL(for: vault) else { continue }
            let vaultChunks = searchMarkdownFiles(
                in: resolvedURL,
                vaultLabel: vault.label,
                queryTokens: queryTokens
            )
            scoredChunks.append(contentsOf: vaultChunks)
        }

        scoredChunks.append(contentsOf: searchBrainMarkdownFiles(
            brainRootURL: brainRootURL,
            queryTokens: queryTokens
        ))

        return scoredChunks
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.sourceLabel.localizedCaseInsensitiveCompare(rhs.sourceLabel) == .orderedAscending
            }
            .prefix(maxChunks)
            .map { $0 }
    }

    private static func isVaultOverviewQuery(_ query: String) -> Bool {
        let normalizedQuery = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let overviewPhrases = [
            "what's in my vault",
            "whats in my vault",
            "what is in my vault",
            "tell me what's in my vault",
            "tell me whats in my vault",
            "show me what's in my vault",
            "show me whats in my vault",
            "what do i have in my vault",
            "what do i have in my notes"
        ]

        return overviewPhrases.contains(where: { normalizedQuery.contains($0) })
    }

    private static func buildVaultOverviewChunks(
        connectedVaults: [ConnectedVault],
        brainRootURL: URL,
        maxChunks: Int
    ) -> [PersonalKnowledgeChunk] {
        var overviewChunks: [PersonalKnowledgeChunk] = []

        for vault in connectedVaults {
            guard let resolvedURL = resolveVaultURL(for: vault) else { continue }

            let markdownFileURLs = collectMarkdownFileURLs(in: resolvedURL)
                .sorted { lhs, rhs in
                    let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhsDate > rhsDate
                }

            let recentMarkdownFileURLs = markdownFileURLs.prefix(maxVaultOverviewNotes)

            for fileURL in recentMarkdownFileURLs {
                let relativePath = relativePath(from: resolvedURL, to: fileURL)
                let sourceLabel = "\(vault.label)/\(relativePath)"
                overviewChunks.append(
                    PersonalKnowledgeChunk(
                        sourcePath: fileURL.path,
                        sourceLabel: sourceLabel,
                        excerpt: "recent note: \(relativePath)",
                        score: 1
                    )
                )
            }
        }

        return Array(overviewChunks.prefix(maxChunks))
    }

    private func saveConnectedVaults() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: brainRootURL, withIntermediateDirectories: true)

        let sourcesFile = ConnectedVaultsFile(vaults: connectedVaults)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sourcesFile)
        try data.write(to: sourcesFileURL, options: .atomic)
    }

    private static func resolveVaultURL(for vault: ConnectedVault) -> URL? {
        if let bookmarkData = vault.bookmarkData {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                _ = resolvedURL.startAccessingSecurityScopedResource()
                return resolvedURL
            }
        }

        let folderURL = vault.folderURL
        guard FileManager.default.isReadableFile(atPath: folderURL.path) else { return nil }
        return folderURL
    }

    private static func searchBrainMarkdownFiles(
        brainRootURL: URL,
        queryTokens: [String]
    ) -> [PersonalKnowledgeChunk] {
        let brainFileNames = ["USER.md", "MEMORY.md"]
        var chunks: [PersonalKnowledgeChunk] = []

        for fileName in brainFileNames {
            let fileURL = brainRootURL.appendingPathComponent(fileName)
            guard let chunk = scoreMarkdownFile(
                at: fileURL,
                sourceLabel: "brain/\(fileName)",
                queryTokens: queryTokens
            ) else {
                continue
            }
            chunks.append(chunk)
        }

        return chunks
    }

    private static func searchMarkdownFiles(
        in rootURL: URL,
        vaultLabel: String,
        queryTokens: [String]
    ) -> [PersonalKnowledgeChunk] {
        let markdownFileURLs = collectMarkdownFileURLs(in: rootURL)
        var scoredChunks: [PersonalKnowledgeChunk] = []

        for fileURL in markdownFileURLs {
            let relativePath = relativePath(from: rootURL, to: fileURL)

            var filenameScore = 0
            let lowercasedRelativePath = relativePath.lowercased()
            for token in queryTokens where lowercasedRelativePath.contains(token) {
                filenameScore += 1
            }

            guard let chunk = scoreMarkdownFile(
                at: fileURL,
                sourceLabel: "\(vaultLabel)/\(relativePath)",
                queryTokens: queryTokens,
                filenameScore: filenameScore
            ) else {
                continue
            }

            scoredChunks.append(chunk)

            if scoredChunks.count >= maxMarkdownFilesToScan {
                break
            }
        }

        return scoredChunks
    }

    private static func scoreMarkdownFile(
        at fileURL: URL,
        sourceLabel: String,
        queryTokens: [String],
        filenameScore: Int = 0
    ) -> PersonalKnowledgeChunk? {
        guard let fileContents = readLimitedFileContents(at: fileURL) else {
            return filenameScore > 0
                ? PersonalKnowledgeChunk(
                    sourcePath: fileURL.path,
                    sourceLabel: sourceLabel,
                    excerpt: "(matched filename: \(fileURL.lastPathComponent))",
                    score: filenameScore
                )
                : nil
        }

        let normalizedContents = fileContents.lowercased()
        var score = filenameScore

        for token in queryTokens where normalizedContents.contains(token) {
            score += 1
        }

        guard score > 0 else { return nil }

        return PersonalKnowledgeChunk(
            sourcePath: fileURL.path,
            sourceLabel: sourceLabel,
            excerpt: excerpt(from: fileContents, matchingTokens: queryTokens),
            score: score
        )
    }

    private static func readLimitedFileContents(at fileURL: URL) -> String? {
        guard let fileData = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            return nil
        }

        let limitedData = fileData.prefix(maxMarkdownFileBytesToRead)
        return String(data: limitedData, encoding: .utf8)
    }

    private static func readLimitedFilePreview(at fileURL: URL, maxLength: Int) -> String {
        guard let fileContents = readLimitedFileContents(at: fileURL) else { return "" }
        return String(fileContents.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func excerpt(from fileContents: String, matchingTokens: [String], maxLength: Int = 800) -> String {
        let trimmedContents = fileContents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContents.isEmpty else { return "" }

        let lowercasedContents = trimmedContents.lowercased()
        if let firstMatchingToken = matchingTokens.first(where: { lowercasedContents.contains($0) }),
           let range = lowercasedContents.range(of: firstMatchingToken) {
            let matchStartIndex = trimmedContents.index(
                trimmedContents.startIndex,
                offsetBy: lowercasedContents.distance(from: lowercasedContents.startIndex, to: range.lowerBound)
            )
            let excerptStartIndex = trimmedContents.index(
                matchStartIndex,
                offsetBy: -120,
                limitedBy: trimmedContents.startIndex
            ) ?? trimmedContents.startIndex
            let excerptEndIndex = trimmedContents.index(
                excerptStartIndex,
                offsetBy: maxLength,
                limitedBy: trimmedContents.endIndex
            ) ?? trimmedContents.endIndex
            return String(trimmedContents[excerptStartIndex..<excerptEndIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(trimmedContents.prefix(maxLength))
    }

    private func countMarkdownFiles(in rootURL: URL) -> Int {
        Self.collectMarkdownFileURLs(in: rootURL).count
    }

    private static func collectMarkdownFileURLs(in rootURL: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var markdownFileURLs: [URL] = []

        for case let fileURL as URL in enumerator {
            if shouldSkipURL(fileURL) {
                enumerator.skipDescendants()
                continue
            }

            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }

            guard fileURL.pathExtension.lowercased() == "md" else { continue }
            markdownFileURLs.append(fileURL)

            if markdownFileURLs.count >= maxMarkdownFilesToScan {
                break
            }
        }

        return markdownFileURLs
    }

    private func countBrainMarkdownFiles() -> Int {
        let brainFileNames = ["USER.md", "MEMORY.md"]
        return brainFileNames.filter { fileName in
            FileManager.default.fileExists(atPath: brainRootURL.appendingPathComponent(fileName).path)
        }.count
    }

    private static func shouldSkipURL(_ fileURL: URL) -> Bool {
        let pathComponents = fileURL.pathComponents
        if pathComponents.contains(where: { excludedPathComponents.contains($0) }) {
            return true
        }

        let fileName = fileURL.lastPathComponent.lowercased()
        return fileName.contains(".env")
            || fileName.contains("id_rsa")
            || fileName.contains(".pem")
    }

    private static func relativePath(from rootURL: URL, to fileURL: URL) -> String {
        let rootPath = (rootURL.path as NSString).standardizingPath
        let filePath = (fileURL.path as NSString).standardizingPath

        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }

        return fileURL.lastPathComponent
    }

    private static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
            .filter { !searchStopWords.contains($0) }
    }

    struct VaultWriteResult: Equatable {
        let relativePath: String
        let vaultLabel: String

        var summary: String {
            "\(vaultLabel)/\(relativePath)"
        }
    }

    func executeWrite(_ writeRequest: VaultWriteRequest, vaultID: UUID? = nil) async throws -> VaultWriteResult {
        let connectedVaultsSnapshot = connectedVaults
        let brainRootURLSnapshot = brainRootURL

        return try await Task.detached(priority: .userInitiated) {
            try Self.performWrite(
                writeRequest: writeRequest,
                connectedVaults: connectedVaultsSnapshot,
                brainRootURL: brainRootURLSnapshot,
                preferredVaultID: vaultID
            )
        }.value
    }

    private static func performWrite(
        writeRequest: VaultWriteRequest,
        connectedVaults: [ConnectedVault],
        brainRootURL: URL,
        preferredVaultID: UUID?
    ) throws -> VaultWriteResult {
        switch writeRequest.destination {
        case .appendMemory(let noteContent):
            let memoryFileURL = brainRootURL.appendingPathComponent("MEMORY.md")
            try appendText(noteContent, to: memoryFileURL, createIfNeeded: true)
            return VaultWriteResult(relativePath: "MEMORY.md", vaultLabel: "Clicky brain")

        case .appendDailyNote(let noteContent):
            guard let connectedVault = resolveConnectedVault(
                connectedVaults: connectedVaults,
                preferredVaultID: preferredVaultID
            ) else {
                throw PersonalKnowledgeError.noConnectedVault
            }

            guard let vaultRootURL = resolveVaultURL(for: connectedVault) else {
                throw PersonalKnowledgeError.vaultFolderNotReadable
            }

            let dailyNoteRelativePath = dailyNoteRelativePath(for: Date())
            let dailyNoteURL = vaultRootURL.appendingPathComponent(dailyNoteRelativePath)
            try ensureParentDirectoryExists(for: dailyNoteURL)
            try appendText(noteContent, to: dailyNoteURL, createIfNeeded: true)
            return VaultWriteResult(relativePath: dailyNoteRelativePath, vaultLabel: connectedVault.label)

        case .newNote(let noteTitle, let noteContent):
            guard let connectedVault = resolveConnectedVault(
                connectedVaults: connectedVaults,
                preferredVaultID: preferredVaultID
            ) else {
                throw PersonalKnowledgeError.noConnectedVault
            }

            guard let vaultRootURL = resolveVaultURL(for: connectedVault) else {
                throw PersonalKnowledgeError.vaultFolderNotReadable
            }

            let noteRelativePath = newNoteRelativePath(noteTitle: noteTitle, vaultRootURL: vaultRootURL)
            let noteURL = vaultRootURL.appendingPathComponent(noteRelativePath)
            try ensureParentDirectoryExists(for: noteURL)
            let noteBody = formattedNewNoteBody(from: noteContent)
            try noteBody.write(to: noteURL, atomically: true, encoding: .utf8)
            return VaultWriteResult(relativePath: noteRelativePath, vaultLabel: connectedVault.label)
        }
    }

    private static func resolveConnectedVault(
        connectedVaults: [ConnectedVault],
        preferredVaultID: UUID?
    ) -> ConnectedVault? {
        if let preferredVaultID,
           let preferredVault = connectedVaults.first(where: { $0.id == preferredVaultID }) {
            return preferredVault
        }

        return connectedVaults.first
    }

    private static func dailyNoteRelativePath(for date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let formattedDate = dateFormatter.string(from: date)
        return "Daily Notes/\(formattedDate).md"
    }

    private static func newNoteRelativePath(noteTitle: String, vaultRootURL: URL) -> String {
        let sanitizedFileName = sanitizeFileName(noteTitle)
        let clickyFolderRelativePath = "Clicky/\(sanitizedFileName).md"
        let clickyFolderURL = vaultRootURL.appendingPathComponent("Clicky", isDirectory: true)

        if FileManager.default.fileExists(atPath: clickyFolderURL.path) {
            return clickyFolderRelativePath
        }

        return "\(sanitizedFileName).md"
    }

    private static func sanitizeFileName(_ rawTitle: String) -> String {
        let trimmedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let sanitizedScalars = trimmedTitle.unicodeScalars.map { scalar -> Character in
            allowedCharacters.contains(scalar) ? Character(scalar) : "-"
        }

        let sanitizedTitle = String(sanitizedScalars)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return sanitizedTitle.isEmpty ? "untitled-note" : sanitizedTitle
    }

    private static func formattedNewNoteBody(from noteContent: String) -> String {
        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let savedAtLine = "Saved by Clicky · \(timestampFormatter.string(from: Date()))"
        let trimmedNoteContent = noteContent.trimmingCharacters(in: .whitespacesAndNewlines)

        return "\(savedAtLine)\n\n\(trimmedNoteContent)"
    }

    private static func formattedAppendBlock(from noteContent: String) -> String {
        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let savedAtLine = "Saved by Clicky · \(timestampFormatter.string(from: Date()))"
        let trimmedNoteContent = noteContent.trimmingCharacters(in: .whitespacesAndNewlines)

        return "\n\n---\n\n\(savedAtLine)\n\n\(trimmedNoteContent)"
    }

    private static func appendText(_ noteContent: String, to fileURL: URL, createIfNeeded: Bool) throws {
        let appendBlock = formattedAppendBlock(from: noteContent)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            defer { try? fileHandle.close() }
            try fileHandle.seekToEnd()
            if let appendData = appendBlock.data(using: .utf8) {
                try fileHandle.write(contentsOf: appendData)
            }
            return
        }

        guard createIfNeeded else {
            throw PersonalKnowledgeError.vaultWriteTargetMissing
        }

        try ensureParentDirectoryExists(for: fileURL)
        try appendBlock.trimmingCharacters(in: .whitespacesAndNewlines)
            .appending("\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func ensureParentDirectoryExists(for fileURL: URL) throws {
        let parentDirectoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectoryURL, withIntermediateDirectories: true)
    }
}

enum PersonalKnowledgeError: LocalizedError {
    case invalidVaultFolder
    case vaultAlreadyConnected
    case vaultFolderNotReadable
    case noConnectedVault
    case invalidVaultWriteRequest
    case vaultWriteTargetMissing

    var errorDescription: String? {
        switch self {
        case .invalidVaultFolder:
            return "That folder does not exist or is not a valid vault folder."
        case .vaultAlreadyConnected:
            return "That vault is already connected."
        case .vaultFolderNotReadable:
            return "Clicky cannot read that folder. Choose it again in the folder picker to grant access."
        case .noConnectedVault:
            return "Connect a vault before saving notes."
        case .invalidVaultWriteRequest:
            return "That vault write request is invalid."
        case .vaultWriteTargetMissing:
            return "The target note does not exist yet."
        }
    }
}
