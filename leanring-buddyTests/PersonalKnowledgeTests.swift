//
//  PersonalKnowledgeTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import leanring_buddy

struct PersonalKnowledgeTests {
    @Test func vaultIntentDetectsExplicitVaultQuestions() {
        #expect(VaultIntentDetector.shouldRetrievePersonalKnowledge(transcript: "what did I write about my startup?"))
        #expect(VaultIntentDetector.shouldRetrievePersonalKnowledge(transcript: "search my notes for project alpha"))
        #expect(VaultIntentDetector.shouldRetrievePersonalKnowledge(transcript: "what do my notes say about hiring"))
    }

    @Test func vaultIntentIgnoresNormalScreenQuestions() {
        #expect(!VaultIntentDetector.shouldRetrievePersonalKnowledge(transcript: "where is the save button"))
        #expect(!VaultIntentDetector.shouldRetrievePersonalKnowledge(transcript: "how do I export this video"))
        #expect(!VaultIntentDetector.shouldRetrievePersonalKnowledge(transcript: "what is html"))
    }

    @Test func vaultIntentIgnoresTakeNotesActionPhrases() {
        #expect(!VaultIntentDetector.shouldRetrievePersonalKnowledge(transcript: "how do I take notes in obsidian"))
    }

    @Test func personalContextAssemblerAddsNoteExcerptsToUserMessage() {
        let chunks = [
            PersonalKnowledgeChunk(
                sourcePath: "/tmp/vault/Projects.md",
                sourceLabel: "Work/Projects.md",
                excerpt: "Project Alpha status: waiting on design review.",
                score: 2
            )
        ]

        let userPrompt = PersonalContextAssembler.buildUserPrompt(
            originalTranscript: "what did I write about project alpha?",
            retrievedChunks: chunks
        )

        #expect(userPrompt.contains("relevant notes"))
        #expect(userPrompt.contains("Project Alpha status"))
        #expect(userPrompt.contains("what did I write about project alpha?"))
        #expect(!userPrompt.contains("teaching skills"))
    }

    @Test func personalContextAssemblerReturnsOriginalTranscriptWhenNoChunks() {
        let userPrompt = PersonalContextAssembler.buildUserPrompt(
            originalTranscript: "what did I write about project alpha?",
            retrievedChunks: []
        )

        #expect(userPrompt == "what did I write about project alpha?")
    }

    @Test func vaultIntentDetectsVaultOverviewQuestions() {
        #expect(VaultIntentDetector.shouldRetrievePersonalKnowledge(transcript: "tell me what's in my vault"))
        #expect(VaultIntentDetector.shouldRetrievePersonalKnowledge(transcript: "tell me whats in my vault"))
    }

    @Test func personalKnowledgeManagerUsesStopWordsForSearch() async throws {
        let temporaryRootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-vault-test-\(UUID().uuidString)", isDirectory: true)
        let temporaryVaultDirectory = temporaryRootDirectory.appendingPathComponent("vault", isDirectory: true)
        let temporaryBrainDirectory = temporaryRootDirectory.appendingPathComponent("brain", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryVaultDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryBrainDirectory, withIntermediateDirectories: true)

        let noteURL = temporaryVaultDirectory.appendingPathComponent("Projects.md")
        try "Project Alpha is blocked on design review.".write(to: noteURL, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: temporaryRootDirectory)
        }

        let manager = PersonalKnowledgeManager(brainRootURL: temporaryBrainDirectory)
        _ = try manager.connectVault(at: temporaryVaultDirectory, label: "Test Vault")

