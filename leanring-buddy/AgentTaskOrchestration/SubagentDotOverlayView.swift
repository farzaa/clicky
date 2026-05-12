//
//  SubagentDotOverlayView.swift
//  leanring-buddy
//
//  Transparent SwiftUI dot stack for active and recent coding-agent tasks.
//

import SwiftUI

struct SubagentDotOverlayView: View {

    @ObservedObject var agentTaskManager: AgentTaskManager
    var onTaskSelected: (UUID) -> Void
    var onTaskDeleted: (AgentTask) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(agentTaskManager.visibleTasksForSubagentDots) { task in
                SubagentDotButton(
                    task: task,
                    dotColor: colorForTask(task),
                    onSelected: {
                        onTaskSelected(task.id)
                    },
                    onDeleted: {
                        onTaskDeleted(task)
                    }
                )
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 10)
        .padding(.trailing, 10)
        .background(Color.clear)
    }

    private func colorForTask(_ task: AgentTask) -> Color {
        let palette: [Color] = [
            Color(hex: "#34D399"),
            Color(hex: "#A78BFA"),
            Color(hex: "#F472B6"),
            Color(hex: "#FBBF24"),
            Color(hex: "#22D3EE"),
            Color(hex: "#FB7185"),
            Color(hex: "#4ADE80"),
            Color(hex: "#C084FC")
        ]
        let stableValue = task.id.uuidString.unicodeScalars.reduce(0) { runningValue, scalar in
            (runningValue + Int(scalar.value)) % palette.count
        }
        let stableIndex = stableValue % palette.count
        return palette[stableIndex]
    }
}

private struct SubagentDotButton: View {

    @ObservedObject var task: AgentTask
    let dotColor: Color
    let onSelected: () -> Void
    let onDeleted: () -> Void

    @State private var isPulsing: Bool = false
    @State private var isHovered: Bool = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: onSelected) {
                ZStack {
                    if !task.status.isTerminal {
                        Circle()
                            .stroke(dotColor.opacity(isPulsing ? 0.20 : 0.46), lineWidth: 6)
                            .frame(width: isPulsing ? 42 : 30, height: isPulsing ? 42 : 30)
                            .blur(radius: 0.5)
                    }

                    Circle()
                        .fill(fillColor)
                        .frame(width: isHovered ? 28 : 24, height: isHovered ? 28 : 24)
                        .shadow(color: fillColor.opacity(0.55), radius: task.status.isTerminal ? 4 : 9)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(isHovered ? 0.72 : 0.34), lineWidth: 1)
                        )

                    statusGlyph
                }
                .frame(width: 46, height: 46)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(task.brief.oneLineTitle)

            if isHovered {
                Button(action: onDeleted) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 15, height: 15)
                        .background(DS.Colors.destructive)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.55), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(task.status.isTerminal ? "Delete subagent" : "Cancel and delete subagent")
                .offset(x: -1, y: -1)
            }
        }
        .frame(width: 46, height: 46)
        .opacity(task.status == .cancelled ? 0.62 : 1.0)
        .animation(.spring(response: 0.18, dampingFraction: 0.68), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            guard !task.status.isTerminal else { return }
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }

    private var fillColor: Color {
        switch task.status {
        case .queued, .planning, .running:
            return dotColor
        case .completed:
            return DS.Colors.success
        case .failed:
            return DS.Colors.destructive
        case .cancelled:
            return DS.Colors.textTertiary
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch task.status {
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.black.opacity(0.72))
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.88))
        case .cancelled:
            Image(systemName: "minus")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.75))
        case .queued, .planning, .running:
            EmptyView()
        }
    }
}
