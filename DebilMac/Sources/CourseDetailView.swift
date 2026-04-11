import AppKit
import SwiftUI

private struct CourseMaterial: Identifiable {
    let id: String
    let name: String
    let status: Status

    enum Status: Hashable {
        case known
        case learning
        case missed

        var label: String {
            switch self {
            case .known: return "Known"
            case .learning: return "Learning"
            case .missed: return "Missed"
            }
        }

        var color: Color {
            switch self {
            case .known: return DS.success
            case .learning: return DS.warning
            case .missed: return DS.destructive
            }
        }

        var systemImage: String {
            switch self {
            case .known: return "checkmark.circle.fill"
            case .learning: return "clock.fill"
            case .missed: return "exclamationmark.triangle.fill"
            }
        }
    }
}

struct CourseDetailView: View {
    let courseId: String
    var onBack: () -> Void

    @State private var importedItems: [URL] = []

    private var courseItem: MaterialItem? { CourseData.items[courseId] }

    private var courseName: String {
        guard let item = courseItem else { return "Course" }
        let parts = item.name.components(separatedBy: "–")
        if parts.count >= 2 {
            return parts.dropFirst().joined(separator: "–").trimmingCharacters(in: .whitespaces)
        }
        return item.name
    }

    private var courseCode: String {
        guard let item = courseItem else { return courseId.uppercased() }
        let parts = item.name.components(separatedBy: "–")
        if let code = parts.first?.trimmingCharacters(in: .whitespaces), !code.isEmpty {
            return code
        }
        return courseId.uppercased()
    }

    private var materials: [CourseMaterial] {
        let roots = CourseData.courseForest(courseId: courseId)
        let leaves = roots.flatMap(flattenLeaves)
        return leaves.map { leaf in
            let status: CourseMaterial.Status
            if leaf.isNew || (leaf.rating ?? 0) == 0 {
                status = .missed
            } else if (leaf.rating ?? 0) <= 2 {
                status = .learning
            } else {
                status = .known
            }
            return CourseMaterial(id: leaf.id, name: leaf.name, status: status)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DebilHeaderBar(onBrandTap: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(courseName)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(DS.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(courseCode)
                                .foregroundStyle(DS.mutedForeground)
                        }
                        Button(action: openImportPanel) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Upload materials")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DS.foreground)
                        .foregroundStyle(DS.background)

                        if !importedItems.isEmpty {
                            Text("Added now: \(importedItems.count) item\(importedItems.count == 1 ? "" : "s")")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DS.mutedForeground)
                        }
                    }

                    HStack(spacing: 8) {
                        ForEach([CourseMaterial.Status.known, .learning, .missed], id: \.self) { st in
                            let count = materials.filter { $0.status == st }.count
                            VStack(spacing: 6) {
                                Image(systemName: st.systemImage)
                                    .font(.system(size: 14))
                                    .foregroundStyle(st.color)
                                Text("\(count)")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(DS.foreground)
                                Text(st.label)
                                    .font(.caption2)
                                    .foregroundStyle(DS.mutedForeground)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(DS.card.opacity(0.9))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(DS.border))
                            )
                        }
                    }

                    Text("Course materials")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(DS.foreground)

                    if materials.isEmpty {
                        Text("No materials found for this course yet.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(DS.mutedForeground)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(DS.card.opacity(0.9))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(DS.border.opacity(0.6)))
                            )
                    } else {
                        VStack(spacing: 8) {
                            ForEach(materials) { m in
                                HStack {
                                    Image(systemName: "book.closed")
                                        .foregroundStyle(DS.mutedForeground)
                                    Text(m.name)
                                        .font(.callout)
                                        .foregroundStyle(DS.foreground)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    Image(systemName: m.status.systemImage)
                                        .foregroundStyle(m.status.color)
                                    Text(m.status.label)
                                        .font(.caption)
                                        .foregroundStyle(m.status.color)
                                }
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(DS.card.opacity(0.9))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DS.border.opacity(0.6)))
                                )
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity)
            }
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

    private func flattenLeaves(_ node: MaterialNode) -> [MaterialNode] {
        guard let children = node.children, !children.isEmpty else { return [node] }
        return children.flatMap(flattenLeaves)
    }
}
