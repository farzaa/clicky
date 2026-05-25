//
//  TeachingSkill.swift
//  leanring-buddy
//
//  Model and parsing for local teaching skills stored as SKILL.md files.
//

import Foundation

enum TeachingSkillStatus: String, Codable, CaseIterable {
    case active
    case stale
    case archived
}

struct TeachingSkill: Identifiable, Equatable {
    let id: String
    var name: String
    var description: String
    var bundleIds: [String]
    var status: TeachingSkillStatus
    var lastUsed: Date?
    var usageCount: Int
    var isPinned: Bool
    var body: String

    var folderURL: URL {
        TeachingSkillStore.skillsRootURL.appendingPathComponent(id, isDirectory: true)
    }

    var fileURL: URL {
        folderURL.appendingPathComponent("SKILL.md")
    }

    func renderedMarkdown(maxBodyCharacters: Int = 2500) -> String {
        var content = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.count > maxBodyCharacters {
            let endIndex = content.index(content.startIndex, offsetBy: maxBodyCharacters)
            content = String(content[..<endIndex]) + "\n..."
        }
        return """
        ### \(name)
        \(description)

        \(content)
        """
    }

    func serialize() -> String {
        let lastUsedValue = lastUsed.map { TeachingSkill.dateFormatter.string(from: $0) } ?? ""
        let bundleLines = bundleIds.map { "  - \($0)" }.joined(separator: "\n")
        return """
        ---
        name: \(name)
        description: \(TeachingSkill.yamlEscape(description))
        bundleIds:
        \(bundleLines.isEmpty ? "  []" : bundleLines)
        status: \(status.rawValue)
        lastUsed: \(lastUsedValue)
        usageCount: \(usageCount)
        pinned: \(isPinned)
        ---

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))

        """
    }

    static func slug(from name: String) -> String {
        let lowered = name.lowercased()
        let allowed = lowered.map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            if character == " " || character == "-" || character == "_" { return "-" }
            return "-"
        }
        let collapsed = String(allowed)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "teaching-skill" : collapsed
    }

    static func parse(id: String, markdown: String) -> TeachingSkill? {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else { return nil }

        let components = trimmed.components(separatedBy: "---")
        guard components.count >= 3 else { return nil }

        let frontmatter = components[1]
        let body = components.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = parseFrontmatter(frontmatter)

        let name = metadata["name"] ?? id
        let description = metadata["description"] ?? ""
        let bundleIds = metadata["bundleIds"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let status = TeachingSkillStatus(rawValue: metadata["status"] ?? "active") ?? .active
        let lastUsed = metadata["lastUsed"].flatMap { dateFormatter.date(from: $0) }
        let usageCount = Int(metadata["usageCount"] ?? "0") ?? 0
        let isPinned = (metadata["pinned"] ?? "false").lowercased() == "true"

        return TeachingSkill(
            id: id,
            name: name,
            description: description,
            bundleIds: bundleIds,
            status: status,
            lastUsed: lastUsed,
            usageCount: usageCount,
            isPinned: isPinned,
            body: body
        )
    }

    private static func parseFrontmatter(_ frontmatter: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentListKey: String?
        var listValues: [String] = []

        func flushList() {
            guard let key = currentListKey else { return }
            result[key] = listValues.joined(separator: ",")
            currentListKey = nil
            listValues = []
        }

        for line in frontmatter.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("- ") {
                listValues.append(String(trimmedLine.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                continue
            }

            flushList()

            guard let separatorIndex = trimmedLine.firstIndex(of: ":") else { continue }
            let key = String(trimmedLine[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmedLine[trimmedLine.index(after: separatorIndex)...])
                .trimmingCharacters(in: .whitespaces)

            if value.isEmpty {
                currentListKey = key
                listValues = []
            } else {
                result[key] = unyamlEscape(value)
            }
        }

        flushList()
        return result
    }

    private static func yamlEscape(_ value: String) -> String {
        if value.contains(":") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return value
    }

    private static func unyamlEscape(_ value: String) -> String {
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            let inner = value.dropFirst().dropLast()
            return inner.replacingOccurrences(of: "\\\"", with: "\"")
        }
        return value
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct SessionTraceEntry: Equatable {
    let timestamp: Date
    let userTranscript: String
    let assistantResponse: String
    let bundleId: String?
    let pointed: Bool
}
