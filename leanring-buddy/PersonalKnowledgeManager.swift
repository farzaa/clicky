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

    private let brainRootURL: URL
    private let sourcesFileURL: URL

    private(set) var connectedVaults: [ConnectedVault] = []

    private let excludedPathComponents: Set<String> = [
        ".git",
        "node_modules",
        ".trash",
        "Trash"
    ]

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

    func search(query: String, maxChunks: Int = 4) -> [PersonalKnowledgeChunk] {
        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        var scoredChunks: [PersonalKnowledgeChunk] = []

        for vault in connectedVaults {
            guard let resolvedURL = resolveVaultURL(vault) else { continue }
            let vaultChunks = searchMarkdownFiles(
                in: resolvedURL,
                vaultLabel: vault.label,
                queryTokens: queryTokens
            )
            scoredChunks.append(contentsOf: vaultChunks)
        }

        scoredChunks.append(contentsOf: searchBrainMarkdownFiles(queryTokens: queryTokens))

        return scoredChunks
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.sourceLabel.localizedCaseInsensitiveCompare(rhs.sourceLabel) == .orderedAscending
            }
            .prefix(maxChunks)
            .map { $0 }
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

    private func resolveVaultURL(_ vault: ConnectedVault) -> URL? {
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

    private func searchBrainMarkdownFiles(queryTokens: [String]) -> [PersonalKnowledgeChunk] {
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

    private func searchMarkdownFiles(
        in rootURL: URL,
        vaultLabel: String,
        queryTokens: [String]
    ) -> [PersonalKnowledgeChunk] {
        let markdownFileURLs = collectMarkdownFileURLs(in: rootURL)
        return markdownFileURLs.compactMap { fileURL in
            let relativePath = relativePath(from: rootURL, to: fileURL)
            let sourceLabel = "\(vaultLabel)/\(relativePath)"
            return scoreMarkdownFile(at: fileURL, sourceLabel: sourceLabel, queryTokens: queryTokens)
        }
    }

    private func scoreMarkdownFile(
        at fileURL: URL,
        sourceLabel: String,
        queryTokens: [String]
    ) -> PersonalKnowledgeChunk? {
        guard let fileContents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        let normalizedContents = fileContents.lowercased()
        var score = 0

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

    private func excerpt(from fileContents: String, matchingTokens: [String], maxLength: Int = 800) -> String {
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

    private func collectMarkdownFileURLs(in rootURL: URL) -> [URL] {
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
        }

        return markdownFileURLs
    }

    private func countMarkdownFiles(in rootURL: URL) -> Int {
        collectMarkdownFileURLs(in: rootURL).count
    }

    private func countBrainMarkdownFiles() -> Int {
        let brainFileNames = ["USER.md", "MEMORY.md"]
        return brainFileNames.filter { fileName in
            FileManager.default.fileExists(atPath: brainRootURL.appendingPathComponent(fileName).path)
        }.count
    }

    private func shouldSkipURL(_ fileURL: URL) -> Bool {
        let pathComponents = fileURL.pathComponents
        if pathComponents.contains(where: { excludedPathComponents.contains($0) }) {
            return true
        }

        let fileName = fileURL.lastPathComponent.lowercased()
        return excludedFileNamePatterns.contains { pattern in
            fileName.contains(pattern)
        }
    }

    private func relativePath(from rootURL: URL, to fileURL: URL) -> String {
        let rootPath = (rootURL.path as NSString).standardizingPath
        let filePath = (fileURL.path as NSString).standardizingPath

        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }

        return fileURL.lastPathComponent
    }

    private func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
    }
}

enum PersonalKnowledgeError: LocalizedError {
    case invalidVaultFolder
    case vaultAlreadyConnected
    case vaultFolderNotReadable

    var errorDescription: String? {
        switch self {
        case .invalidVaultFolder:
            return "That folder does not exist or is not a valid vault folder."
        case .vaultAlreadyConnected:
            return "That vault is already connected."
        case .vaultFolderNotReadable:
            return "Clicky cannot read that folder. Choose it again in the folder picker to grant access."
        }
    }
}
