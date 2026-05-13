//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for blue glowing cursor.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
import AVFoundation
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// Cursor-like triangle shape (equilateral)
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct CaptionBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct CaptionBubbleContentSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

// SwiftUI view for the blue glowing cursor pointer.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// triangle when it is. During voice interaction, the triangle is
// replaced by a waveform (listening), hourglass (processing), or
// streaming text bubble (responding).
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The rotation angle of the triangle in degrees. Default is -35° (cursor-like).
    /// Changes to face the direction of travel when navigating to a target.
    @State private var triangleRotationDegrees: Double = -35.0

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy triangle during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Subtle uniform scale dip applied to the main dot when a scroll
    /// fires — a quick 1.0 → 0.92 → 1.0 squash that reads as "absorbing
    /// the scroll energy" without the dot feeling sluggish. Paired with
    /// the afterimage trail rendered next to the dot.
    @State private var scrollSquashScale: CGFloat = 1.0

    /// 0.0 = no afterimage trail, 1.0 = trail fully visible. Animated
    /// fast-in / linger / fast-out to mirror the instant scroll wheel.
    /// Three ghost circles fan out in `scrollTrailDirection` at
    /// increasing offsets with decreasing opacity multipliers — like
    /// motion blur or a comet smear.
    @State private var scrollTrailIntensity: Double = 0.0

    /// Unit vector the afterimage trail extends along (matches the
    /// scroll direction). Set just before the trail intensity animates.
    @State private var scrollTrailDirection: CGVector = .zero

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// One-shot squash-and-stretch multiplier applied to the cursor when the
    /// buddy performs a click action. Driven by companionManager.clickPulseToken.
    @State private var clickPulseScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    /// Measured size of the TTS-caption bubble, used to center it
    /// horizontally next to the cursor (the position() modifier wants
    /// the bubble's center, not its corner).
    @State private var captionBubbleSize: CGSize = .zero
    @State private var captionBubbleContentHeight: CGFloat = 0
    @State private var captionBubbleScrollOffset: CGFloat = 0
    @State private var shouldAutoScrollCaptionBubbleToBottom = true

    // MARK: - Onboarding Video Layout

    private let onboardingVideoPlayerWidth: CGFloat = 330
    private let onboardingVideoPlayerHeight: CGFloat = 186

    private let fullWelcomeMessage = "hey! i'm dot"

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Onboarding video — always in the view tree so opacity animation works
            // reliably. When no player exists or opacity is 0, nothing is visible.
            // allowsHitTesting(false) prevents it from intercepting clicks.
            OnboardingVideoPlayerView(player: companionManager.onboardingVideoPlayer)
                .frame(width: onboardingVideoPlayerWidth, height: onboardingVideoPlayerHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.black.opacity(0.4 * companionManager.onboardingVideoOpacity), radius: 12, x: 0, y: 6)
                .opacity(isCursorOnThisScreen ? companionManager.onboardingVideoOpacity : 0)
                .position(
                    x: cursorPosition.x + 10 + (onboardingVideoPlayerWidth / 2),
                    y: cursorPosition.y + 18 + (onboardingVideoPlayerHeight / 2)
                )
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeInOut(duration: 2.0), value: companionManager.onboardingVideoOpacity)
                .allowsHitTesting(false)

            // Onboarding prompt — "press control + option and say hi" streamed after video ends
            if isCursorOnThisScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                Text(companionManager.onboardingPromptText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(companionManager.onboardingPromptOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // TTS caption bubble — shown next to the blue Dot while the
            // agent is speaking (per-step narration). Wraps to a max
            // width, follows the cursor with a spring animation, and
            // gates visibility on the same `buddyIsVisibleOnThisScreen`
            // logic as the navigation pointer bubble so only one screen
            // renders the caption at a time on multi-monitor setups.
            if buddyIsVisibleOnThisScreen
                && companionManager.captionBubbleVisible
                && !companionManager.captionBubbleText.isEmpty {
                captionBubbleContent
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(0.92))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                            )
                            .shadow(color: Color.black.opacity(0.4), radius: 14, x: 0, y: 6)
                    )
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: CaptionBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .position(
                        captionBubblePosition(for: captionBubbleSize)
                    )
                    .opacity(companionManager.captionBubbleVisible ? 1.0 : 0.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.75, blendDuration: 0), value: cursorPosition)
                    .animation(.easeInOut(duration: 0.18), value: companionManager.captionBubbleText)
                    .animation(.easeInOut(duration: 0.25), value: companionManager.captionBubbleVisible)
                    .onPreferenceChange(CaptionBubbleSizePreferenceKey.self) { newSize in
                        captionBubbleSize = newSize
                    }
                    .allowsHitTesting(false)
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(
                                color: DS.Colors.overlayCursorBlue.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (navigationBubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // Blue dot cursor — shown when idle or while TTS is playing (responding).
            // All three states (dot, waveform, hourglass) stay in the view tree
            // permanently and cross-fade via opacity so SwiftUI doesn't remove/re-insert
            // them (which caused a visible cursor "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            // Afterimage trail ghosts rendered BEHIND the main dot so the
            // main cursor stays on top. Each ghost is the same color +
            // size, offset further in the scroll direction with lower
            // opacity — reads as motion blur or a comet smear matching
            // the instant scroll-wheel event. Driven by
            // `scrollTrailIntensity` (animated burst → fade) and
            // `scrollTrailDirection` (set at trigger time).
            ForEach(1...Self.scrollAfterimageGhostCount, id: \.self) { ghostIndex in
                let ghostOffsetMagnitude = CGFloat(ghostIndex) * Self.scrollAfterimageGhostSpacingInPoints
                let ghostFadeRolloff = Double(ghostIndex - 1) / Double(Self.scrollAfterimageGhostCount)
                Circle()
                    .fill(DS.Colors.overlayCursorBlue)
                    .frame(width: 14, height: 14)
                    .shadow(color: DS.Colors.overlayCursorBlue, radius: 6, x: 0, y: 0)
                    .scaleEffect(max(0.5, 1.0 - CGFloat(ghostIndex) * 0.12))
                    .offset(
                        x: scrollTrailDirection.dx * ghostOffsetMagnitude,
                        y: scrollTrailDirection.dy * ghostOffsetMagnitude
                    )
                    .opacity(scrollTrailIntensity * (0.6 - ghostFadeRolloff * 0.45))
                    .position(cursorPosition)
                    .allowsHitTesting(false)
            }

            // Blue dot cursor — shown when idle or while TTS is playing (responding).
            // All three states (dot, waveform, hourglass) stay in the view tree
            // permanently and cross-fade via opacity so SwiftUI doesn't remove/re-insert
            // them (which caused a visible cursor "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            BlueCursorFaceDotView(
                glowRadius: 8 + (buddyFlightScale - 1.0) * 20,
                glowOpacity: 1.0,
                eyeOpacity: 0.68
            )
                .scaleEffect(buddyFlightScale * clickPulseScale * scrollSquashScale)
                .opacity(
                    buddyIsVisibleOnThisScreen
                    && companionManager.voiceState == .idle
                    ? cursorOpacity
                    : 0
                )
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)
                .animation(
                    buddyNavigationMode == .navigatingToTarget ? nil : .easeInOut(duration: 0.3),
                    value: triangleRotationDegrees
                )

            // Speaking glow — keeps Dot round while text or TTS is streaming.
            // The old horizontal/vertical mouth cycle read a little uncanny;
            // this uses a softer breathing dot plus tiny voice pips instead.
            BlueCursorSpeakingGlowView()
                .scaleEffect(buddyFlightScale * clickPulseScale)
                .opacity(
                    buddyIsVisibleOnThisScreen
                    && companionManager.voiceState == .responding
                    && !companionManager.isShowingWaitingAnimation
                    ? cursorOpacity
                    : 0
                )
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Listening face — keeps Dot present while the side pulses react
            // to mic input.
            BlueCursorListeningFaceView(audioPowerLevel: companionManager.currentAudioPowerLevel)
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Thinking face — shown while the AI is processing or waiting.
            BlueCursorThinkingFaceView()
                .opacity(
                    buddyIsVisibleOnThisScreen
                    && (companionManager.voiceState == .processing || companionManager.isShowingWaitingAnimation)
                    ? cursorOpacity
                    : 0
                )
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()

            // Only show welcome message on first appearance (app start)
            // and only if the cursor starts on this screen
            if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
            companionManager.tearDownOnboardingVideo()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            // When a UI element location is detected, navigate the buddy to
            // that position so it points at the element.
            guard let screenLocation = newLocation,
                  let displayFrame = companionManager.detectedElementDisplayFrame else {
                return
            }

            // Only navigate if the target is on THIS screen
            guard screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                  || displayFrame == screenFrame else {
                return
            }

            startNavigatingToElement(screenLocation: screenLocation)
        }
        .onChange(of: companionManager.clickPulseToken) { _ in
            // Squash to 0.65, then bounce back past 1.0 with a low-damping
            // spring for an overshoot that settles to 1.0 — feels like a
            // springy button press in sync with the actual click.
            withAnimation(.easeOut(duration: 0.08)) {
                clickPulseScale = 0.65
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.4)) {
                    clickPulseScale = 1.0
                }
            }
        }
        .onChange(of: companionManager.scrollAnimationTriggerToken) { _ in
            playScrollAfterimageTrail(
                directionUnitVector: companionManager.mostRecentScrollDirectionUnitVector
            )
        }
        .onChange(of: companionManager.captionBubbleScrollCommandSequence) { _ in
            shouldAutoScrollCaptionBubbleToBottom = false
            applyCaptionBubbleScrollCommand()
        }
        .onChange(of: companionManager.captionBubbleText) { _ in
            shouldAutoScrollCaptionBubbleToBottom = true
            captionBubbleScrollOffset = 0
        }
        .onChange(of: companionManager.captionBubbleVisible) { isVisible in
            if !isVisible {
                captionBubbleScrollOffset = 0
                captionBubbleContentHeight = 0
                shouldAutoScrollCaptionBubbleToBottom = true
            } else {
                shouldAutoScrollCaptionBubbleToBottom = true
            }
        }
    }

    /// Fast afterimage trail to mirror the instant scroll-wheel event.
    /// The main dot does a tiny squash (1.0 → 0.92 → 1.0) and three
    /// ghost copies fan out in the scroll direction with decreasing
    /// opacity. Burst-in is fast (40ms), the trail lingers briefly
    /// (80ms), then fades out (140ms) — total ~260ms, fast enough to
    /// feel synced with the actual wheel scroll rather than a deliberate
    /// animation playing after it.
    private func playScrollAfterimageTrail(directionUnitVector: CGVector) {
        guard directionUnitVector != .zero else { return }

        // Set the trail direction BEFORE animating intensity so the
        // ghosts know which way to fan out the moment they fade in.
        scrollTrailDirection = directionUnitVector

        // Burst in: trail appears, main dot squashes slightly.
        withAnimation(.easeOut(duration: 0.04)) {
            scrollTrailIntensity = 1.0
            scrollSquashScale = Self.scrollMainDotSquashScale
        }

        // Main dot springs back to rest scale almost immediately —
        // the squash is a flicker, not a sustained pose.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.6, blendDuration: 0)) {
                scrollSquashScale = 1.0
            }
        }

        // Trail lingers briefly, then fades out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeIn(duration: 0.14)) {
                scrollTrailIntensity = 0.0
            }
        }
    }

    // Afterimage trail tuning. Tweak these to taste — they're tight on
    // purpose so the smear feels like motion blur, not a separate beat.
    private static let scrollAfterimageGhostCount: Int = 3
    private static let scrollAfterimageGhostSpacingInPoints: CGFloat = 11
    private static let scrollMainDotSquashScale: CGFloat = 0.92

    // TTS caption bubble tuning. Bubble lives just below-right of the Dot
    // so it doesn't collide with the small navigation-pointer bubble
    // (which sits at +18y to the right).
    private static let captionBubbleMaxWidth: CGFloat = 640
    private static let captionBubbleHorizontalOffsetInPoints: CGFloat = 16
    private static let captionBubbleVerticalOffsetInPoints: CGFloat = 28
    private static let captionBubbleScreenMarginInPoints: CGFloat = 12
    private static let captionBubbleKeyboardScrollStepInPoints: CGFloat = 72

    private var captionBubbleMaximumWidth: CGFloat {
        max(220, min(Self.captionBubbleMaxWidth, screenFrame.width - (Self.captionBubbleScreenMarginInPoints * 2)))
    }

    private var captionBubbleMaximumHeight: CGFloat {
        let usableScreenHeight = max(180, screenFrame.height - 96)
        return min(usableScreenHeight, max(220, screenFrame.height * 0.68))
    }

    private var captionBubbleContentExceedsMaximumHeight: Bool {
        captionBubbleContentHeight > captionBubbleMaximumHeight + 1
    }

    private var captionBubbleMaximumScrollOffset: CGFloat {
        max(0, captionBubbleContentHeight - captionBubbleMaximumHeight)
    }

    @ViewBuilder
    private var captionBubbleContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            captionBubbleTextViewport

            if captionBubbleContentExceedsMaximumHeight {
                Text("use ↑/↓ to scroll")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.52))
                    .frame(maxWidth: captionBubbleMaximumWidth, alignment: .trailing)
            }

            Text("hold cmd to reposition without hiding")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.38))
                .frame(maxWidth: captionBubbleMaximumWidth, alignment: .trailing)
                .padding(.top, 1)
        }
        .frame(maxWidth: captionBubbleMaximumWidth, alignment: .leading)
    }

    private var captionBubbleTextViewport: some View {
        ZStack(alignment: .topLeading) {
            MarkdownResponseTextView(markdownText: companionManager.captionBubbleText)
                .frame(maxWidth: captionBubbleMaximumWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geometryProxy in
                        Color.clear.preference(
                            key: CaptionBubbleContentSizePreferenceKey.self,
                            value: geometryProxy.size
                        )
                    }
                )
                .offset(y: -captionBubbleScrollOffset)
        }
        .frame(maxWidth: captionBubbleMaximumWidth, alignment: .topLeading)
        .frame(
            height: captionBubbleContentExceedsMaximumHeight ? captionBubbleMaximumHeight : nil,
            alignment: .topLeading
        )
        .clipped()
        .onPreferenceChange(CaptionBubbleContentSizePreferenceKey.self) { newSize in
            updateCaptionBubbleMeasuredContentHeight(newSize.height)
        }
    }

    private func updateCaptionBubbleMeasuredContentHeight(_ measuredContentHeight: CGFloat) {
        captionBubbleContentHeight = measuredContentHeight
        let maximumScrollOffset = max(0, measuredContentHeight - captionBubbleMaximumHeight)
        guard maximumScrollOffset > 1 else {
            captionBubbleScrollOffset = 0
            return
        }

        if shouldAutoScrollCaptionBubbleToBottom {
            captionBubbleScrollOffset = maximumScrollOffset
        } else {
            captionBubbleScrollOffset = min(
                max(0, captionBubbleScrollOffset),
                maximumScrollOffset
            )
        }
    }

    private func applyCaptionBubbleScrollCommand() {
        guard captionBubbleContentExceedsMaximumHeight else {
            captionBubbleScrollOffset = 0
            return
        }

        let scrollDirectionSteps = companionManager.captionBubbleScrollDirectionSteps
        if scrollDirectionSteps <= -10_000 {
            captionBubbleScrollOffset = 0
            return
        }
        if scrollDirectionSteps >= 10_000 {
            captionBubbleScrollOffset = captionBubbleMaximumScrollOffset
            return
        }

        let requestedScrollOffset = captionBubbleScrollOffset
            + CGFloat(scrollDirectionSteps) * Self.captionBubbleKeyboardScrollStepInPoints
        captionBubbleScrollOffset = min(
            max(0, requestedScrollOffset),
            captionBubbleMaximumScrollOffset
        )
    }

    private func captionBubblePosition(for measuredBubbleSize: CGSize) -> CGPoint {
        let desiredX = cursorPosition.x
            + Self.captionBubbleHorizontalOffsetInPoints
            + (measuredBubbleSize.width / 2)
        let desiredY = cursorPosition.y
            + Self.captionBubbleVerticalOffsetInPoints
            + (measuredBubbleSize.height / 2)

        let minimumX = Self.captionBubbleScreenMarginInPoints + (measuredBubbleSize.width / 2)
        let maximumX = screenFrame.width - Self.captionBubbleScreenMarginInPoints - (measuredBubbleSize.width / 2)
        let minimumY = Self.captionBubbleScreenMarginInPoints + (measuredBubbleSize.height / 2)
        let maximumY = screenFrame.height - Self.captionBubbleScreenMarginInPoints - (measuredBubbleSize.height / 2)

        return CGPoint(
            x: min(max(desiredX, minimumX), max(minimumX, maximumX)),
            y: min(max(desiredY, minimumY), max(minimumY, maximumY))
        )
    }

    /// Whether the buddy triangle should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // During forward flight or pointing, the buddy is NOT interrupted by
            // mouse movement — it completes its full animation and return flight.
            // Only during the RETURN flight do we allow cursor movement to cancel
            // (so the buddy snaps to following if the user moves while it's flying back).
            if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                let distanceFromNavigationStart = hypot(
                    currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                    currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }

            // During forward navigation or pointing, just skip cursor tracking
            if self.buddyNavigationMode != .followingCursor {
                return
            }

            // Normal cursor following
            let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let buddyX = swiftUIPosition.x + 35
            let buddyY = swiftUIPosition.y + 25
            self.cursorPosition = CGPoint(x: buddyX, y: buddyY)
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset the target so the buddy sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. The triangle rotates to face its direction
    /// of travel (tangent to the curve) each frame, scales up at the midpoint
    /// for a "swooping" feel, and the glow intensifies during flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            // Linear progress 0→1 over the flight duration
            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            // Rotation: face the direction of travel by computing the tangent
            // to the bezier curve. B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
            let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                         + 2.0 * t * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                         + 2.0 * t * (endPosition.y - controlPoint.y)
            // +90° offset because the triangle's "tip" points up at 0° rotation,
            // and atan2 returns 0° for rightward movement
            self.triangleRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0

            // Scale pulse: sin curve peaks at midpoint of the flight.
            // Buddy grows to ~1.3x at the apex, then shrinks back to 1.0x on landing.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget

        // Rotate back to default pointer angle now that we've arrived
        triangleRotationDegrees = -35.0

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // Use custom bubble text from the companion manager (e.g. onboarding demo)
        // if available, otherwise fall back to a random pointer phrase
        let pointerPhrase = companionManager.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            // All characters streamed — hold for 3 seconds, then fly back
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        finishNavigationAndResumeFollowing()
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = -35.0
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        companionManager.clearDetectedElementLocation()
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                // Hold the text for 2 seconds, then fade it out
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                    // Start the onboarding video right after the welcome text disappears
                    self.companionManager.setupOnboardingVideo()
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// MARK: - Blue Cursor Speaking Glow

