//
//  AuxiliaryMemoryStore.swift
//  leanring-buddy
//
//  Persists non-skill memories (preferences, routines) until dedicated
//  generators and stores land for each category.
//

import Foundation

final class AuxiliaryMemoryStore {
    static var fileURL: URL {
        ClickyPaths.home.appendingPathComponent("auxiliary-memories.json")
    }

    private(set) var memories: [Memory] = []

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func load() {
        guard let fileData = try? Data(contentsOf: Self.fileURL),
              let decodedMemories = try? decoder.decode([Memory].self, from: fileData) else {
            memories = []
            return
        }

        memories = decodedMemories.sorted { lhs, rhs in
            if lhs.usageCount != rhs.usageCount { return lhs.usageCount > rhs.usageCount }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    func memory(withID id: String) -> Memory? {
        memories.first { $0.id == id }
    }

    func memories(for category: MemoryCategory) -> [Memory] {
        memories.filter { $0.category == category }
    }

    @discardableResult
    func save(_ memory: Memory) throws -> Memory {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: ClickyPaths.home, withIntermediateDirectories: true)

        if let index = memories.firstIndex(where: { $0.id == memory.id }) {
            memories[index] = memory
        } else {
            memories.append(memory)
        }

        memories.sort { lhs, rhs in
            if lhs.usageCount != rhs.usageCount { return lhs.usageCount > rhs.usageCount }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        let encodedData = try encoder.encode(memories)
        try encodedData.write(to: Self.fileURL, options: .atomic)
        return memory
    }

    func delete(id: String) throws {
        memories.removeAll { $0.id == id }
        let encodedData = try encoder.encode(memories)
        try encodedData.write(to: Self.fileURL, options: .atomic)
    }
}
