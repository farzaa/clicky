//
//  MarkdownResponseTextView.swift
//  leanring-buddy
//
//  Lightweight Markdown renderer for Dot's on-screen responses.
//  SwiftUI's dynamic Text(markdown:) support is useful for inline styling,
//  but the response bubble needs better block layout and readable math.
//

import Foundation
import SwiftUI

struct MarkdownResponseTextView: View {
    let markdownText: String

    var body: some View {
        let responseBlocks = MarkdownResponseParser.parse(markdownText)

        VStack(alignment: .leading, spacing: 10) {
            ForEach(responseBlocks) { responseBlock in
                responseBlockView(responseBlock)
            }
        }
    }

    @ViewBuilder
    private func responseBlockView(_ responseBlock: MarkdownResponseBlock) -> some View {
        switch responseBlock.kind {
        case .paragraph(let paragraphText):
            MarkdownInlineText(
                text: paragraphText,
                font: .system(size: 16, weight: .regular),
                foregroundColor: .white.opacity(0.96)
            )

        case .heading(let headingLevel, let headingText):
            MarkdownInlineText(
                text: headingText,
                font: headingFont(for: headingLevel),
                foregroundColor: .white
            )
            .padding(.bottom, headingLevel <= 2 ? 1 : 0)

        case .unorderedList(let listItems):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(listItems) { listItem in
                    MarkdownListItemRowView(
                        markerText: "•",
                        itemText: listItem.text,
                        taskState: listItem.taskState
                    )
                }
            }

        case .orderedList(let listItems):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(listItems) { listItem in
                    MarkdownListItemRowView(
                        markerText: listItem.markerText ?? "\(listItem.id + 1).",
                        itemText: listItem.text,
                        taskState: listItem.taskState
                    )
                }
            }

        case .blockquote(let quoteText):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(DS.Colors.overlayCursorBlue.opacity(0.75))
                    .frame(width: 3)
                MarkdownInlineText(
                    text: quoteText,
                    font: .system(size: 15, weight: .regular),
                    foregroundColor: .white.opacity(0.82)
                )
            }
            .padding(.vertical, 2)

        case .fencedCode(let language, let codeText):
            MarkdownCodeBlockView(language: language, codeText: codeText)

        case .diagram(let diagram):
            MarkdownDiagramView(diagram: diagram)

        case .mathBlock(let mathText):
            MarkdownMathBlockView(mathText: mathText)

        case .horizontalRule:
            Rectangle()
                .fill(Color.white.opacity(0.16))
                .frame(height: 1)
                .padding(.vertical, 2)

        case .table(let table):
            MarkdownTableView(table: table)
        }
    }

    private func headingFont(for headingLevel: Int) -> Font {
        switch headingLevel {
        case 1:
            return .system(size: 20, weight: .semibold)
        case 2:
            return .system(size: 18, weight: .semibold)
        default:
            return .system(size: 16.5, weight: .semibold)
        }
    }
}

private struct MarkdownInlineText: View {
    let text: String
    let font: Font
    let foregroundColor: Color

    var body: some View {
        Text(attributedMarkdownText)
            .font(font)
            .foregroundColor(foregroundColor)
            .lineSpacing(4)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .tint(DS.Colors.accentText)
    }

    private var attributedMarkdownText: AttributedString {
        let textWithReadableMath = MathSyntaxFormatter.replacingInlineMathDelimiters(in: text)
        let markdownParsingOptions = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )

        if let attributedString = try? AttributedString(
            markdown: textWithReadableMath,
            options: markdownParsingOptions
        ) {
            return attributedString
        }

        return AttributedString(textWithReadableMath)
    }
}

private struct MarkdownListItemRowView: View {
    let markerText: String
    let itemText: String
    let taskState: MarkdownResponseTaskState?

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            if let taskState {
                Image(systemName: taskState == .checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(taskState == .checked ? DS.Colors.success : .white.opacity(0.48))
                    .frame(width: 16, alignment: .center)
                    .padding(.top, 2)
            } else {
                Text(markerText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.overlayCursorBlue.opacity(0.9))
                    .frame(width: 22, alignment: .trailing)
                    .padding(.top, 0.5)
            }

            MarkdownInlineText(
                text: itemText,
                font: .system(size: 16, weight: .regular),
                foregroundColor: .white.opacity(0.94)
            )
        }
    }
}

private struct MarkdownCodeBlockView: View {
    let language: String?
    let codeText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let language, !language.isEmpty {
                Text(language.lowercased())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(DS.Colors.codeText.opacity(0.82))
                    .textCase(.uppercase)
                    .tracking(0.6)
            }

            Text(codeText)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.075))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
                )
        )
    }
}

private struct MarkdownMathBlockView: View {
    let mathText: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(DS.Colors.overlayCursorBlue.opacity(0.9))
                .frame(width: 3)

            Text(MathSyntaxFormatter.displayText(from: mathText))
                .font(.system(size: 17, weight: .medium, design: .serif))
                .foregroundColor(.white.opacity(0.95))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(DS.Colors.overlayCursorBlue.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(DS.Colors.overlayCursorBlue.opacity(0.22), lineWidth: 0.8)
                )
        )
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownResponseTable

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 9, verticalSpacing: 6) {
            GridRow {
                ForEach(0..<table.columnCount, id: \.self) { columnIndex in
                    MarkdownInlineText(
                        text: table.headerText(at: columnIndex),
                        font: .system(size: 14, weight: .semibold),
                        foregroundColor: .white.opacity(0.96)
                    )
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.12))
                .gridCellColumns(table.columnCount)

            ForEach(table.rows.indices, id: \.self) { rowIndex in
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { columnIndex in
                        MarkdownInlineText(
                            text: table.cellText(rowIndex: rowIndex, columnIndex: columnIndex),
                            font: .system(size: 14, weight: .regular),
                            foregroundColor: .white.opacity(0.82)
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.09), lineWidth: 0.8)
                )
        )
    }
}

private struct MarkdownDiagramView: View {
    let diagram: MarkdownResponseDiagram

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(diagram.badgeText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(DS.Colors.overlayCursorBlue.opacity(0.95))
                    .textCase(.uppercase)
                    .tracking(0.6)

                if let title = diagram.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(2)
                }
            }

            switch diagram.kind {
            case .flowchart(let flowchart):
                MarkdownFlowchartDiagramView(flowchart: flowchart)
            case .sequence(let sequenceDiagram):
                MarkdownSequenceDiagramView(sequenceDiagram: sequenceDiagram)
            case .pie(let pieDiagram):
                MarkdownPieDiagramView(pieDiagram: pieDiagram)
            case .sourceFallback(_, let sourceText):
                MarkdownCodeBlockView(language: diagram.language, codeText: sourceText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(DS.Colors.overlayCursorBlue.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(DS.Colors.overlayCursorBlue.opacity(0.22), lineWidth: 0.8)
                )
        )
    }
}

private struct MarkdownFlowchartDiagramView: View {
    let flowchart: MarkdownResponseFlowchart

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if flowchart.edges.isEmpty {
                FlexibleNodeGrid(nodes: Array(flowchart.nodes.values))
            } else {
                ForEach(flowchart.edges) { edge in
                    HStack(alignment: .center, spacing: 6) {
                        MarkdownDiagramNodeView(node: flowchart.node(for: edge.fromID))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(spacing: 1) {
                            Text(edge.symbolText)
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(DS.Colors.overlayCursorBlue.opacity(0.92))
                            if let label = edge.label, !label.isEmpty {
                                Text(label)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.white.opacity(0.66))
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 48)
                        MarkdownDiagramNodeView(node: flowchart.node(for: edge.toID))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

private struct MarkdownSequenceDiagramView: View {
    let sequenceDiagram: MarkdownResponseSequenceDiagram

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sequenceDiagram.participants, id: \.self) { participant in
                        Text(participant)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.09))
                            )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(sequenceDiagram.messages) { message in
                    HStack(alignment: .center, spacing: 6) {
                        Text(message.from)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.86))
                            .lineLimit(1)
                            .frame(width: 78, alignment: .trailing)
                        Text(message.arrowText)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(DS.Colors.overlayCursorBlue.opacity(0.92))
                            .frame(width: 40)
                        Text(message.to)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.86))
                            .lineLimit(1)
                            .frame(width: 78, alignment: .leading)
                        if !message.text.isEmpty {
                            Text(message.text)
                                .font(.system(size: 12.5, weight: .regular))
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}