private struct BlueCursorFaceDotView: View {
    let glowRadius: CGFloat
    let glowOpacity: Double
    let eyeOpacity: Double
    let eyeHeightScale: CGFloat

    init(
        glowRadius: CGFloat,
        glowOpacity: Double,
        eyeOpacity: Double,
        eyeHeightScale: CGFloat = 1.0
    ) {
        self.glowRadius = glowRadius
        self.glowOpacity = glowOpacity
        self.eyeOpacity = eyeOpacity
        self.eyeHeightScale = eyeHeightScale
    }

    var body: some View {
        let eyeHeight = max(0.9, 4.2 * eyeHeightScale)

        ZStack {
            Circle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 14, height: 14)
                .shadow(
                    color: DS.Colors.overlayCursorBlue.opacity(glowOpacity),
                    radius: glowRadius,
                    x: 0,
                    y: 0
                )

            HStack(spacing: 2.3) {
                Capsule(style: .continuous)
                    .fill(Color(red: 0.02, green: 0.08, blue: 0.12).opacity(eyeOpacity))
                    .frame(width: 1.55, height: eyeHeight)
                Capsule(style: .continuous)
                    .fill(Color(red: 0.02, green: 0.08, blue: 0.12).opacity(eyeOpacity))
                    .frame(width: 1.55, height: eyeHeight)
            }
            .offset(y: -0.9)
            .allowsHitTesting(false)
        }
        .frame(width: 14, height: 14)
    }
}

