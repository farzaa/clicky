import Foundation

struct MaterialItem: Hashable {
    var name: String
    var children: [String]?
    var rating: Int?
    var isNew: Bool?
}

struct CourseSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let isNew: Bool
    let fileCount: Int
}

enum CourseBucket: String, CaseIterable, Hashable {
    case year1 = "Year 1"
    case year2 = "Year 2"
    case year3 = "Year 3"
    case year4 = "Year 4"
    case commonCore = "Common Core"
    case other = "Other"
}

/// Mirrors `ExistingFolder.tsx` `existingItems`.
enum CourseData {
    static private(set) var items: [String: MaterialItem] = [
        "root": MaterialItem(
            name: "My Courses",
            children: ["cs101", "math201", "phys150", "bio110", "comp3230"],
            rating: nil,
            isNew: nil
        ),
        "cs101": MaterialItem(name: "CS 101 – Intro to Computer Science", children: ["cs101-lectures", "cs101-labs"], rating: nil, isNew: nil),
        "cs101-lectures": MaterialItem(name: "Lectures", children: ["cs101-lec1", "cs101-lec2", "cs101-lec3"], rating: nil, isNew: nil),
        "cs101-lec1": MaterialItem(name: "Lecture 1 - Variables.pdf", children: nil, rating: 4, isNew: nil),
        "cs101-lec2": MaterialItem(name: "Lecture 2 - Control Flow.pdf", children: nil, rating: 2, isNew: nil),
        "cs101-lec3": MaterialItem(name: "Lecture 3 - Functions.pdf", children: nil, rating: 5, isNew: nil),
        "cs101-labs": MaterialItem(name: "Labs", children: ["cs101-lab1", "cs101-lab2"], rating: nil, isNew: nil),
        "cs101-lab1": MaterialItem(name: "Lab 1 - Hello World.py", children: nil, rating: 5, isNew: nil),
        "cs101-lab2": MaterialItem(name: "Lab 2 - Loops.py", children: nil, rating: 3, isNew: nil),
        "math201": MaterialItem(name: "MATH 201 – Linear Algebra", children: ["math-notes", "math-hw"], rating: nil, isNew: nil),
        "math-notes": MaterialItem(name: "Notes", children: ["math-n1", "math-n2"], rating: nil, isNew: nil),
        "math-n1": MaterialItem(name: "Chapter 1 - Vectors.pdf", children: nil, rating: 3, isNew: nil),
        "math-n2": MaterialItem(name: "Chapter 2 - Matrices.pdf", children: nil, rating: 1, isNew: nil),
        "math-hw": MaterialItem(name: "Homework", children: ["math-hw1"], rating: nil, isNew: nil),
        "math-hw1": MaterialItem(name: "Problem Set 1.pdf", children: nil, rating: 4, isNew: nil),
        "phys150": MaterialItem(name: "PHYS 150 – Mechanics", children: ["phys-slides", "phys-exam"], rating: nil, isNew: nil),
        "phys-slides": MaterialItem(name: "Slides", children: ["phys-s1", "phys-s2"], rating: nil, isNew: nil),
        "phys-s1": MaterialItem(name: "Kinematics.pptx", children: nil, rating: 2, isNew: nil),
        "phys-s2": MaterialItem(name: "Newton's Laws.pptx", children: nil, rating: 5, isNew: nil),
        "phys-exam": MaterialItem(name: "Midterm Review.pdf", children: nil, rating: 3, isNew: nil),
        "bio110": MaterialItem(name: "BIO 110 – Cell Biology", children: ["bio-lectures", "bio-labs"], rating: nil, isNew: true),
        "bio-lectures": MaterialItem(name: "Lectures", children: ["bio-lec1", "bio-lec2"], rating: nil, isNew: true),
        "bio-lec1": MaterialItem(name: "Lecture 1 - Cell Structure.pdf", children: nil, rating: 0, isNew: true),
        "bio-lec2": MaterialItem(name: "Lecture 2 - Mitosis.pdf", children: nil, rating: 0, isNew: true),
        "bio-labs": MaterialItem(name: "Labs", children: ["bio-lab1"], rating: nil, isNew: true),
        "bio-lab1": MaterialItem(name: "Lab 1 - Microscopy.pdf", children: nil, rating: 0, isNew: true),
        "comp3230": MaterialItem(
            name: "COMP3230 – Operating Systems (HKU)",
            children: ["comp3230-lectures", "comp3230-assignments"],
            rating: nil,
            isNew: nil
        ),
        "comp3230-lectures": MaterialItem(
            name: "Lectures",
            children: ["comp3230-lec1", "comp3230-lec2", "comp3230-lec3"],
            rating: nil,
            isNew: nil
        ),
        "comp3230-lec1": MaterialItem(name: "Lecture 1 - Processes and threads.pdf", children: nil, rating: 4, isNew: nil),
        "comp3230-lec2": MaterialItem(name: "Lecture 2 - CPU scheduling.pdf", children: nil, rating: 3, isNew: nil),
        "comp3230-lec3": MaterialItem(name: "Lecture 3 - Memory management.pdf", children: nil, rating: 2, isNew: nil),
        "comp3230-assignments": MaterialItem(name: "Assignments", children: ["comp3230-a1", "comp3230-a2"], rating: nil, isNew: nil),
        "comp3230-a1": MaterialItem(name: "Assignment 1 - Shell basics.pdf", children: nil, rating: 5, isNew: nil),
        "comp3230-a2": MaterialItem(name: "Assignment 2 - Pthreads.pdf", children: nil, rating: 0, isNew: nil),
    ]

