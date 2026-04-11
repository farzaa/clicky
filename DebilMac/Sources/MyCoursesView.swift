import AppKit
import SwiftUI

struct MyCoursesView: View {
    var onBack: () -> Void
    var onCourseDetail: (String) -> Void

    @State private var search = ""
    @State private var expandedCourses: Set<String> = []
    @State private var expandedNodeIds: Set<String> = []
    @State private var selectedCourseId: String?
    @State private var hoveredCourseId: String?
    @State private var selectedNodeId: String?
    @State private var importedItems: [URL] = []
    @State private var ratingOverrides: [String: Int] = [:]

    private var query: String { search.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }

    private var topCourseIds: [String] { CourseData.topCourseIds }

    private var filteredCourseIds: [String] {
        guard !query.isEmpty else { return topCourseIds }
        let ids = topCourseIds.filter { CourseData.itemMatchesSearch(itemId: $0, query: query) }
        return CourseData.sortCourseIds(ids)
    }

    private var groupedCourseIds: [(bucket: CourseBucket, ids: [String])] {
        let grouped = Dictionary(grouping: filteredCourseIds, by: { CourseData.bucket(for: $0) })
        return CourseBucket.allCases.compactMap { bucket in
            guard let ids = grouped[bucket], !ids.isEmpty else { return nil }
            return (bucket, CourseData.sortCourseIds(ids))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DebilHeaderBar(onBrandTap: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    titleBlock
                    searchField

                    VStack(spacing: 12) {
                        ForEach(groupedCourseIds, id: \.bucket) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.bucket.rawValue)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(DS.mutedForeground)
                                    .padding(.horizontal, 2)

                                VStack(spacing: 8) {
                                    ForEach(group.ids, id: \.self) { courseId in
                                        courseRow(courseId: courseId)
                                    }
                                }
                            }
                        }
                    }

                    if !search.isEmpty && filteredCourseIds.isEmpty {
                        Text("No results for \"\(search)\"")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(DS.mutedForeground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DS.accent.opacity(0.5))
                        .frame(width: 34, height: 34)
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(DS.mutedForeground)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("My courses")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DS.foreground)
                    Text("Browse and manage course materials")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DS.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Button(action: openImportPanel) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Add files…")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(DS.foreground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DS.card.opacity(0.9))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(DS.border.opacity(0.9))
                            )
                    )
                }
                .buttonStyle(.plain)

                if !importedItems.isEmpty {
                    Text("Added: \(importedItems.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DS.mutedForeground)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(DS.mutedForeground.opacity(0.6))
            TextField("Search folders and files...", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(8)
        .background(DS.card.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DS.border.opacity(0.6)))
    }

    private func courseRow(courseId: String) -> some View {
        let course = CourseData.courseSummary(for: courseId)
        let expanded = expandedCourses.contains(courseId)
        let fileCount = course?.fileCount ?? 0
        let roots = CourseData.courseForest(courseId: courseId)
        let visibleRoots = query.isEmpty ? roots : CourseData.filterNodes(roots, query: query)
        let isSelected = selectedCourseId == courseId
        let isHovered = hoveredCourseId == courseId

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    selectedCourseId = courseId
                    withAnimation(.easeInOut(duration: 0.18)) {
                        toggleCourse(courseId)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.mutedForeground)
                            .frame(width: 12)
                        Image(systemName: expanded ? "folder.fill" : "folder")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.mutedForeground.opacity(0.9))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(course?.name ?? courseId)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DS.foreground)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text("\(fileCount) files")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(DS.mutedForeground)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button("Open") {
                    selectedCourseId = courseId
                    onCourseDetail(courseId)
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? DS.accent.opacity(0.32) : (isHovered ? DS.accent.opacity(0.16) : .clear))
            )

            if expanded {
                Divider().overlay(DS.border.opacity(0.45))
                    .padding(.horizontal, 10)
                MinimalTree(
                    roots: visibleRoots,
                    query: query,
                    expandedNodeIds: $expandedNodeIds,
                    selectedNodeId: $selectedNodeId,
                    ratingOverrides: ratingOverrides,
                    onRatingChange: { nodeId, newRating in
                        ratingOverrides[nodeId] = newRating
                    }
                )
                .padding(10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DS.card.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? DS.foreground.opacity(0.22) : DS.border.opacity(0.55))
                )
        )
        .onHover { hovering in
            hoveredCourseId = hovering ? courseId : (hoveredCourseId == courseId ? nil : hoveredCourseId)
        }
    }

    private func toggleCourse(_ courseId: String) {
        if expandedCourses.contains(courseId) {
            expandedCourses.remove(courseId)
        } else {
            expandedCourses.insert(courseId)
        }
    }

    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Add"

        panel.begin { response in
            guard response == .OK else { return }
            DispatchQueue.main.async {
                mergeImportedURLs(panel.urls)
            }
        }
    }

    private func mergeImportedURLs(_ urls: [URL]) {
        var seen = Set<String>()
        var merged: [URL] = []
        for u in importedItems + urls {
            let key = u.resolvingSymlinksInPath().standardizedFileURL.path
            if seen.insert(key).inserted {
                merged.append(u)
            }
        }
        importedItems = merged
    }
}