/// A compact speaking-state indicator. It keeps Dot's silhouette round and
/// adds a gentle breath plus tiny voice pips so streamed text/TTS feels alive
/// without becoming mouth-like or twitchy.
private struct BlueCursorSpeakingGlowView: View {
    private let breathDurationSeconds: TimeInterval = 1.65
    private let pipDurationSeconds: TimeInterval = 1.45
    private let pipOffsets: [CGSize] = [
        CGSize(width: 11.0, height: -7.0),
        CGSize(width: 14.0, height: 0.0),
        CGSize(width: 10.5, height: 7.0)
    ]
    private let pipDiameters: [CGFloat] = [3.2, 4.0, 2.8]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { timelineContext in
            let breath = CGFloat(breathAmount(for: timelineContext.date))

            ZStack {
                Circle()
                    .fill(DS.Colors.overlayCursorBlue.opacity(0.18 + Double(breath) * 0.08))
                    .frame(width: 24, height: 24)
                    .scaleEffect(0.95 + breath * 0.14)

                Circle()
                    .stroke(DS.Colors.overlayCursorBlue.opacity(0.24 + Double(breath) * 0.18), lineWidth: 1.0)
                    .frame(width: 19, height: 19)
                    .scaleEffect(0.92 + breath * 0.16)

                BlueCursorFaceDotView(
                    glowRadius: 7 + breath * 3,
                    glowOpacity: 0.66 + Double(breath) * 0.10,
                    eyeOpacity: 0.74
                )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.26 + Double(breath) * 0.10), lineWidth: 0.75)
                    )

                ForEach(pipOffsets.indices, id: \.self) { pipIndex in
                    let pipPulse = CGFloat(pipPulseAmount(
                        for: timelineContext.date,
                        pipIndex: pipIndex
                    ))
                    let baseOffset = pipOffsets[pipIndex]
                    let travelScale = 0.91 + pipPulse * 0.14

                    Circle()
                        .fill(DS.Colors.overlayCursorBlue.opacity(0.24 + Double(pipPulse) * 0.58))
                        .frame(width: pipDiameters[pipIndex], height: pipDiameters[pipIndex])
                        .scaleEffect(0.72 + pipPulse * 0.46)
                        .offset(
                            x: baseOffset.width * travelScale,
                            y: baseOffset.height * travelScale
                        )
                        .shadow(
                            color: DS.Colors.overlayCursorBlue.opacity(0.28 + Double(pipPulse) * 0.32),
                            radius: 3 + pipPulse * 2,
                            x: 0,
                            y: 0
                        )
                }
            }
            .frame(width: 36, height: 32)
            .scaleEffect(0.98 + breath * 0.05)
        }
    }

    private func breathAmount(for date: Date) -> Double {
        let rawProgress = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: breathDurationSeconds) / breathDurationSeconds
        let wave = (sin(rawProgress * .pi * 2.0) + 1.0) / 2.0
        return wave * wave * (3.0 - 2.0 * wave)
    }

    private func pipPulseAmount(for date: Date, pipIndex: Int) -> Double {
        let shiftedTime = date.timeIntervalSinceReferenceDate + Double(pipIndex) * 0.18
        let rawProgress = shiftedTime
            .truncatingRemainder(dividingBy: pipDurationSeconds) / pipDurationSeconds
        let wave = max(0, sin(rawProgress * .pi))
        return pow(wave, 1.35)
    }
}

