//
//  LearningPetSpriteView.swift
//  leanring-buddy
//
//  8x11 Pip sprite rendering for the cursor companion.
//

import AppKit
import SwiftUI

enum LearningPetAnimation: Hashable {
    case idle
    case runningRight
    case runningLeft
    case waving
    case jumping
    case failed
    case waiting
    case working
    case review
    case looking(directionIndex: Int)

    static let atlasColumnCount = 8
    static let atlasRowCount = 11
    static let atlasCellWidth = 192
    static let atlasCellHeight = 208

    var rowIndex: Int {
        switch self {
        case .idle: return 0
        case .runningRight: return 1
        case .runningLeft: return 2
        case .waving: return 3
        case .jumping: return 4
        case .failed: return 5
        case .waiting: return 6
        case .working: return 7
        case .review: return 8
        case .looking(let directionIndex): return directionIndex < 8 ? 9 : 10
        }
    }

    var frameCount: Int {
        switch self {
        case .idle: return 6
        case .runningRight, .runningLeft, .failed: return 8
        case .waving: return 4
        case .jumping: return 5
        case .waiting, .working, .review: return 6
        case .looking: return 1
        }
    }

    var frameDurations: [TimeInterval] {
        switch self {
        case .idle:
            return [0.28, 0.11, 0.11, 0.14, 0.14, 0.32]
        case .runningRight, .runningLeft:
            return [0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.22]
        case .waving:
            return [0.14, 0.14, 0.14, 0.28]
        case .jumping:
            return [0.14, 0.14, 0.14, 0.14, 0.28]
        case .failed:
            return [0.14, 0.14, 0.14, 0.14, 0.14, 0.14, 0.14, 0.24]
        case .waiting:
            return [0.15, 0.15, 0.15, 0.15, 0.15, 0.26]
        case .working:
            return [0.12, 0.12, 0.12, 0.12, 0.12, 0.22]
        case .review:
            return [0.15, 0.15, 0.15, 0.15, 0.15, 0.28]
        case .looking:
            return [1.0]
        }
    }

    var firstFrameColumn: Int {
        switch self {
        case .looking(let directionIndex):
            return min(max(directionIndex, 0), 15) % 8
        default:
            return 0
        }
    }

    var reducedMotionFrameColumn: Int {
        firstFrameColumn
    }

    var accessibilityDescription: String {
        switch self {
        case .idle: return "Pip the learning fox"
        case .runningRight, .runningLeft: return "Pip following the pointer"
        case .waving: return "Pip waving hello"
        case .jumping: return "Pip celebrating"
        case .failed: return "Pip asking for a grown-up's help"
        case .waiting: return "Pip listening"
        case .working: return "Pip thinking"
        case .review: return "Pip explaining"
        case .looking: return "Pip looking at the item being explained"
        }
    }

    func frameColumn(at date: Date, animationStartedAt: Date, reduceMotion: Bool) -> Int {
        if reduceMotion || frameCount == 1 {
            return reducedMotionFrameColumn
        }

        let elapsedSeconds = max(date.timeIntervalSince(animationStartedAt), 0)
        let loopDuration = frameDurations.reduce(0, +)
        var timeWithinLoop = elapsedSeconds.truncatingRemainder(dividingBy: loopDuration)

        for (frameIndex, frameDuration) in frameDurations.enumerated() {
            if timeWithinLoop < frameDuration {
                return firstFrameColumn + frameIndex
            }
            timeWithinLoop -= frameDuration
        }

        return firstFrameColumn + frameCount - 1
    }
}

enum LearningPetDirectionResolver {
    /// Converts a vector in SwiftUI screen coordinates into the v2 atlas's
    /// clockwise direction order, where 000 points up and 090 points right.
    static func directionIndex(toward vector: CGVector) -> Int? {
        guard hypot(vector.dx, vector.dy) >= 1 else { return nil }

        let clockwiseRadiansFromUp = atan2(vector.dx, -vector.dy)
        let clockwiseDegreesFromUp = clockwiseRadiansFromUp * 180 / .pi
        let normalizedDegrees = clockwiseDegreesFromUp < 0
            ? clockwiseDegreesFromUp + 360
            : clockwiseDegreesFromUp
        return Int((normalizedDegrees / 22.5).rounded()) % 16
    }

    static func lookingAnimation(toward vector: CGVector) -> LearningPetAnimation? {
        guard let directionIndex = directionIndex(toward: vector) else { return nil }
        return .looking(directionIndex: directionIndex)
    }
}

