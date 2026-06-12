//
//  TakeoverController.swift
//  leanring-buddy
//
//  The offline autonomous loop: screenshot -> local VLM -> one action ->
//  guardrails -> execute (or dry-run) -> narrate -> repeat. Everything here
//  is built so a misgrounding small model is harmless, not destructive.
//
//  Rails, in priority order:
//   1. Offline + local + Accessibility precondition (refuses to start otherwise).
//   2. Kill switch (ESC) aborts instantly, mid-action.
//   3. Hard caps: step count + wall-clock.
//   4. Dry-run by default; real actions need an explicit arm.
//   5. Danger gate: destructive actions need the extra "allow risky" opt-in.
//

import Combine
import Foundation

@MainActor
final class TakeoverController: ObservableObject {
    enum RunState: Equatable {
        case idle
        case running(step: Int, lastAction: String)
        case finished(summary: String)
        case stopped(reason: String)
    }

    /// Dry-run moves the cursor to where it would act and narrates, but never
    /// clicks/types. The safe default — flip `isArmed` on to perform real input.
    @Published var isArmed = false
    /// Even when armed, destructive actions (submit/return/combos, danger-word
    /// clicks) are skipped unless this is also on. Two deliberate switches
    /// stand between a 3B model and anything irreversible.
    @Published var allowRiskyActions = false
    @Published private(set) var runState: RunState = .idle

    private static let stepCap = 25
    private static let wallClockCapSeconds: TimeInterval = 120
    private static let dangerWordPattern =
        #"(?i)\b(send|delete|remove|buy|purchase|pay|confirm|submit|post|publish|discard|trash|erase|format|reset|sign\s?out|log\s?out)\b"#

    private let visionAgent: TakeoverVisionAgent
    private let executor: ComputerUseActionExecutor
    private let captureCursorScreen: () async throws -> CompanionScreenCapture?
    private let narrate: (String) async -> Void
    private let isNetworkAvailable: () -> Bool

    private var runTask: Task<Void, Never>?
    private var killRequested = false

    init(
        visionAgent: TakeoverVisionAgent,
        executor: ComputerUseActionExecutor,
        captureCursorScreen: @escaping () async throws -> CompanionScreenCapture?,
        narrate: @escaping (String) async -> Void,
        isNetworkAvailable: @escaping () -> Bool
    ) {
        self.visionAgent = visionAgent
        self.executor = executor
        self.captureCursorScreen = captureCursorScreen
        self.narrate = narrate
        self.isNetworkAvailable = isNetworkAvailable
    }

    // MARK: - Preconditions

    enum StartRefusal: LocalizedError {
        case networkUp
        case accessibilityMissing
        case alreadyRunning
        var errorDescription: String? {
            switch self {
            case .networkUp: return "takeover is offline-only — turn off wifi first."
            case .accessibilityMissing: return "i need accessibility permission to control the cursor — grant it in system settings."
            case .alreadyRunning: return "already running a takeover."
            }
        }
    }

    var isRunning: Bool {
        if case .running = runState { return true }
        return false
    }

    // MARK: - Run

    func start(task: String) {
        guard !isRunning else { return }

        // Rail 1: offline + Accessibility, refuse loudly otherwise.
        if isNetworkAvailable() {
            failToStart(.networkUp); return
        }
        if !executor.isAccessibilityTrusted {
            failToStart(.accessibilityMissing); return
        }

        killRequested = false
        runState = .running(step: 0, lastAction: "looking at your screen")

        // Rail 2: kill switch live for the whole run.
        executor.startKillSwitchMonitor { [weak self] in
            self?.requestKill()
        }

        runTask = Task { await runLoop(task: task) }
    }

    func requestKill() {
        killRequested = true
        runTask?.cancel()
    }

    private func failToStart(_ refusal: StartRefusal) {
        runState = .stopped(reason: refusal.localizedDescription)
        Task { await narrate(refusal.localizedDescription) }
    }