private struct MarkdownPieDiagramView: View {
    let pieDiagram: MarkdownResponsePieDiagram

    var totalValue: Double {
        max(0.0001, pieDiagram.slices.reduce(0) { $0 + max(0, $1.value) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(pieDiagram.slices) { slice in
                let fraction = max(0, slice.value) / totalValue
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(slice.label)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.88))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.62))
                    }
                    GeometryReader { geometryProxy in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(DS.Colors.overlayCursorBlue.opacity(0.62))
                                .frame(width: max(5, geometryProxy.size.width * CGFloat(fraction)))
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
    }
}

private struct FlexibleNodeGrid: View {
    let nodes: [MarkdownResponseDiagramNode]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(nodes) { node in
                MarkdownDiagramNodeView(node: node)
            }
        }
    }
}

private struct MarkdownDiagramNodeView: View {
    let node: MarkdownResponseDiagramNode

    var body: some View {
        Text(node.label)
            .font(.system(size: 12.5, weight: node.shape == .decision ? .semibold : .medium))
            .foregroundColor(.white.opacity(0.9))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, 8)
            .padding(.vertical, node.shape == .terminator ? 5 : 6)
            .frame(maxWidth: .infinity)
            .background(nodeBackground)
    }

    @ViewBuilder
    private var nodeBackground: some View {
        switch node.shape {
        case .decision:
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(DS.Colors.warning.opacity(0.34), lineWidth: 0.9)
                )
        case .terminator:
            Capsule()
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Capsule()
                        .stroke(DS.Colors.success.opacity(0.32), lineWidth: 0.9)
                )
        case .process:
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                )
        }
    }
}

struct MarkdownResponseBlock: Identifiable {
    let id: Int
    let kind: Kind

    enum Kind {
        case paragraph(String)
        case heading(level: Int, text: String)
        case unorderedList([MarkdownResponseListItem])
        case orderedList([MarkdownResponseListItem])
        case blockquote(String)
        case fencedCode(language: String?, codeText: String)
        case diagram(MarkdownResponseDiagram)
        case mathBlock(String)
        case horizontalRule
        case table(MarkdownResponseTable)
    }
}

struct MarkdownResponseListItem: Identifiable {
    let id: Int
    let markerText: String?
    let taskState: MarkdownResponseTaskState?
    let text: String
}

enum MarkdownResponseTaskState {
    case checked
    case unchecked
}

struct MarkdownResponseTable {
    let headers: [String]
    let rows: [[String]]

    var columnCount: Int {
        max(headers.count, rows.map(\.count).max() ?? 0)
    }

    func headerText(at columnIndex: Int) -> String {
        guard headers.indices.contains(columnIndex) else { return "" }
        return headers[columnIndex]
    }

    func cellText(rowIndex: Int, columnIndex: Int) -> String {
        guard rows.indices.contains(rowIndex),
              rows[rowIndex].indices.contains(columnIndex) else {
            return ""
        }
        return rows[rowIndex][columnIndex]
    }
}

struct MarkdownResponseDiagram {
    let language: String
    let title: String?
    let kind: Kind

    enum Kind {
        case flowchart(MarkdownResponseFlowchart)
        case sequence(MarkdownResponseSequenceDiagram)
        case pie(MarkdownResponsePieDiagram)
        case sourceFallback(language: String, sourceText: String)
    }

    var badgeText: String {
        switch kind {
        case .flowchart(let flowchart):
            return "mermaid \(flowchart.direction)"
        case .sequence:
            return "mermaid sequence"
        case .pie:
            return "mermaid pie"
        case .sourceFallback(let language, _):
            return language
        }
    }
}

struct MarkdownResponseFlowchart {
    let direction: String
    let nodes: [String: MarkdownResponseDiagramNode]
    let edges: [MarkdownResponseFlowchartEdge]

    func node(for id: String) -> MarkdownResponseDiagramNode {
        nodes[id] ?? MarkdownResponseDiagramNode(id: id, label: id, shape: .process)
    }
}

struct MarkdownResponseDiagramNode: Identifiable {
    let id: String
    let label: String
    let shape: Shape

    enum Shape {
        case process
        case decision
        case terminator
    }
}

struct MarkdownResponseFlowchartEdge: Identifiable {
    let id: Int
    let fromID: String
    let toID: String
    let label: String?
    let style: Style

    enum Style {
        case normal
        case dotted
        case thick
        case open
    }

    var symbolText: String {
        switch style {
        case .normal:
            return "->"
        case .dotted:
            return ".>"
        case .thick:
            return "=>"
        case .open:
            return "--"
        }
    }
}

struct MarkdownResponseSequenceDiagram {
    let participants: [String]
    let messages: [MarkdownResponseSequenceMessage]
}

struct MarkdownResponseSequenceMessage: Identifiable {
    let id: Int
    let from: String
    let to: String
    let text: String
    let isDashed: Bool

    var arrowText: String {
        isDashed ? "-->" : "->"
    }
}

struct MarkdownResponsePieDiagram {
    let title: String?
    let slices: [MarkdownResponsePieSlice]
}

struct MarkdownResponsePieSlice: Identifiable {
    let id: Int
    let label: String
    let value: Double
}

enum MarkdownDiagramParser {
    static func parse(language: String?, sourceText: String) -> MarkdownResponseDiagram? {
        let normalizedLanguage = language?
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map(String.init)
        let diagramLanguage = normalizedLanguage ?? "mermaid"
        let firstMeaningfulLine = meaningfulLines(in: sourceText).first ?? ""
        let lowercasedFirstLine = firstMeaningfulLine.lowercased()
        let isMermaidSource = diagramLanguage == "mermaid"
            || lowercasedFirstLine.hasPrefix("flowchart")
            || lowercasedFirstLine.hasPrefix("graph")
            || lowercasedFirstLine.hasPrefix("sequencediagram")
            || lowercasedFirstLine.hasPrefix("pie")
        let isDiagramLanguage = isMermaidSource
            || diagramLanguage == "dot"
            || diagramLanguage == "graphviz"
            || diagramLanguage == "plantuml"

        guard isDiagramLanguage else { return nil }

        if lowercasedFirstLine.hasPrefix("flowchart") || lowercasedFirstLine.hasPrefix("graph") {
            if let flowchart = parseFlowchart(sourceText: sourceText) {
                return MarkdownResponseDiagram(
                    language: "mermaid",
                    title: nil,
                    kind: .flowchart(flowchart)
                )
            }
        }

        if lowercasedFirstLine.hasPrefix("sequencediagram") {
            if let sequenceDiagram = parseSequenceDiagram(sourceText: sourceText) {
                return MarkdownResponseDiagram(
                    language: "mermaid",
                    title: nil,
                    kind: .sequence(sequenceDiagram)
                )
            }
        }

        if lowercasedFirstLine.hasPrefix("pie") {
            if let pieDiagram = parsePieDiagram(sourceText: sourceText) {
                return MarkdownResponseDiagram(
                    language: "mermaid",
                    title: pieDiagram.title,
                    kind: .pie(pieDiagram)
                )
            }
        }

        return MarkdownResponseDiagram(
            language: diagramLanguage,
            title: inferredTitle(from: sourceText),
            kind: .sourceFallback(language: diagramLanguage, sourceText: sourceText)
        )
    }