private struct MinimalTree: View {
    let roots: [MaterialNode]
    let query: String
    @Binding var expandedNodeIds: Set<String>
    @Binding var selectedNodeId: String?
    let ratingOverrides: [String: Int]
    let onRatingChange: (String, Int) -> Void
    @State private var hoveredNodeId: String?

    private struct VisibleNode: Identifiable {
        let id: String
        let node: MaterialNode
        let level: Int
    }

    private var visibleNodes: [VisibleNode] {
        roots.flatMap { flatten($0, level: 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleNodes) { item in
                nodeRow(item)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DS.background.opacity(0.65))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DS.border.opacity(0.45)))
        )
    }

    private func nodeRow(_ item: VisibleNode) -> some View {
        let node = item.node
        let isFolder = node.children != nil
        let isExpanded = expandedNodeIds.contains(node.id)
        let isSelected = selectedNodeId == node.id
        let isHovered = hoveredNodeId == node.id

        let row = rowContent(node: node, isFolder: isFolder, isExpanded: isExpanded)
            .padding(.leading, CGFloat(item.level) * 14)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? DS.accent.opacity(0.35) : (isHovered ? DS.accent.opacity(0.18) : DS.card.opacity(0.45)))
            )

        if isFolder {
            return AnyView(
                Button {
                    selectedNodeId = node.id
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if expandedNodeIds.contains(node.id) {
                            expandedNodeIds.remove(node.id)
                        } else {
                            expandedNodeIds.insert(node.id)
                        }
                    }
                } label: {
                    row
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .onHover { hovering in
                    hoveredNodeId = hovering ? node.id : (hoveredNodeId == node.id ? nil : hoveredNodeId)
                }
            )
        } else {
            return AnyView(
                row
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedNodeId = node.id
                    }
                    .onHover { hovering in
                        hoveredNodeId = hovering ? node.id : (hoveredNodeId == node.id ? nil : hoveredNodeId)
                    }
            )
        }
    }

    private func rowContent(node: MaterialNode, isFolder: Bool, isExpanded: Bool) -> some View {
        HStack(spacing: 8) {
            Group {
                if isFolder {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.mutedForeground.opacity(0.75))
                } else {
                    Color.clear
                }
            }
            .frame(width: 10, height: 10)

            Image(systemName: isFolder ? "folder" : "doc")
                .font(.system(size: 12))
                .foregroundStyle(DS.mutedForeground.opacity(0.75))

            Text(node.name)
                .font(.system(size: 12))
                .foregroundStyle(DS.foreground.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if !isFolder {
                StarRatingView(
                    rating: currentRating(for: node),
                    onChange: { newRating in
                        selectedNodeId = node.id
                        onRatingChange(node.id, newRating)
                    }
                )
            }
        }
    }

    private func currentRating(for node: MaterialNode) -> Int {
        ratingOverrides[node.id] ?? node.rating ?? 0
    }

    private func flatten(_ node: MaterialNode, level: Int) -> [VisibleNode] {
        let isExpanded = expandedNodeIds.contains(node.id)
        var rows = [VisibleNode(id: node.id, node: node, level: level)]
        if isExpanded, let children = node.children {
            for child in children {
                rows.append(contentsOf: flatten(child, level: level + 1))
            }
        }
        return rows
    }
}