// MARK: - Blue Cursor Listening Face

/// A small face with symmetric side pulses. The center stays Dot-shaped while
/// the outer pips react to live mic power.
private struct BlueCursorListeningFaceView: View {
    let audioPowerLevel: CGFloat

    private let pulseVerticalOffsets: [CGFloat] = [-5.2, 0.0, 5.2]
    private let breathDurationSeconds: TimeInterval = 1.25

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            let audioLevel = easedAudioPowerLevel()
            let breath = breathAmount(for: timelineContext.date)

            ZStack {
                Circle()
                    .fill(DS.Colors.overlayCursorBlue.opacity(0.12 + Double(audioLevel) * 0.12))
                    .frame(width: 27, height: 27)
                    .scaleEffect(0.94 + breath * 0.06 + audioLevel * 0.12)

                Circle()
                    .stroke(
                        DS.Colors.overlayCursorBlue.opacity(0.24 + Double(audioLevel) * 0.28),
                        lineWidth: 1.0
                    )
                    .frame(width: 21, height: 21)
                    .scaleEffect(0.95 + breath * 0.08 + audioLevel * 0.08)

                ForEach(pulseVerticalOffsets.indices, id: \.self) { pulseIndex in
                    let pulseAmount = listeningPulseAmount(
                        for: timelineContext.date,
                        pulseIndex: pulseIndex
                    )
                    let pulseDiameter = 2.1 + pulseAmount * 1.9 + audioLevel * 1.2

                    ForEach(0..<2, id: \.self) { sideIndex in
                        let direction: CGFloat = sideIndex == 0 ? -1.0 : 1.0

                        Circle()
                            .fill(DS.Colors.overlayCursorBlue.opacity(0.20 + Double(pulseAmount) * 0.30 + Double(audioLevel) * 0.32))
                            .frame(width: pulseDiameter, height: pulseDiameter)
                            .offset(
                                x: direction * (11.3 + pulseAmount * 2.5 + audioLevel * 2.8),
                                y: pulseVerticalOffsets[pulseIndex]
                            )
                            .shadow(
                                color: DS.Colors.overlayCursorBlue.opacity(0.20 + Double(audioLevel) * 0.35),
                                radius: 3 + audioLevel * 3,
                                x: 0,
                                y: 0
                            )
                    }
                }

                BlueCursorFaceDotView(
                    glowRadius: 7 + audioLevel * 5,
                    glowOpacity: 0.72 + Double(audioLevel) * 0.18,
                    eyeOpacity: 0.76
                )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.22 + Double(audioLevel) * 0.12), lineWidth: 0.75)
                    )
            }
            .frame(width: 44, height: 36)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func easedAudioPowerLevel() -> CGFloat {
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        return pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
    }

    private func breathAmount(for date: Date) -> CGFloat {
        let rawProgress = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: breathDurationSeconds) / breathDurationSeconds
        let wave = (sin(rawProgress * .pi * 2.0) + 1.0) / 2.0
        return CGFloat(wave * wave * (3.0 - 2.0 * wave))
    }

    private func listeningPulseAmount(for date: Date, pulseIndex: Int) -> CGFloat {
        let shiftedTime = date.timeIntervalSinceReferenceDate + Double(pulseIndex) * 0.12
        let wave = (sin(shiftedTime * 4.2) + 1.0) / 2.0
        let reactiveAmount = easedAudioPowerLevel()
        return CGFloat(0.24 + wave * 0.18) + reactiveAmount * CGFloat(0.45 + Double(pulseIndex) * 0.08)
    }
}