        let overviewChunks = await manager.search(query: "tell me whats in my vault")
        #expect(!overviewChunks.isEmpty)
        #expect(overviewChunks.contains(where: { $0.sourceLabel.contains("Projects.md") }))
        #expect(overviewChunks.first?.excerpt.contains("recent note:") == true)
    }

    @Test func personalKnowledgeManagerSearchesConnectedVault() async throws {
        let temporaryRootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-vault-test-\(UUID().uuidString)", isDirectory: true)
        let temporaryVaultDirectory = temporaryRootDirectory.appendingPathComponent("vault", isDirectory: true)
        let temporaryBrainDirectory = temporaryRootDirectory.appendingPathComponent("brain", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryVaultDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryBrainDirectory, withIntermediateDirectories: true)

        let noteURL = temporaryVaultDirectory.appendingPathComponent("Projects.md")
        try "Project Alpha is blocked on design review.".write(to: noteURL, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: temporaryRootDirectory)
        }

        let manager = PersonalKnowledgeManager(brainRootURL: temporaryBrainDirectory)
        _ = try manager.connectVault(at: temporaryVaultDirectory, label: "Test Vault")

        let chunks = await manager.search(query: "what did I write about project alpha?")
        #expect(chunks.contains(where: { $0.excerpt.contains("Project Alpha") }))
    }

    @Test func connectedVaultsFileRoundTripsThroughJSON() throws {
        let temporaryBrainDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-brain-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryBrainDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryBrainDirectory) }

        let manager = PersonalKnowledgeManager(brainRootURL: temporaryBrainDirectory)
        let temporaryVaultDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-vault-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryVaultDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryVaultDirectory) }

        _ = try manager.connectVault(at: temporaryVaultDirectory, label: "Test Vault")

        let reloadedManager = PersonalKnowledgeManager(brainRootURL: temporaryBrainDirectory)
        #expect(reloadedManager.connectedVaults.count == 1)
        #expect(reloadedManager.connectedVaults.first?.label == "Test Vault")
    }

    @Test func vaultDiscoveryParsesObsidianRegistryShape() {
        let discoveredVault = DiscoveredVault(
            id: "abc123",
            displayName: "Work",
            path: "/Users/test/Documents/Work"
        )

        #expect(discoveredVault.displayName == "Work")
        #expect(discoveredVault.folderURL.path == "/Users/test/Documents/Work")
    }

    @Test func vaultWriteIntentParsesExplicitSaveCommands() {
        let writeRequest = VaultWriteIntentDetector.parseWriteRequest(
            transcript: "save to my vault: project kickoff is next Tuesday"
        )

        #expect(writeRequest != nil)
        if case .newNote(let noteTitle, let noteContent)? = writeRequest?.destination {
            #expect(noteTitle == "project kickoff is next Tuesday")
            #expect(noteContent == "project kickoff is next Tuesday")
        } else {
            Issue.record("Expected new note write request")
        }
    }

    @Test func vaultWriteIntentParsesDailyNoteCommands() {
        let writeRequest = VaultWriteIntentDetector.parseWriteRequest(
            transcript: "add to my daily note: shipped the vault write feature"
        )

        #expect(writeRequest != nil)
        if case .appendDailyNote(let noteContent)? = writeRequest?.destination {
            #expect(noteContent == "shipped the vault write feature")
        } else {
            Issue.record("Expected daily note write request")
        }
    }

    @Test func vaultWriteIntentParsesMemoryCommands() {
        let writeRequest = VaultWriteIntentDetector.parseWriteRequest(
            transcript: "remember in my notes: I prefer concise answers"
        )

        #expect(writeRequest != nil)
        if case .appendMemory(let noteContent)? = writeRequest?.destination {
            #expect(noteContent == "I prefer concise answers")
        } else {
            Issue.record("Expected memory write request")
        }
    }

    @Test func vaultIntentIgnoresWriteCommands() {
        #expect(!VaultIntentDetector.shouldRetrievePersonalKnowledge(transcript: "save to my vault: launch checklist"))
        #expect(!VaultIntentDetector.shouldRetrievePersonalKnowledge(transcript: "add to my daily note: standup notes"))
    }

    @Test func personalKnowledgeManagerExecutesVaultWrites() async throws {
        let temporaryRootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-vault-write-test-\(UUID().uuidString)", isDirectory: true)
        let temporaryVaultDirectory = temporaryRootDirectory.appendingPathComponent("vault", isDirectory: true)
        let temporaryBrainDirectory = temporaryRootDirectory.appendingPathComponent("brain", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryVaultDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryBrainDirectory, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: temporaryRootDirectory)
        }

        let manager = PersonalKnowledgeManager(brainRootURL: temporaryBrainDirectory)
        _ = try manager.connectVault(at: temporaryVaultDirectory, label: "Test Vault")

        let newNoteRequest = VaultWriteRequest(
            destination: .newNote(noteTitle: "Launch Plan", noteContent: "Ship vault writes on Thursday."),
            sourceTranscript: "save to my vault: Ship vault writes on Thursday."
        )
        let newNoteResult = try await manager.executeWrite(newNoteRequest)
        #expect(newNoteResult.relativePath.hasSuffix("Launch-Plan.md"))
        #expect(newNoteResult.vaultLabel == "Test Vault")

        let dailyNoteRequest = VaultWriteRequest(
            destination: .appendDailyNote(noteContent: "Finished tests."),
            sourceTranscript: "add to my daily note: Finished tests."
        )
        let dailyNoteResult = try await manager.executeWrite(dailyNoteRequest)
        #expect(dailyNoteResult.relativePath.hasPrefix("Daily Notes/"))

        let memoryRequest = VaultWriteRequest(
            destination: .appendMemory(noteContent: "Prefers concise answers."),
            sourceTranscript: "remember in my notes: Prefers concise answers."
        )
        let memoryResult = try await manager.executeWrite(memoryRequest)
        #expect(memoryResult.relativePath == "MEMORY.md")
        #expect(memoryResult.vaultLabel == "Clicky brain")
    }
}