    static func itemMatchesSearch(itemId: String, query: String) -> Bool {
        guard let item = items[itemId] else { return false }
        if query.isEmpty { return true }
        if item.name.lowercased().contains(query) { return true }
        if let ch = item.children {
            return ch.contains { itemMatchesSearch(itemId: $0, query: query) }
        }
        return false
    }

    static func countFiles(itemId: String) -> Int {
        guard let item = items[itemId] else { return 0 }
        guard let ch = item.children else { return 1 }
        return ch.reduce(0) { $0 + countFiles(itemId: $1) }
    }

    static var topCourseIds: [String] {
        if let rootKids = items["root"]?.children, !rootKids.isEmpty {
            return rootKids.filter { items[$0] != nil }
        }
        return inferredTopCourseIds()
    }

    static func courseSummary(for courseId: String) -> CourseSummary? {
        guard let item = items[courseId] else { return nil }
        return CourseSummary(
            id: courseId,
            name: item.name,
            isNew: item.isNew ?? false,
            fileCount: countFiles(itemId: courseId)
        )
    }

    static func sortCourseIds(_ ids: [String]) -> [String] {
        ids.sorted { lhs, rhs in
            let l = items[lhs]?.name ?? lhs
            let r = items[rhs]?.name ?? rhs
            return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
        }
    }

    static func bucket(for courseId: String) -> CourseBucket {
        guard let name = items[courseId]?.name else { return .other }
        let code = name.components(separatedBy: "–").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? name
        let upper = code.uppercased()

        if upper.hasPrefix("CC") || upper.contains("COMMON CORE") {
            return .commonCore
        }

        if let firstDigit = code.first(where: { $0.isNumber }),
           let year = Int(String(firstDigit)),
           (1 ... 4).contains(year) {
            switch year {
            case 1: return .year1
            case 2: return .year2
            case 3: return .year3
            case 4: return .year4
            default: break
            }
        }

        return .other
    }

    /// Future-friendly insertion API for user-created courses (in-memory for now).
    @discardableResult
    static func addCourse(
        id: String,
        name: String,
        children: [String] = [],
        isNew: Bool = true
    ) -> Bool {
        guard !id.isEmpty, items[id] == nil else { return false }

        items[id] = MaterialItem(
            name: name,
            children: children.isEmpty ? nil : children,
            rating: nil,
            isNew: isNew
        )

        var root = items["root"] ?? MaterialItem(name: "My Courses", children: [], rating: nil, isNew: nil)
        var rootChildren = root.children ?? []
        if !rootChildren.contains(id) {
            rootChildren.append(id)
        }
        root.children = rootChildren
        items["root"] = root
        return true
    }

    private static func inferredTopCourseIds() -> [String] {
        var childIds = Set<String>()
        for item in items.values {
            for child in item.children ?? [] {
                childIds.insert(child)
            }
        }

        return items
            .filter { key, item in
                key != "root" && !childIds.contains(key) && item.children != nil
            }
            .map(\.key)
            .sorted()
    }
}

struct MaterialNode: Identifiable, Hashable {
    let id: String
    let name: String
    var rating: Int?
    var isNew: Bool
    var children: [MaterialNode]?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MaterialNode, rhs: MaterialNode) -> Bool {
        lhs.id == rhs.id
    }
}

extension CourseData {
    static func buildSubtree(from itemId: String) -> MaterialNode {
        guard let item = items[itemId] else {
            return MaterialNode(
                id: itemId,
                name: itemId,
                rating: nil,
                isNew: false,
                children: nil
            )
        }
        if let ch = item.children {
            return MaterialNode(
                id: itemId,
                name: item.name,
                rating: item.rating,
                isNew: item.isNew ?? false,
                children: ch.map { buildSubtree(from: $0) }
            )
        }
        return MaterialNode(
            id: itemId,
            name: item.name,
            rating: item.rating,
            isNew: item.isNew ?? false,
            children: nil
        )
    }

    static func courseForest(courseId: String) -> [MaterialNode] {
        guard let item = items[courseId], let kids = item.children else { return [] }
        return kids.map { buildSubtree(from: $0) }
    }

    static func filterNodes(_ nodes: [MaterialNode], query: String) -> [MaterialNode] {
        guard !query.isEmpty else { return nodes }
        return nodes.compactMap { filterNode($0, query: query) }
    }

    private static func filterNode(_ node: MaterialNode, query: String) -> MaterialNode? {
        guard itemMatchesSearch(itemId: node.id, query: query) else { return nil }
        if let ch = node.children {
            let mapped = ch.compactMap { filterNode($0, query: query) }
            return MaterialNode(id: node.id, name: node.name, rating: node.rating, isNew: node.isNew, children: mapped.isEmpty ? nil : mapped)
        }
        return node
    }
}