    private static func parseFlowchart(sourceText: String) -> MarkdownResponseFlowchart? {
        let statements = mermaidStatements(in: sourceText)
        guard let declaration = statements.first else { return nil }
        let declarationParts = declaration.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let direction = declarationParts.dropFirst().first?.uppercased() ?? "TD"

        var nodes: [String: MarkdownResponseDiagramNode] = [:]
        var edges: [MarkdownResponseFlowchartEdge] = []

        for statement in statements.dropFirst() {
            if shouldSkipFlowchartStatement(statement) {
                continue
            }

            if let parsedEdges = parseFlowchartEdges(
                statement: statement,
                startingEdgeID: edges.count
            ) {
                for parsedEdge in parsedEdges.edges {
                    edges.append(parsedEdge)
                }
                for node in parsedEdges.nodes {
                    nodes[node.id] = node
                }
                continue
            }

            if let node = parseNodeReference(statement), node.label != node.id {
                nodes[node.id] = node
            }
        }

        guard !edges.isEmpty || !nodes.isEmpty else { return nil }
        return MarkdownResponseFlowchart(direction: direction, nodes: nodes, edges: edges)
    }

    private static func parseSequenceDiagram(sourceText: String) -> MarkdownResponseSequenceDiagram? {
        let lines = meaningfulLines(in: sourceText)
        var participantAliases: [String: String] = [:]
        var orderedParticipants: [String] = []
        var messages: [MarkdownResponseSequenceMessage] = []

        for line in lines.dropFirst() {
            let lowercasedLine = line.lowercased()
            if lowercasedLine.hasPrefix("title ")
                || lowercasedLine.hasPrefix("note ")
                || lowercasedLine.hasPrefix("activate ")
                || lowercasedLine.hasPrefix("deactivate ")
                || lowercasedLine == "loop"
                || lowercasedLine == "end" {
                continue
            }

            if lowercasedLine.hasPrefix("participant ") || lowercasedLine.hasPrefix("actor ") {
                let declarationText = line
                    .replacingOccurrences(of: #"^(participant|actor)\s+"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                let aliasParts = declarationText.components(separatedBy: " as ")
                let participantID = cleanupDiagramLabel(aliasParts.first ?? declarationText)
                let displayName = cleanupDiagramLabel(aliasParts.count > 1 ? aliasParts[1] : participantID)
                if !participantID.isEmpty {
                    participantAliases[participantID] = displayName
                    appendUnique(displayName, to: &orderedParticipants)
                }
                continue
            }

            guard let parsedMessage = parseSequenceMessage(
                line: line,
                messageID: messages.count,
                participantAliases: participantAliases
            ) else {
                continue
            }

            messages.append(parsedMessage)
            appendUnique(parsedMessage.from, to: &orderedParticipants)
            appendUnique(parsedMessage.to, to: &orderedParticipants)
        }

        guard !messages.isEmpty else { return nil }
        return MarkdownResponseSequenceDiagram(participants: orderedParticipants, messages: messages)
    }

    private static func parsePieDiagram(sourceText: String) -> MarkdownResponsePieDiagram? {
        let lines = meaningfulLines(in: sourceText)
        var title: String?
        var slices: [MarkdownResponsePieSlice] = []

        for line in lines.dropFirst() {
            let lowercasedLine = line.lowercased()
            if lowercasedLine.hasPrefix("title ") {
                title = cleanupDiagramLabel(String(line.dropFirst(6)))
                continue
            }

            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let label = cleanupDiagramLabel(String(line[..<colonIndex]))
            let valueText = String(line[line.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, let value = Double(valueText) else { continue }
            slices.append(MarkdownResponsePieSlice(id: slices.count, label: label, value: value))
        }

        guard !slices.isEmpty else { return nil }
        return MarkdownResponsePieDiagram(title: title, slices: slices)
    }

    private static func parseFlowchartEdges(
        statement: String,
        startingEdgeID: Int
    ) -> (edges: [MarkdownResponseFlowchartEdge], nodes: [MarkdownResponseDiagramNode])? {
        let edgeOperators: [(operatorText: String, style: MarkdownResponseFlowchartEdge.Style)] = [
            ("-.->", .dotted),
            ("==>", .thick),
            ("-->", .normal),
            ("--x", .normal),
            ("--o", .normal),
            ("---", .open)
        ]

        guard let matchedOperator = edgeOperators.first(where: { statement.contains($0.operatorText) }),
              let operatorRange = statement.range(of: matchedOperator.operatorText) else {
            return nil
        }

        let leftText = String(statement[..<operatorRange.lowerBound])
        var rightText = String(statement[operatorRange.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        var edgeLabel: String?
        if rightText.hasPrefix("|"),
           let closingLabelDelimiter = rightText.dropFirst().firstIndex(of: "|") {
            edgeLabel = cleanupDiagramLabel(String(rightText[rightText.index(after: rightText.startIndex)..<closingLabelDelimiter]))
            rightText = String(rightText[rightText.index(after: closingLabelDelimiter)...])
                .trimmingCharacters(in: .whitespaces)
        }

        guard let sourceNode = parseNodeReference(leftText) else { return nil }
        let targetTexts = rightText
            .split(separator: "&", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !targetTexts.isEmpty else { return nil }

        var edges: [MarkdownResponseFlowchartEdge] = []
        var nodes = [sourceNode]
        for targetText in targetTexts {
            guard let targetNode = parseNodeReference(targetText) else { continue }
            nodes.append(targetNode)
            edges.append(MarkdownResponseFlowchartEdge(
                id: startingEdgeID + edges.count,
                fromID: sourceNode.id,
                toID: targetNode.id,
                label: edgeLabel,
                style: matchedOperator.style
            ))
        }

        guard !edges.isEmpty else { return nil }
        return (edges, nodes)
    }

    private static func parseSequenceMessage(
        line: String,
        messageID: Int,
        participantAliases: [String: String]
    ) -> MarkdownResponseSequenceMessage? {
        let operators = ["-->>", "->>", "-->", "->", "--x", "-x"]
        guard let messageOperator = operators.first(where: { line.contains($0) }),
              let operatorRange = line.range(of: messageOperator) else {
            return nil
        }

        let fromID = cleanupDiagramLabel(String(line[..<operatorRange.lowerBound]))
        let targetAndMessageText = String(line[operatorRange.upperBound...])
        let targetAndMessageParts = targetAndMessageText.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let toID = cleanupDiagramLabel(String(targetAndMessageParts.first ?? ""))
        let messageText = targetAndMessageParts.count > 1
            ? cleanupDiagramLabel(String(targetAndMessageParts[1]))
            : ""

        guard !fromID.isEmpty, !toID.isEmpty else { return nil }
        return MarkdownResponseSequenceMessage(
            id: messageID,
            from: participantAliases[fromID] ?? fromID,
            to: participantAliases[toID] ?? toID,
            text: messageText,
            isDashed: messageOperator.hasPrefix("--")
        )
    }

    private static func parseNodeReference(_ rawText: String) -> MarkdownResponseDiagramNode? {
        let text = rawText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s*:::.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "; "))
        guard !text.isEmpty else { return nil }

        if let delimiterIndex = text.firstIndex(where: { $0 == "[" || $0 == "{" || $0 == "(" }) {
            let delimiter = text[delimiterIndex]
            let idText = cleanupNodeID(String(text[..<delimiterIndex]))
            let closingDelimiter: Character = delimiter == "[" ? "]" : (delimiter == "{" ? "}" : ")")
            let labelStartIndex = text.index(after: delimiterIndex)
            let labelEndIndex = text[labelStartIndex...].lastIndex(of: closingDelimiter) ?? text.endIndex
            var labelText = String(text[labelStartIndex..<labelEndIndex])
                .trimmingCharacters(in: .whitespaces)
            while labelText.count >= 2,
                  let firstCharacter = labelText.first,
                  let lastCharacter = labelText.last,
                  (firstCharacter == "(" && lastCharacter == ")")
                    || (firstCharacter == "[" && lastCharacter == "]")
                    || (firstCharacter == "{" && lastCharacter == "}") {
                labelText.removeFirst()
                labelText.removeLast()
                labelText = labelText.trimmingCharacters(in: .whitespaces)
            }
            labelText = cleanupDiagramLabel(labelText)

            let nodeID = idText.isEmpty ? cleanupNodeID(labelText) : idText
            guard !nodeID.isEmpty else { return nil }
            let shape: MarkdownResponseDiagramNode.Shape = delimiter == "{"
                ? .decision
                : (delimiter == "(" ? .terminator : .process)
            return MarkdownResponseDiagramNode(
                id: nodeID,
                label: labelText.isEmpty ? nodeID : labelText,
                shape: shape
            )
        }

        let nodeID = cleanupNodeID(text)
        guard !nodeID.isEmpty else { return nil }
        return MarkdownResponseDiagramNode(id: nodeID, label: nodeID, shape: .process)
    }

    private static func meaningfulLines(in sourceText: String) -> [String] {
        sourceText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .compactMap { rawLine in
                let lineWithoutComment = rawLine.components(separatedBy: "%%").first ?? rawLine
                let trimmedLine = lineWithoutComment.trimmingCharacters(in: .whitespaces)
                return trimmedLine.isEmpty ? nil : trimmedLine
            }
    }

    private static func mermaidStatements(in sourceText: String) -> [String] {
        meaningfulLines(in: sourceText)
            .flatMap { line in
                line.split(separator: ";", omittingEmptySubsequences: true)
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
            }
            .filter { !$0.isEmpty }
    }

    private static func shouldSkipFlowchartStatement(_ statement: String) -> Bool {
        let lowercasedStatement = statement.lowercased()
        return lowercasedStatement == "end"
            || lowercasedStatement.hasPrefix("subgraph ")
            || lowercasedStatement.hasPrefix("classdef ")
            || lowercasedStatement.hasPrefix("class ")
            || lowercasedStatement.hasPrefix("style ")
            || lowercasedStatement.hasPrefix("linkstyle ")
            || lowercasedStatement.hasPrefix("click ")
    }

    private static func cleanupNodeID(_ rawText: String) -> String {
        let cleanedText = cleanupDiagramLabel(rawText)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map(String.init) ?? ""
        return cleanedText.trimmingCharacters(in: CharacterSet(charactersIn: ";,"))
    }

    private static func cleanupDiagramLabel(_ rawText: String) -> String {
        var labelText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        labelText = labelText.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        return labelText
    }

    private static func inferredTitle(from sourceText: String) -> String? {
        for line in meaningfulLines(in: sourceText) {
            if line.lowercased().hasPrefix("title ") {
                return cleanupDiagramLabel(String(line.dropFirst(6)))
            }
        }
        return nil
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        guard !value.isEmpty, !values.contains(value) else { return }
        values.append(value)
    }
}

enum MarkdownResponseParser {
    static func parse(_ markdownText: String) -> [MarkdownResponseBlock] {
        let normalizedText = markdownText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedText.components(separatedBy: "\n")
        var blocks: [MarkdownResponseBlock] = []
        var currentLineIndex = 0

        while currentLineIndex < lines.count {
            let currentLine = lines[currentLineIndex]
            let currentTrimmedLine = currentLine.trimmingCharacters(in: .whitespaces)

            if currentTrimmedLine.isEmpty {
                currentLineIndex += 1
                continue
            }

            if let fencedCodeInfo = fencedCodeInfo(from: currentTrimmedLine) {
                let parsedCodeBlock = parseFencedCodeBlock(
                    lines: lines,
                    startIndex: currentLineIndex,
                    fenceDelimiter: fencedCodeInfo.fenceDelimiter,
                    language: fencedCodeInfo.language
                )
                if let diagram = MarkdownDiagramParser.parse(
                    language: fencedCodeInfo.language,
                    sourceText: parsedCodeBlock.codeText
                ) {
                    blocks.append(MarkdownResponseBlock(id: blocks.count, kind: .diagram(diagram)))
                    currentLineIndex = parsedCodeBlock.nextLineIndex
                    continue
                }
                blocks.append(MarkdownResponseBlock(
                    id: blocks.count,
                    kind: .fencedCode(language: fencedCodeInfo.language, codeText: parsedCodeBlock.codeText)
                ))
                currentLineIndex = parsedCodeBlock.nextLineIndex
                continue
            }

            if isMathBlockStart(currentTrimmedLine) {
                let parsedMathBlock = parseMathBlock(lines: lines, startIndex: currentLineIndex)
                blocks.append(MarkdownResponseBlock(
                    id: blocks.count,
                    kind: .mathBlock(parsedMathBlock.mathText)
                ))
                currentLineIndex = parsedMathBlock.nextLineIndex
                continue
            }

            if let table = parseTable(lines: lines, startIndex: currentLineIndex) {
                blocks.append(MarkdownResponseBlock(id: blocks.count, kind: .table(table.table)))
                currentLineIndex = table.nextLineIndex
                continue
            }

            if let heading = parseHeading(from: currentTrimmedLine) {
                blocks.append(MarkdownResponseBlock(
                    id: blocks.count,
                    kind: .heading(level: heading.level, text: heading.text)
                ))
                currentLineIndex += 1
                continue
            }

            if isHorizontalRule(currentTrimmedLine) {
                blocks.append(MarkdownResponseBlock(id: blocks.count, kind: .horizontalRule))
                currentLineIndex += 1
                continue
            }

            if parseUnorderedListLine(currentLine) != nil {
                let parsedList = parseUnorderedList(lines: lines, startIndex: currentLineIndex)
                blocks.append(MarkdownResponseBlock(id: blocks.count, kind: .unorderedList(parsedList.items)))
                currentLineIndex = parsedList.nextLineIndex
                continue
            }

            if parseOrderedListLine(currentLine) != nil {
                let parsedList = parseOrderedList(lines: lines, startIndex: currentLineIndex)
                blocks.append(MarkdownResponseBlock(id: blocks.count, kind: .orderedList(parsedList.items)))
                currentLineIndex = parsedList.nextLineIndex
                continue
            }

            if isBlockquoteLine(currentLine) {
                let parsedQuote = parseBlockquote(lines: lines, startIndex: currentLineIndex)
                blocks.append(MarkdownResponseBlock(id: blocks.count, kind: .blockquote(parsedQuote.quoteText)))
                currentLineIndex = parsedQuote.nextLineIndex
                continue
            }

            let parsedParagraph = parseParagraph(lines: lines, startIndex: currentLineIndex)
            blocks.append(MarkdownResponseBlock(id: blocks.count, kind: .paragraph(parsedParagraph.text)))
            currentLineIndex = parsedParagraph.nextLineIndex
        }

        if blocks.isEmpty {
            return [MarkdownResponseBlock(id: 0, kind: .paragraph(markdownText))]
        }

        return blocks
    }

    private static func fencedCodeInfo(from trimmedLine: String) -> (fenceDelimiter: String, language: String?)? {
        for fenceDelimiter in ["```", "~~~"] where trimmedLine.hasPrefix(fenceDelimiter) {
            let languageText = String(trimmedLine.dropFirst(fenceDelimiter.count))
                .trimmingCharacters(in: .whitespaces)
            return (fenceDelimiter, languageText.isEmpty ? nil : languageText)
        }
        return nil
    }

    private static func parseFencedCodeBlock(
        lines: [String],
        startIndex: Int,
        fenceDelimiter: String,
        language: String?
    ) -> (codeText: String, nextLineIndex: Int) {
        var codeLines: [String] = []
        var currentLineIndex = startIndex + 1

        while currentLineIndex < lines.count {
            let trimmedLine = lines[currentLineIndex].trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix(fenceDelimiter) {
                return (codeLines.joined(separator: "\n"), currentLineIndex + 1)
            }
            codeLines.append(lines[currentLineIndex])
            currentLineIndex += 1
        }

        return (codeLines.joined(separator: "\n"), currentLineIndex)
    }

    private static func isMathBlockStart(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("$$") || trimmedLine.hasPrefix(#"\["#)
    }

    private static func parseMathBlock(lines: [String], startIndex: Int) -> (mathText: String, nextLineIndex: Int) {
        let startLine = lines[startIndex].trimmingCharacters(in: .whitespaces)

        if startLine.hasPrefix("$$") {
            return parseDelimitedMathBlock(
                lines: lines,
                startIndex: startIndex,
                openingDelimiter: "$$",
                closingDelimiter: "$$"
            )
        }

        return parseDelimitedMathBlock(
            lines: lines,
            startIndex: startIndex,
            openingDelimiter: #"\["#,
            closingDelimiter: #"\]"#
        )
    }

    private static func parseDelimitedMathBlock(
        lines: [String],
        startIndex: Int,
        openingDelimiter: String,
        closingDelimiter: String
    ) -> (mathText: String, nextLineIndex: Int) {
        let startLine = lines[startIndex].trimmingCharacters(in: .whitespaces)
        let contentAfterOpeningDelimiter = String(startLine.dropFirst(openingDelimiter.count))

        if let inlineClosingRange = contentAfterOpeningDelimiter.range(of: closingDelimiter) {
            let inlineMathText = String(contentAfterOpeningDelimiter[..<inlineClosingRange.lowerBound])
            return (inlineMathText.trimmingCharacters(in: .whitespacesAndNewlines), startIndex + 1)
        }

        var mathLines: [String] = []
        if !contentAfterOpeningDelimiter.trimmingCharacters(in: .whitespaces).isEmpty {
            mathLines.append(contentAfterOpeningDelimiter)
        }

        var currentLineIndex = startIndex + 1
        while currentLineIndex < lines.count {
            let currentLine = lines[currentLineIndex]
            if let closingRange = currentLine.range(of: closingDelimiter) {
                let contentBeforeClosingDelimiter = String(currentLine[..<closingRange.lowerBound])
                if !contentBeforeClosingDelimiter.trimmingCharacters(in: .whitespaces).isEmpty {
                    mathLines.append(contentBeforeClosingDelimiter)
                }
                return (mathLines.joined(separator: "\n"), currentLineIndex + 1)
            }
            mathLines.append(currentLine)
            currentLineIndex += 1
        }

        return (mathLines.joined(separator: "\n"), currentLineIndex)
    }

    private static func parseTable(
        lines: [String],
        startIndex: Int
    ) -> (table: MarkdownResponseTable, nextLineIndex: Int)? {
        guard startIndex + 1 < lines.count,
              lineLooksLikeTableRow(lines[startIndex]),
              lineLooksLikeTableSeparator(lines[startIndex + 1]) else {
            return nil
        }

        let headers = parseTableRow(lines[startIndex])
        var rows: [[String]] = []
        var currentLineIndex = startIndex + 2

        while currentLineIndex < lines.count {
            let currentLine = lines[currentLineIndex]
            let trimmedLine = currentLine.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty || !lineLooksLikeTableRow(currentLine) {
                break
            }
            rows.append(parseTableRow(currentLine))
            currentLineIndex += 1
        }

        return (MarkdownResponseTable(headers: headers, rows: rows), currentLineIndex)
    }

    private static func lineLooksLikeTableRow(_ line: String) -> Bool {
        line.contains("|") && parseTableRow(line).count >= 2
    }

    private static func lineLooksLikeTableSeparator(_ line: String) -> Bool {
        let cells = parseTableRow(line)
        guard cells.count >= 2 else { return false }

        return cells.allSatisfy { cellText in
            let normalizedCellText = cellText
                .replacingOccurrences(of: ":", with: "")
                .trimmingCharacters(in: .whitespaces)
            return normalizedCellText.count >= 3 && normalizedCellText.allSatisfy { character in
                character == "-"
            }
        }
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var tableLine = line.trimmingCharacters(in: .whitespaces)
        if tableLine.hasPrefix("|") {
            tableLine.removeFirst()
        }
        if tableLine.hasSuffix("|") {
            tableLine.removeLast()
        }
        return tableLine
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { cellText in
                String(cellText).trimmingCharacters(in: .whitespaces)
            }
    }

    private static func parseHeading(from trimmedLine: String) -> (level: Int, text: String)? {
        guard trimmedLine.hasPrefix("#") else { return nil }

        var headingLevel = 0
        var currentIndex = trimmedLine.startIndex
        while currentIndex < trimmedLine.endIndex,
              trimmedLine[currentIndex] == "#",
              headingLevel < 6 {
            headingLevel += 1
            currentIndex = trimmedLine.index(after: currentIndex)
        }

        guard currentIndex < trimmedLine.endIndex,
              trimmedLine[currentIndex] == " " else {
            return nil
        }

        let headingText = String(trimmedLine[currentIndex...])
            .trimmingCharacters(in: .whitespaces)
        guard !headingText.isEmpty else { return nil }
        return (headingLevel, headingText)
    }

    private static func isHorizontalRule(_ trimmedLine: String) -> Bool {
        let compactLine = trimmedLine.replacingOccurrences(of: " ", with: "")
        guard compactLine.count >= 3,
              let firstCharacter = compactLine.first,
              firstCharacter == "-" || firstCharacter == "*" || firstCharacter == "_" else {
            return false
        }

        return compactLine.allSatisfy { character in
            character == firstCharacter
        }
    }

    private static func parseUnorderedList(
        lines: [String],
        startIndex: Int
    ) -> (items: [MarkdownResponseListItem], nextLineIndex: Int) {
        var listItems: [MarkdownResponseListItem] = []
        var currentLineIndex = startIndex

        while currentLineIndex < lines.count,
              let parsedItem = parseUnorderedListLine(lines[currentLineIndex]) {
            listItems.append(MarkdownResponseListItem(
                id: listItems.count,
                markerText: nil,
                taskState: parsedItem.taskState,
                text: parsedItem.text
            ))
            currentLineIndex += 1
        }

        return (listItems, currentLineIndex)
    }

    private static func parseUnorderedListLine(_ line: String) -> (taskState: MarkdownResponseTaskState?, text: String)? {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard trimmedLine.count >= 2 else { return nil }

        let validMarkers = ["- ", "* ", "+ "]
        guard let marker = validMarkers.first(where: { trimmedLine.hasPrefix($0) }) else {
            return nil
        }

        var itemText = String(trimmedLine.dropFirst(marker.count))
            .trimmingCharacters(in: .whitespaces)
        var taskState: MarkdownResponseTaskState?

        if itemText.hasPrefix("[ ] ") {
            taskState = .unchecked
            itemText = String(itemText.dropFirst(4))
        } else if itemText.hasPrefix("[x] ") || itemText.hasPrefix("[X] ") {
            taskState = .checked
            itemText = String(itemText.dropFirst(4))
        }

        return (taskState, itemText)
    }

    private static func parseOrderedList(
        lines: [String],
        startIndex: Int
    ) -> (items: [MarkdownResponseListItem], nextLineIndex: Int) {
        var listItems: [MarkdownResponseListItem] = []
        var currentLineIndex = startIndex

        while currentLineIndex < lines.count,
              let parsedItem = parseOrderedListLine(lines[currentLineIndex]) {
            listItems.append(MarkdownResponseListItem(
                id: listItems.count,
                markerText: parsedItem.markerText,
                taskState: nil,
                text: parsedItem.text
            ))
            currentLineIndex += 1
        }

        return (listItems, currentLineIndex)
    }

    private static func parseOrderedListLine(_ line: String) -> (markerText: String, text: String)? {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        var currentIndex = trimmedLine.startIndex
        var digitText = ""

        while currentIndex < trimmedLine.endIndex,
              trimmedLine[currentIndex].isNumber {
            digitText.append(trimmedLine[currentIndex])
            currentIndex = trimmedLine.index(after: currentIndex)
        }

        guard !digitText.isEmpty,
              currentIndex < trimmedLine.endIndex,
              trimmedLine[currentIndex] == "." || trimmedLine[currentIndex] == ")" else {
            return nil
        }

        let markerCharacter = trimmedLine[currentIndex]
        currentIndex = trimmedLine.index(after: currentIndex)

        guard currentIndex < trimmedLine.endIndex,
              trimmedLine[currentIndex] == " " else {
            return nil
        }

        let itemText = String(trimmedLine[currentIndex...])
            .trimmingCharacters(in: .whitespaces)
        guard !itemText.isEmpty else { return nil }

        return ("\(digitText)\(markerCharacter)", itemText)
    }

    private static func isBlockquoteLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    private static func parseBlockquote(
        lines: [String],
        startIndex: Int
    ) -> (quoteText: String, nextLineIndex: Int) {
        var quoteLines: [String] = []
        var currentLineIndex = startIndex

        while currentLineIndex < lines.count,
              isBlockquoteLine(lines[currentLineIndex]) {
            var trimmedLine = lines[currentLineIndex].trimmingCharacters(in: .whitespaces)
            trimmedLine.removeFirst()
            if trimmedLine.hasPrefix(" ") {
                trimmedLine.removeFirst()
            }
            quoteLines.append(trimmedLine)
            currentLineIndex += 1
        }

        return (quoteLines.joined(separator: "\n"), currentLineIndex)
    }

    private static func parseParagraph(
        lines: [String],
        startIndex: Int
    ) -> (text: String, nextLineIndex: Int) {
        var paragraphLines: [String] = []
        var currentLineIndex = startIndex

        while currentLineIndex < lines.count {
            let currentLine = lines[currentLineIndex]
            let currentTrimmedLine = currentLine.trimmingCharacters(in: .whitespaces)

            if currentTrimmedLine.isEmpty || startsNonParagraphBlock(lines: lines, index: currentLineIndex) {
                break
            }

            paragraphLines.append(currentLine)
            currentLineIndex += 1
        }

        return (
            paragraphLines
                .map { line in line.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n"),
            currentLineIndex
        )
    }

    private static func startsNonParagraphBlock(lines: [String], index: Int) -> Bool {
        let trimmedLine = lines[index].trimmingCharacters(in: .whitespaces)

        return fencedCodeInfo(from: trimmedLine) != nil
            || isMathBlockStart(trimmedLine)
            || parseTable(lines: lines, startIndex: index) != nil
            || parseHeading(from: trimmedLine) != nil
            || isHorizontalRule(trimmedLine)
            || parseUnorderedListLine(lines[index]) != nil
            || parseOrderedListLine(lines[index]) != nil
            || isBlockquoteLine(lines[index])
    }
}

enum MathSyntaxFormatter {
    static func replacingInlineMathDelimiters(in text: String) -> String {
        var renderedText = ""
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            if text[currentIndex] == "\\",
               let parsedParenthesizedMath = parseInlineMath(
                    in: text,
                    startIndex: currentIndex,
                    openingDelimiter: #"\("#,
                    closingDelimiter: #"\)"#
               ) {
                renderedText += displayText(from: parsedParenthesizedMath.mathText)
                currentIndex = parsedParenthesizedMath.nextIndex
                continue
            }

            if text[currentIndex] == "$",
               !hasPrefix("$$", in: text, at: currentIndex),
               !isEscapedDollar(in: text, at: currentIndex),
               let parsedDollarMath = parseInlineMath(
                    in: text,
                    startIndex: currentIndex,
                    openingDelimiter: "$",
                    closingDelimiter: "$"
               ) {
                renderedText += displayText(from: parsedDollarMath.mathText)
                currentIndex = parsedDollarMath.nextIndex
                continue
            }

            renderedText.append(text[currentIndex])
            currentIndex = text.index(after: currentIndex)
        }

        return replacingLooseMathSyntax(in: renderedText)
    }

    static func replacingAllMathDelimiters(in text: String) -> String {
        let textWithDisplayMath = replacingDisplayMathDelimiters(in: text)
        return replacingInlineMathDelimiters(in: textWithDisplayMath)
    }

    static func displayText(from mathText: String) -> String {
        var displayText = mathText.trimmingCharacters(in: .whitespacesAndNewlines)
        displayText = replaceCommandWithTwoBracedArguments(
            in: displayText,
            command: #"\frac"#,
            render: { numerator, denominator in
                "\(Self.displayText(from: numerator))⁄\(Self.displayText(from: denominator))"
            }
        )
        displayText = replaceCommandWithOneBracedArgument(
            in: displayText,
            command: #"\sqrt"#,
            render: { radicand in
                "√(\(Self.displayText(from: radicand)))"
            }
        )
        displayText = replaceTextStyleCommands(in: displayText)
        displayText = replaceKnownCommands(in: displayText)
        displayText = applyingScriptMarkers(in: displayText)
        displayText = cleanupRemainingTeXSyntax(in: displayText)
        return displayText
    }

    private static func replacingLooseMathSyntax(in text: String) -> String {
        var renderedText = replaceTextStyleCommands(in: text)
        renderedText = replaceKnownCommands(in: renderedText)
        renderedText = applyingBracedScriptMarkers(in: renderedText)
        renderedText = applyingParenthesizedNumericScripts(in: renderedText)
        renderedText = renderedText.replacingOccurrences(
            of: #"\\([a-zA-Z]+)"#,
            with: "$1",
            options: .regularExpression
        )
        return renderedText
    }

    private static func replacingDisplayMathDelimiters(in text: String) -> String {
        var renderedText = ""
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            if hasPrefix("$$", in: text, at: currentIndex),
               let parsedMath = parseInlineMath(
                    in: text,
                    startIndex: currentIndex,
                    openingDelimiter: "$$",
                    closingDelimiter: "$$"
               ) {
                renderedText += displayText(from: parsedMath.mathText)
                currentIndex = parsedMath.nextIndex
                continue
            }

            if hasPrefix(#"\["#, in: text, at: currentIndex),
               let parsedMath = parseInlineMath(
                    in: text,
                    startIndex: currentIndex,
                    openingDelimiter: #"\["#,
                    closingDelimiter: #"\]"#
               ) {
                renderedText += displayText(from: parsedMath.mathText)
                currentIndex = parsedMath.nextIndex
                continue
            }

            renderedText.append(text[currentIndex])
            currentIndex = text.index(after: currentIndex)
        }

        return renderedText
    }

    private static func parseInlineMath(
        in text: String,
        startIndex: String.Index,
        openingDelimiter: String,
        closingDelimiter: String
    ) -> (mathText: String, nextIndex: String.Index)? {
        guard hasPrefix(openingDelimiter, in: text, at: startIndex) else { return nil }

        let contentStartIndex = text.index(startIndex, offsetBy: openingDelimiter.count)
        guard contentStartIndex < text.endIndex else { return nil }

        var searchIndex = contentStartIndex
        while searchIndex < text.endIndex {
            if hasPrefix(closingDelimiter, in: text, at: searchIndex),
               !isEscapedDollar(in: text, at: searchIndex) {
                let mathText = String(text[contentStartIndex..<searchIndex])
                guard !mathText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                let nextIndex = text.index(searchIndex, offsetBy: closingDelimiter.count)
                return (mathText, nextIndex)
            }
            searchIndex = text.index(after: searchIndex)
        }

        return nil
    }

    private static func replaceKnownCommands(in mathText: String) -> String {
        var renderedText = mathText
        let commandReplacements: [String: String] = [
            #"\lceil"#: "⌈",
            #"\rceil"#: "⌉",
            #"\lfloor"#: "⌊",
            #"\rfloor"#: "⌋",
            #"\rightarrow"#: "→",
            #"\leftarrow"#: "←",
            #"\Rightarrow"#: "⇒",
            #"\Leftarrow"#: "⇐",
            #"\leftrightarrow"#: "↔",
            #"\Leftrightarrow"#: "⇔",
            #"\alpha"#: "α",
            #"\beta"#: "β",
            #"\gamma"#: "γ",
            #"\delta"#: "δ",
            #"\epsilon"#: "ε",
            #"\varepsilon"#: "ε",
            #"\zeta"#: "ζ",
            #"\eta"#: "η",
            #"\theta"#: "θ",
            #"\vartheta"#: "ϑ",
            #"\iota"#: "ι",
            #"\kappa"#: "κ",
            #"\lambda"#: "λ",
            #"\mu"#: "μ",
            #"\nu"#: "ν",
            #"\xi"#: "ξ",
            #"\pi"#: "π",
            #"\rho"#: "ρ",
            #"\sigma"#: "σ",
            #"\tau"#: "τ",
            #"\upsilon"#: "υ",
            #"\phi"#: "φ",
            #"\varphi"#: "φ",
            #"\chi"#: "χ",
            #"\psi"#: "ψ",
            #"\omega"#: "ω",
            #"\Gamma"#: "Γ",
            #"\Delta"#: "Δ",
            #"\Theta"#: "Θ",
            #"\Lambda"#: "Λ",
            #"\Xi"#: "Ξ",
            #"\Pi"#: "Π",
            #"\Sigma"#: "Σ",
            #"\Phi"#: "Φ",
            #"\Psi"#: "Ψ",
            #"\Omega"#: "Ω",
            #"\times"#: "×",
            #"\cdot"#: "·",
            #"\pm"#: "±",
            #"\mp"#: "∓",
            #"\leq"#: "≤",
            #"\le"#: "≤",
            #"\geq"#: "≥",
            #"\ge"#: "≥",
            #"\neq"#: "≠",
            #"\approx"#: "≈",
            #"\equiv"#: "≡",
            #"\propto"#: "∝",
            #"\infty"#: "∞",
            #"\partial"#: "∂",
            #"\nabla"#: "∇",
            #"\sum"#: "∑",
            #"\prod"#: "∏",
            #"\int"#: "∫",
            #"\oint"#: "∮",
            #"\in"#: "∈",
            #"\notin"#: "∉",
            #"\subseteq"#: "⊆",
            #"\subset"#: "⊂",
            #"\supseteq"#: "⊇",
            #"\supset"#: "⊃",
            #"\cup"#: "∪",
            #"\cap"#: "∩",
            #"\land"#: "∧",
            #"\lor"#: "∨",
            #"\neg"#: "¬",
            #"\forall"#: "∀",
            #"\exists"#: "∃",
            #"\emptyset"#: "∅",
            #"\degree"#: "°",
            #"\ldots"#: "…",
            #"\cdots"#: "⋯",
            #"\dots"#: "…",
            #"\oplus"#: "⊕",
            #"\otimes"#: "⊗",
            #"\ominus"#: "⊖",
            #"\mid"#: "|",
            #"\vert"#: "|",
            #"\sim"#: "~",
            #"\simeq"#: "≃",
            #"\log"#: "log",
            #"\ln"#: "ln",
            #"\exp"#: "exp",
            #"\sin"#: "sin",
            #"\cos"#: "cos",
            #"\tan"#: "tan",
            #"\min"#: "min",
            #"\max"#: "max",
            #"\to"#: "→"
        ]

        for (commandText, replacementText) in commandReplacements.sorted(by: { $0.key.count > $1.key.count }) {
            renderedText = renderedText.replacingOccurrences(of: commandText, with: replacementText)
        }

        return renderedText
    }

    private static func replaceTextStyleCommands(in text: String) -> String {
        let styleCommands = [
            #"\operatorname"#,
            #"\mathrm"#,
            #"\mathbf"#,
            #"\mathit"#,
            #"\mathsf"#,
            #"\mathtt"#,
            #"\mathbb"#,
            #"\text"#
        ]

        var renderedText = text
        for styleCommand in styleCommands {
            renderedText = replaceCommandWithOneBracedArgument(
                in: renderedText,
                command: styleCommand,
                render: { argumentText in argumentText }
            )
        }
        return renderedText
    }

    private static func applyingBracedScriptMarkers(in text: String) -> String {
        var renderedText = ""
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            let currentCharacter = text[currentIndex]
            guard currentCharacter == "^" || currentCharacter == "_" else {
                renderedText.append(currentCharacter)
                currentIndex = text.index(after: currentIndex)
                continue
            }

            let argumentStartIndex = text.index(after: currentIndex)
            guard argumentStartIndex < text.endIndex,
                  text[argumentStartIndex] == "{",
                  let argument = parseBracedArgument(in: text, openingBraceIndex: argumentStartIndex) else {
                renderedText.append(currentCharacter)
                currentIndex = argumentStartIndex
                continue
            }

            renderedText += scriptText(argument.argumentText, isSuperscript: currentCharacter == "^")
            currentIndex = argument.nextIndex
        }

        return renderedText
    }

    private static func applyingParenthesizedNumericScripts(in text: String) -> String {
        var renderedText = ""
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            let currentCharacter = text[currentIndex]
            guard currentCharacter == "^" || currentCharacter == "_" else {
                renderedText.append(currentCharacter)
                currentIndex = text.index(after: currentIndex)
                continue
            }

            let argumentStartIndex = text.index(after: currentIndex)
            guard argumentStartIndex < text.endIndex,
                  text[argumentStartIndex] == "(",
                  let closingParenthesisIndex = text[argumentStartIndex...].firstIndex(of: ")") else {
                renderedText.append(currentCharacter)
                currentIndex = argumentStartIndex
                continue
            }

            let argumentEndIndex = text.index(after: closingParenthesisIndex)
            let argumentText = String(text[argumentStartIndex..<argumentEndIndex])
            let isNumericArgument = argumentText.dropFirst().dropLast().allSatisfy { character in
                character.isNumber || character == "." || character == "," || character == "+" || character == "-"
            }

            guard isNumericArgument else {
                renderedText.append(currentCharacter)
                currentIndex = argumentStartIndex
                continue
            }

            renderedText += scriptText(argumentText, isSuperscript: currentCharacter == "^")
            currentIndex = argumentEndIndex
        }

        return renderedText
    }

    private static func replaceCommandWithTwoBracedArguments(
        in text: String,
        command: String,
        render: (String, String) -> String
    ) -> String {
        var renderedText = ""
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            guard hasPrefix(command, in: text, at: currentIndex) else {
                renderedText.append(text[currentIndex])
                currentIndex = text.index(after: currentIndex)
                continue
            }

            var argumentStartIndex = text.index(currentIndex, offsetBy: command.count)
            skipWhitespace(in: text, from: &argumentStartIndex)
            guard let firstArgument = parseBracedArgument(in: text, openingBraceIndex: argumentStartIndex) else {
                renderedText += command
                currentIndex = argumentStartIndex
                continue
            }

            argumentStartIndex = firstArgument.nextIndex
            skipWhitespace(in: text, from: &argumentStartIndex)
            guard let secondArgument = parseBracedArgument(in: text, openingBraceIndex: argumentStartIndex) else {
                renderedText += command
                currentIndex = firstArgument.nextIndex
                continue
            }

            renderedText += render(firstArgument.argumentText, secondArgument.argumentText)
            currentIndex = secondArgument.nextIndex
        }

        return renderedText
    }

    private static func replaceCommandWithOneBracedArgument(
        in text: String,
        command: String,
        render: (String) -> String
    ) -> String {
        var renderedText = ""
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            guard hasPrefix(command, in: text, at: currentIndex) else {
                renderedText.append(text[currentIndex])
                currentIndex = text.index(after: currentIndex)
                continue
            }

            var argumentStartIndex = text.index(currentIndex, offsetBy: command.count)
            skipWhitespace(in: text, from: &argumentStartIndex)
            guard let argument = parseBracedArgument(in: text, openingBraceIndex: argumentStartIndex) else {
                renderedText += command
                currentIndex = argumentStartIndex
                continue
            }

            renderedText += render(argument.argumentText)
            currentIndex = argument.nextIndex
        }

        return renderedText
    }

    private static func applyingScriptMarkers(in text: String) -> String {
        var renderedText = ""
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            let currentCharacter = text[currentIndex]
            guard currentCharacter == "^" || currentCharacter == "_" else {
                renderedText.append(currentCharacter)
                currentIndex = text.index(after: currentIndex)
                continue
            }

            let isSuperscript = currentCharacter == "^"
            let argumentStartIndex = text.index(after: currentIndex)
            guard argumentStartIndex < text.endIndex else {
                renderedText.append(currentCharacter)
                currentIndex = argumentStartIndex
                continue
            }

            let argumentText: String
            let nextIndex: String.Index
            if text[argumentStartIndex] == "{",
               let argument = parseBracedArgument(in: text, openingBraceIndex: argumentStartIndex) {
                argumentText = argument.argumentText
                nextIndex = argument.nextIndex
            } else {
                argumentText = String(text[argumentStartIndex])
                nextIndex = text.index(after: argumentStartIndex)
            }

            renderedText += scriptText(argumentText, isSuperscript: isSuperscript)
            currentIndex = nextIndex
        }

        return renderedText
    }