    private func runLoop(task: String) async {
        defer {
            executor.stopKillSwitchMonitor()
            // Rail 4: arming never persists past a run.
            isArmed = false
            allowRiskyActions = false
        }

        let startDate = Date()
        var historyTrace: [String] = []
        var recentActions: [TakeoverAction] = []

        for step in 0..<Self.stepCap {
            if killRequested || Task.isCancelled { finish(.stopped(reason: "stopped.")); return }

            // Rail 1 (continuous): bail if the network comes up mid-run.
            if isNetworkAvailable() {
                await narrate("wifi came back on — stopping takeover to stay offline.")
                finish(.stopped(reason: "network came up")); return
            }

            // Rail 3: wall-clock cap.
            if Date().timeIntervalSince(startDate) >= Self.wallClockCapSeconds {
                await narrate("i've spent my time budget on this — stopping here.")
                finish(.stopped(reason: "time cap")); return
            }

            let capture: CompanionScreenCapture?
            do {
                capture = try await captureCursorScreen()
            } catch {
                finish(.stopped(reason: "couldn't capture the screen")); return
            }
            guard let capture else { finish(.stopped(reason: "no screen to look at")); return }

            let action: TakeoverAction
            do {
                action = try await visionAgent.decideNextAction(
                    task: task,
                    historyTrace: historyTrace,
                    screenshotJPEG: capture.imageData,
                    screenshotWidthInPixels: capture.screenshotWidthInPixels,
                    screenshotHeightInPixels: capture.screenshotHeightInPixels
                )
            } catch is CancellationError {
                finish(.stopped(reason: "stopped.")); return
            } catch {
                // Misgrounding / parse failure: one honest retry, then stop —
                // never click blindly.
                await narrate("i'm not reading the screen clearly — stopping so i don't click the wrong thing.")
                finish(.stopped(reason: "couldn't ground the screen")); return
            }

            switch action {
            case .done(let summary):
                await narrate(summary.isEmpty ? "all done." : summary)
                finish(.finished(summary: summary)); return
            case .giveUp(let reason):
                await narrate(reason.isEmpty ? "i can't do this one." : reason)
                finish(.stopped(reason: reason)); return
            default:
                break
            }

            // Rail (stuck): same move three times running -> bail.
            if recentActions.count >= 2,
               recentActions.suffix(2).allSatisfy({ TakeoverAction.areEquivalent($0, action) }) {
                await narrate("i'm going in circles here — stopping.")
                finish(.stopped(reason: "stuck in a loop")); return
            }

            runState = .running(step: step + 1, lastAction: action.traceLabel)
            await narrate(action.narration)

            await performGuarded(action: action, on: capture)

            historyTrace.append(action.traceLabel)
            recentActions.append(action)
            if killRequested || Task.isCancelled { finish(.stopped(reason: "stopped.")); return }

            // Let the screen settle before the next screenshot.
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        await narrate("i've taken as many steps as i'm allowed for this one.")
        finish(.stopped(reason: "step cap"))
    }

    // MARK: - Guarded execution

    private func performGuarded(action: TakeoverAction, on capture: CompanionScreenCapture) async {
        // Rail 4: dry-run only moves the cursor to the target and narrates.
        let dryRun = !isArmed

        switch action {
        case .click(let x, let y, let targetLabel, let why):
            guard let appKitPoint = appKitGlobalPoint(forPixelX: x, pixelY: y, on: capture) else { return }
            if dryRun {
                executor.moveCursorVisible(toAppKitGlobal: appKitPoint)
                return
            }
            // Rail 5: danger-word clicks need the risky opt-in.
            if isDangerous(targetLabel + " " + why) && !allowRiskyActions {
                await narrate("that looks like it might do something irreversible, so i'll leave that click to you.")
                executor.moveCursorVisible(toAppKitGlobal: appKitPoint)
                return
            }
            executor.click(atAppKitGlobal: appKitPoint)

        case .type(let text, _):
            if dryRun { return }
            // Rail 5: all text entry needs the risky opt-in.
            if !allowRiskyActions {
                await narrate("i'd type \"\(text.prefix(40))\" here — flip on allow-risky if you want me to.")
                return
            }
            executor.typeText(text)

        case .key(let combo, _):
            if dryRun { return }
            // Rail 5: submission (return) and any combo need the risky opt-in.
            let lowered = combo.lowercased()
            let isSubmitOrCombo = lowered == "return" || lowered == "enter" || lowered.contains("+")
            if isSubmitOrCombo && !allowRiskyActions {
                await narrate("pressing \(combo) could submit something — i'll leave that to you.")
                return
            }
            executor.pressKey(combo: combo)

        case .scroll(let x, let y, let direction, let amount, _):
            guard let appKitPoint = appKitGlobalPoint(forPixelX: x, pixelY: y, on: capture) else { return }
            if dryRun {
                executor.moveCursorVisible(toAppKitGlobal: appKitPoint)
                return
            }
            executor.scroll(atAppKitGlobal: appKitPoint, direction: direction, amount: amount)

        case .done, .giveUp:
            break
        }
    }

    private func isDangerous(_ text: String) -> Bool {
        text.range(of: Self.dangerWordPattern, options: .regularExpression) != nil
    }

    /// Maps a screenshot pixel to an AppKit global point — the same scale the
    /// pointing pipeline uses (px -> display points -> bottom-left global).
    /// The executor flips this to Quartz top-left at the post boundary.
    private func appKitGlobalPoint(forPixelX pixelX: Int, pixelY: Int, on capture: CompanionScreenCapture) -> CGPoint? {
        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        guard screenshotWidth > 0, screenshotHeight > 0 else { return nil }

        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let displayFrame = capture.displayFrame

        let clampedX = max(0, min(CGFloat(pixelX), screenshotWidth))
        let clampedY = max(0, min(CGFloat(pixelY), screenshotHeight))

        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY

        return CGPoint(x: displayLocalX + displayFrame.origin.x,
                       y: appKitY + displayFrame.origin.y)
    }

    private func finish(_ state: RunState) {
        runState = state
        runTask = nil
    }
}