enum LearningPetPresentationResolver {
    /// Pip mirrors Clicky's existing state. The resolver is intentionally
    /// pure so the pet cannot introduce a second navigation lifecycle.
    static func animation(
        voiceState: CompanionVoiceState,
        navigationMode: BuddyNavigationMode,
        isMovingHorizontally: Bool,
        isMovingRight: Bool,
        pointingDirection: CGVector? = nil
    ) -> LearningPetAnimation {
        switch navigationMode {
        case .navigatingToTarget:
            return isMovingRight ? .runningRight : .runningLeft
        case .pointingAtTarget:
            if let pointingDirection,
               let lookingAnimation = LearningPetDirectionResolver.lookingAnimation(
                   toward: pointingDirection
               ) {
                return lookingAnimation
            }
            return .jumping
        case .followingCursor:
            break
        }

        switch voiceState {
        case .listening:
            return .waiting
        case .processing:
            return .working
        case .responding:
            return .review
        case .idle:
            if isMovingHorizontally {
                return isMovingRight ? .runningRight : .runningLeft
            }
            return .idle
        }
    }
}

private struct LearningPetSpriteFrameKey: Hashable {
    let rowIndex: Int
    let columnIndex: Int
}

@MainActor
private final class LearningPetSpriteAtlas {
    static let shared = LearningPetSpriteAtlas()

    private let sourceImage = NSImage(named: NSImage.Name("PipSpritesheet"))
    private var frameCache: [LearningPetSpriteFrameKey: NSImage] = [:]

    func frameImage(rowIndex: Int, columnIndex: Int) -> NSImage? {
        guard (0..<LearningPetAnimation.atlasRowCount).contains(rowIndex),
              (0..<LearningPetAnimation.atlasColumnCount).contains(columnIndex) else {
            return nil
        }

        let frameKey = LearningPetSpriteFrameKey(rowIndex: rowIndex, columnIndex: columnIndex)
        if let cachedImage = frameCache[frameKey] {
            return cachedImage
        }

        guard let sourceImage else { return nil }

        let expectedAtlasWidth = CGFloat(
            LearningPetAnimation.atlasColumnCount * LearningPetAnimation.atlasCellWidth
        )
        let expectedAtlasHeight = CGFloat(
            LearningPetAnimation.atlasRowCount * LearningPetAnimation.atlasCellHeight
        )
        guard sourceImage.size.width == expectedAtlasWidth,
              sourceImage.size.height == expectedAtlasHeight else {
            return nil
        }

        let cellWidth = CGFloat(LearningPetAnimation.atlasCellWidth)
        let cellHeight = CGFloat(LearningPetAnimation.atlasCellHeight)
        let sourceRectangle = NSRect(
            x: CGFloat(columnIndex) * cellWidth,
            y: sourceImage.size.height - CGFloat(rowIndex + 1) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        let destinationRectangle = NSRect(x: 0, y: 0, width: cellWidth, height: cellHeight)
        let frameImage = NSImage(size: destinationRectangle.size)

        frameImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        sourceImage.draw(
            in: destinationRectangle,
            from: sourceRectangle,
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: nil
        )
        frameImage.unlockFocus()
        frameImage.isTemplate = false

        frameCache[frameKey] = frameImage
        return frameImage
    }
}

struct LearningPetSpriteView: View {
    let animation: LearningPetAnimation
    var height: CGFloat = 72

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var animationStartedAt = Date()

    private var width: CGFloat {
        height * CGFloat(LearningPetAnimation.atlasCellWidth)
            / CGFloat(LearningPetAnimation.atlasCellHeight)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: accessibilityReduceMotion ? 1.0 : 1.0 / 30.0)) { timelineContext in
            let frameColumn = animation.frameColumn(
                at: timelineContext.date,
                animationStartedAt: animationStartedAt,
                reduceMotion: accessibilityReduceMotion
            )

            Group {
                if let frameImage = LearningPetSpriteAtlas.shared.frameImage(
                    rowIndex: animation.rowIndex,
                    columnIndex: frameColumn
                ) {
                    Image(nsImage: frameImage)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                } else {
                    Image(systemName: "pawprint.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color(red: 0.95, green: 0.47, blue: 0.20))
                        .padding(height * 0.24)
                }
            }
            .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        .onChange(of: animation) { _, _ in
            animationStartedAt = Date()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(animation.accessibilityDescription)
    }
}