    private static func scriptText(_ text: String, isSuperscript: Bool) -> String {
        let scriptMap = isSuperscript ? superscriptCharacters : subscriptCharacters
        let mappedCharacters = text.map { character in
            scriptMap[character]
        }

        if mappedCharacters.allSatisfy({ $0 != nil }) {
            return mappedCharacters.compactMap { $0 }.joined()
        }

        return isSuperscript ? "^(\(text))" : "_(\(text))"
    }

    private static func cleanupRemainingTeXSyntax(in text: String) -> String {
        var renderedText = text
        let cleanupReplacements: [(String, String)] = [
            (#"\left"#, ""),
            (#"\right"#, ""),
            (#"\,"#, " "),
            (#"\;"#, " "),
            (#"\:"#, " "),
            (#"\!"#, ""),
            (#"\quad"#, "  "),
            (#"\qquad"#, "    "),
            ("~", " "),
            ("{", ""),
            ("}", "")
        ]

        for (targetText, replacementText) in cleanupReplacements {
            renderedText = renderedText.replacingOccurrences(of: targetText, with: replacementText)
        }

        renderedText = renderedText.replacingOccurrences(
            of: #"\\([()\[\],.;:+\-*/=|])"#,
            with: "$1",
            options: .regularExpression
        )
        renderedText = renderedText.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )

        return renderedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseBracedArgument(
        in text: String,
        openingBraceIndex: String.Index
    ) -> (argumentText: String, nextIndex: String.Index)? {
        guard openingBraceIndex < text.endIndex,
              text[openingBraceIndex] == "{" else {
            return nil
        }

        var nestingDepth = 0
        var currentIndex = openingBraceIndex
        var argumentStartIndex: String.Index?

        while currentIndex < text.endIndex {
            if text[currentIndex] == "{" {
                nestingDepth += 1
                if nestingDepth == 1 {
                    argumentStartIndex = text.index(after: currentIndex)
                }
            } else if text[currentIndex] == "}" {
                nestingDepth -= 1
                if nestingDepth == 0 {
                    let resolvedArgumentStartIndex = argumentStartIndex ?? text.index(after: openingBraceIndex)
                    let argumentText = String(text[resolvedArgumentStartIndex..<currentIndex])
                    return (argumentText, text.index(after: currentIndex))
                }
            }

            currentIndex = text.index(after: currentIndex)
        }

        return nil
    }

    private static func skipWhitespace(in text: String, from index: inout String.Index) {
        while index < text.endIndex,
              text[index].isWhitespace {
            index = text.index(after: index)
        }
    }

    private static func hasPrefix(_ prefix: String, in text: String, at index: String.Index) -> Bool {
        guard let endIndex = text.index(index, offsetBy: prefix.count, limitedBy: text.endIndex) else {
            return false
        }
        return text[index..<endIndex] == prefix
    }

    private static func isEscapedDollar(in text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else { return false }
        let previousIndex = text.index(before: index)
        return text[previousIndex] == "\\"
    }

    private static let superscriptCharacters: [Character: String] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        ".": ".", ",": ",",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ",
        "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ",
        "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ",
        "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ",
        "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ"
    ]

    private static let subscriptCharacters: [Character: String] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        ".": ".", ",": ",",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ",
        "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
        "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ",
        "v": "ᵥ", "x": "ₓ"
    ]
}

enum ResponseSpeechTextFormatter {
    static func speechText(from responseText: String) -> String {
        var speechText = MathSyntaxFormatter.replacingAllMathDelimiters(in: responseText)

        speechText = speechText.replacingOccurrences(
            of: #"(?is)```(mermaid|graphviz|dot|plantuml)\n?(.*?)```"#,
            with: "diagram",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"(?is)~~~(mermaid|graphviz|dot|plantuml)\n?(.*?)~~~"#,
            with: "diagram",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"(?s)```[a-zA-Z0-9_-]*\n?(.*?)```"#,
            with: "$1",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"(?s)~~~[a-zA-Z0-9_-]*\n?(.*?)~~~"#,
            with: "$1",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"(?m)^\s{0,3}#{1,6}\s+"#,
            with: "",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"(?m)^\s{0,3}>\s?"#,
            with: "",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"(?m)^\s{0,3}[-*+]\s+\[[ xX]\]\s+"#,
            with: "",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"(?m)^\s{0,3}[-*+]\s+"#,
            with: "",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"(?m)^\s{0,3}\d+[.)]\s+"#,
            with: "",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"`([^`]+)`"#,
            with: "$1",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"\*\*([^*]+)\*\*"#,
            with: "$1",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"__([^_]+)__"#,
            with: "$1",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"\*([^*]+)\*"#,
            with: "$1",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"_([^_]+)_"#,
            with: "$1",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"!\[([^\]]*)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"(?m)^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$"#,
            with: "",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"(?m)^\s*[-*_]{3,}\s*$"#,
            with: "",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        speechText = speechText.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )

        return speechText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