// MARK: - Blue Cursor Thinking Face

/// A face-preserving waiting state. A slow blink and small orbiting sparkle
/// reads as "thinking" without switching into a mechanical hourglass.
private struct BlueCursorThinkingFaceView: View {
    private let breathDurationSeconds: TimeInterval = 2.2
    private let orbitDurationSeconds: TimeInterval = 2.8
    private let blinkDurationSeconds: TimeInterval = 3.4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { timelineContext in
            let breath = breathAmount(for: timelineContext.date)
            let orbitAngle = orbitAngle(for: timelineContext.date)
            let sparkleOpacity = sparkleOpacity(for: timelineContext.date)
            let eyeHeightScale = blinkingEyeHeightScale(for: timelineContext.date)

            ZStack {
                Circle()
                    .fill(DS.Colors.overlayCursorBlue.opacity(0.12 + Double(breath) * 0.06))
                    .frame(width: 27, height: 27)
                    .scaleEffect(0.96 + breath * 0.08)

                Circle()
                    .stroke(
                        DS.Colors.overlayCursorBlue.opacity(0.22 + Double(breath) * 0.20),
                        lineWidth: 1.0
                    )
                    .frame(width: 21, height: 21)
                    .scaleEffect(0.94 + breath * 0.14)

                Circle()
                    .fill(Color.white.opacity(0.66 * sparkleOpacity))
                    .frame(width: 3.6, height: 3.6)
                    .offset(
                        x: CGFloat(cos(Double(orbitAngle))) * 13.2,
                        y: CGFloat(sin(Double(orbitAngle))) * 8.4
                    )
                    .shadow(
                        color: DS.Colors.overlayCursorBlue.opacity(0.45 * sparkleOpacity),
                        radius: 5,
                        x: 0,
                        y: 0
                    )

                Circle()
                    .fill(DS.Colors.overlayCursorBlue.opacity(0.34 * sparkleOpacity))
                    .frame(width: 2.2, height: 2.2)
                    .offset(
                        x: CGFloat(cos(Double(orbitAngle - 0.55))) * 11.6,
                        y: CGFloat(sin(Double(orbitAngle - 0.55))) * 7.4
                    )

                BlueCursorFaceDotView(
                    glowRadius: 7 + breath * 3,
                    glowOpacity: 0.68 + Double(breath) * 0.12,
                    eyeOpacity: 0.72,
                    eyeHeightScale: eyeHeightScale
                )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.22 + Double(breath) * 0.10), lineWidth: 0.75)
                    )
            }
            .frame(width: 38, height: 34)
            .scaleEffect(0.98 + breath * 0.04)
        }
    }

    private func breathAmount(for date: Date) -> CGFloat {
        let rawProgress = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: breathDurationSeconds) / breathDurationSeconds
        let wave = (sin(rawProgress * .pi * 2.0) + 1.0) / 2.0
        return CGFloat(wave * wave * (3.0 - 2.0 * wave))
    }

    private func orbitAngle(for date: Date) -> CGFloat {
        let rawProgress = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: orbitDurationSeconds) / orbitDurationSeconds
        return CGFloat(rawProgress * .pi * 2.0)
    }

    private func sparkleOpacity(for date: Date) -> Double {
        let rawProgress = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: orbitDurationSeconds) / orbitDurationSeconds
        let wave = (sin(rawProgress * .pi * 2.0) + 1.0) / 2.0
        return 0.48 + wave * 0.42
    }

    private func blinkingEyeHeightScale(for date: Date) -> CGFloat {
        let rawProgress = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: blinkDurationSeconds) / blinkDurationSeconds
        let closeProgress = smoothStep(clamped((CGFloat(rawProgress) - 0.72) / 0.045))
        let openProgress = smoothStep(clamped((CGFloat(rawProgress) - 0.79) / 0.075))
        let blinkAmount = closeProgress * (1.0 - openProgress)
        return 1.0 - blinkAmount * 0.78
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        let clampedValue = clamped(value)
        return clampedValue * clampedValue * (3 - 2 * clampedValue)
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}

// MARK: - Onboarding Video Player

/// NSViewRepresentable wrapping an AVPlayerLayer so HLS video plays
/// inside SwiftUI. Uses a custom NSView subclass to keep the player
/// layer sized to the view's bounds automatically.
private struct OnboardingVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerNSView {
        let view = AVPlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerNSView, context: Context) {
        nsView.player = player
    }
}

private class AVPlayerNSView: NSView {
    var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }

    private let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
