//
//  RemoteCommandSubscriber.swift
//  leanring-buddy
//
//  Subscribes to vibe-id's per-user cross-device event bus via WebSocket
//  and feeds delivered `dot.command.issued` events into the companion's
//  agent loop. Posts `dot.command.completed` back once the agent loop
//  terminates so the phone control page sees real status.
//
//  Default: off. Activated by the menu bar panel toggle
//  ("DotRemoteControlEnabled" UserDefaults boolean). While off the
//  subscriber holds no connection and makes no requests.
//
//  Architecture: see ~/Desktop/projects/vibe-id/docs/REMOTE_CONTROL_DESIGN.md.
//

import Combine
import Foundation

/// One delivered remote event surfaced to the menu bar panel for the audit
/// row. Mirrors the envelope the worker fans out via the user-session DO.
struct RemoteEventRecord: Identifiable, Equatable {
    let id: String
    let eventType: String
    let payload: [String: String]
    let sourceDeviceLabel: String?
    let createdAt: Date
    /// Set when this Mac has finished dispatching the event through the
    /// agent loop and posted the matching `*.completed` event back.
    let completedAt: Date?
    let completedStatus: String?
}

@MainActor
final class RemoteCommandSubscriber: ObservableObject {
    /// UserDefaults key the menu-bar panel toggle binds to via @AppStorage.
    /// When the value flips, this subscriber starts/stops its WebSocket.
    static let remoteControlEnabledUserDefaultsKey = "DotRemoteControlEnabled"

    /// UserDefaults key the cold-boot replay banner uses. Stores the unix
    /// timestamp of the last event this Mac processed so we can detect
    /// "we missed a chunk of history while asleep".
    static let lastProcessedEventTimestampUserDefaultsKey = "DotRemoteControlLastProcessedEventTimestamp"

    /// UserDefaults key storing the persistent dedup ring buffer of recent
    /// event IDs. Survives Mac restart, so a half-delivered event isn't
    /// re-run after a crash.
    static let dispatchedEventIdsUserDefaultsKey = "DotRemoteControlDispatchedEventIds"

    /// True while the WebSocket is connected. The panel renders a small
    /// "connected" dot when this is true and `isRemoteControlEnabled`.
    @Published private(set) var isWebSocketConnected: Bool = false

    /// Most recent error from the connection loop, nil while healthy.
    @Published private(set) var lastErrorDescription: String?

    /// Newest-first list of delivered events for the panel audit row.
    /// Capped at 50; older history lives server-side via GET /events.
    @Published private(set) var recentDeliveredEvents: [RemoteEventRecord] = []

    /// Set to a non-nil value when the subscriber has just reconnected and
    /// drained a burst of events whose `created_at` is meaningfully older
    /// than the current time. The panel renders a banner so the user can
    /// see (and potentially cancel) the replay. Cleared when the banner
    /// is dismissed.
    @Published private(set) var coldBootReplayBannerEventCount: Int = 0

    private let companionManager: CompanionManager

    /// Background task owning the WebSocket connection while remote
    /// control is enabled. Cancelled the moment the toggle flips off.
    private var connectionLoopTask: Task<Void, Never>?
    private var currentWebSocketTask: URLSessionWebSocketTask?

    /// Persistent device id, stable across launches. Sent on the WS upgrade
    /// so audit log rows can distinguish "delivered to my laptop" vs
    /// "delivered to my desktop".
    private let subscriberDeviceIdentifier: String

    /// Tracks the agent-loop source string we issued for each in-flight
    /// command so the outcome publisher can correlate the result back to
    /// the originating event_id. Cleared when the outcome lands.
    private var inFlightCommandEventIdBySourceString: [String: String] = [:]

    /// Persistent ring buffer of recently dispatched event_ids. Loaded
    /// from UserDefaults on init; trimmed + written back on each insert.
    private var dispatchedEventIdsPersistent: [String]

    /// Subscription to the companion manager's agent-loop outcome
    /// publisher. Held for the lifetime of this object.
    private var agentLoopOutcomeCancellable: AnyCancellable?

    /// Exponential reconnect backoff state. Reset on a successful connect.
    private var currentReconnectBackoffSeconds: TimeInterval = 0

    /// Server-side project feature flag. Defaults to true until /auth/me returns
    /// so existing local preferences do not get cleared by a transient startup
    /// fetch failure.
    private var isRemoteControlAllowedByServer = true

    private static let baseReconnectBackoffSeconds: TimeInterval = 1.0
    private static let maximumReconnectBackoffSeconds: TimeInterval = 60.0
    /// When the subscriber connects, any events with created_at older than
    /// (now - this) trigger the cold-boot replay banner instead of running
    /// silently. The user can then choose to dismiss or cancel them.
    private static let coldBootReplayBannerThresholdSeconds: TimeInterval = 30.0
    private static let persistentDedupRingBufferCapacity = 500
    private static let recentDeliveredEventsCapacity = 50

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self.subscriberDeviceIdentifier = Self.resolvePersistentDeviceIdentifier()
        self.dispatchedEventIdsPersistent = Self.loadPersistedDispatchedEventIds()

        agentLoopOutcomeCancellable = companionManager.agentLoopOutcomePublisher
            .sink { [weak self] outcome in
                self?.handleAgentLoopOutcome(outcome)
            }

        // Honour saved preference on launch.
        let isRemoteControlEnabledAtLaunch = UserDefaults.standard.bool(
            forKey: Self.remoteControlEnabledUserDefaultsKey
        )
        if isRemoteControlEnabledAtLaunch {
            startConnectionLoopIfNeeded()
        }
    }

    // MARK: - Toggle entry point

    /// Called from the menu bar panel when the user flips the toggle.
    /// Idempotent.
    func setRemoteControlEnabled(_ shouldEnableRemoteControl: Bool) {
        guard isRemoteControlAllowedByServer else {
            UserDefaults.standard.set(
                false,
                forKey: Self.remoteControlEnabledUserDefaultsKey
            )
            lastErrorDescription = "Remote control is disabled by the server."
            stopConnectionLoop()
            return
        }
        UserDefaults.standard.set(
            shouldEnableRemoteControl,
            forKey: Self.remoteControlEnabledUserDefaultsKey
        )
        if shouldEnableRemoteControl {
            startConnectionLoopIfNeeded()
        } else {
            stopConnectionLoop()
        }
    }

    func setServerAllowsRemoteControl(_ shouldAllowRemoteControl: Bool) {
        guard shouldAllowRemoteControl != isRemoteControlAllowedByServer else { return }
        isRemoteControlAllowedByServer = shouldAllowRemoteControl

        if shouldAllowRemoteControl {
            lastErrorDescription = nil
            if UserDefaults.standard.bool(forKey: Self.remoteControlEnabledUserDefaultsKey) {
                startConnectionLoopIfNeeded()
            }
            return
        }

        UserDefaults.standard.set(false, forKey: Self.remoteControlEnabledUserDefaultsKey)
        lastErrorDescription = "Remote control is disabled by the server."
        stopConnectionLoop()
        DotDebugLogger.log("remote.subscriber", "stopped by server feature flag")
    }

    func dismissColdBootReplayBanner() {
        coldBootReplayBannerEventCount = 0
    }

    // MARK: - Connection loop

    private func startConnectionLoopIfNeeded() {
        guard connectionLoopTask == nil else { return }
        DotDebugLogger.log("remote.subscriber", "starting connection loop", metadata: [
            "deviceId": subscriberDeviceIdentifier
        ])
        connectionLoopTask = Task { [weak self] in
            await self?.runConnectionLoopUntilCancelled()
        }
    }

    private func stopConnectionLoop() {
        DotDebugLogger.log("remote.subscriber", "stopping connection loop")
        connectionLoopTask?.cancel()
        connectionLoopTask = nil
        currentWebSocketTask?.cancel(with: .goingAway, reason: nil)
        currentWebSocketTask = nil
        isWebSocketConnected = false
    }

    private func runConnectionLoopUntilCancelled() async {
        while !Task.isCancelled {
            do {
                try await openWebSocketAndProcessUntilDisconnect()
                currentReconnectBackoffSeconds = 0
                lastErrorDescription = nil
            } catch is CancellationError {
                return
            } catch {
                let errorDescription = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                lastErrorDescription = errorDescription
                DotDebugLogger.log("remote.subscriber", "websocket loop errored", metadata: [
                    "error": errorDescription
                ])
                currentReconnectBackoffSeconds = min(
                    Self.maximumReconnectBackoffSeconds,
                    max(Self.baseReconnectBackoffSeconds, currentReconnectBackoffSeconds * 2)
                )
            }

            isWebSocketConnected = false
            let nextDelaySeconds = max(
                Self.baseReconnectBackoffSeconds,
                currentReconnectBackoffSeconds
            )
            try? await Task.sleep(nanoseconds: UInt64(nextDelaySeconds * 1_000_000_000))
        }
    }

    private func openWebSocketAndProcessUntilDisconnect() async throws {
        guard let installToken = DotInstallTokenStore.currentInstallToken() else {
            throw RemoteCommandSubscriberError.notSignedIn
        }

        let baseURLString = AppBundleConfiguration.vibeIdBaseURLString()
        // Translate https:// → wss:// (and http:// → ws://) so URLSession
        // builds the right kind of task.
        var websocketBaseString = baseURLString
        if websocketBaseString.hasPrefix("https://") {
            websocketBaseString = "wss://" + websocketBaseString.dropFirst("https://".count)
        } else if websocketBaseString.hasPrefix("http://") {
            websocketBaseString = "ws://" + websocketBaseString.dropFirst("http://".count)
        }

        var websocketURLComponents = URLComponents(
            string: "\(websocketBaseString)/session/ws"
        )
        websocketURLComponents?.queryItems = [
            URLQueryItem(name: "token", value: installToken),
            URLQueryItem(name: "device_id", value: subscriberDeviceIdentifier),
            URLQueryItem(name: "subscribe", value: "dot.command.issued"),
        ]
        guard let websocketURL = websocketURLComponents?.url else {
            throw RemoteCommandSubscriberError.invalidConfiguration
        }

        let websocketTask = URLSession.shared.webSocketTask(with: websocketURL)
        currentWebSocketTask = websocketTask
        websocketTask.resume()
        isWebSocketConnected = true

        DotDebugLogger.log("remote.subscriber", "websocket opened", metadata: [
            "host": websocketURL.host ?? "unknown"
        ])

        // Send a periodic application-level ping so the worker DO knows
        // we're still here and so corporate proxies don't reap the
        // connection as idle. The DO replies with `{type:pong}`.
        let pingPongTask = Task { [weak self, weak websocketTask] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let websocketTask, let _ = self else { break }
                let pingMessage = #"{"type":"ping"}"#
                do {
                    try await websocketTask.send(.string(pingMessage))
                } catch {
                    break
                }
            }
        }
        defer { pingPongTask.cancel() }

        // Drain messages until the socket closes or errors out.
        while !Task.isCancelled {
            let incomingMessage: URLSessionWebSocketTask.Message
            do {
                incomingMessage = try await websocketTask.receive()
            } catch {
                throw error
            }

            switch incomingMessage {
            case .string(let messageText):
                handleIncomingEventMessage(messageText)
            case .data(let messageData):
                if let messageText = String(data: messageData, encoding: .utf8) {
                    handleIncomingEventMessage(messageText)
                }
            @unknown default:
                break
            }
        }
    }

    // MARK: - Message handling

    private func handleIncomingEventMessage(_ rawMessageText: String) {
        guard let messageData = rawMessageText.data(using: .utf8),
              let parsedJSON = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
            return
        }

        // Ignore non-event control frames (pong, etc.).
        if let messageType = parsedJSON["type"] as? String, messageType == "pong" {
            return
        }

        guard let eventId = parsedJSON["id"] as? String,
              let eventType = parsedJSON["event_type"] as? String,
              let createdAtEpochSeconds = parsedJSON["created_at"] as? Int else {
            return
        }

        // For v1 we only act on dot.command.issued. Other event_types just
        // populate the audit row (so the user can see "I received this"
        // even for things we don't act on yet).
        let payloadAsStringsOnly: [String: String] = (parsedJSON["payload"] as? [String: Any])?
            .reduce(into: [:]) { result, kv in
                if let stringValue = kv.value as? String { result[kv.key] = stringValue }
                else { result[kv.key] = String(describing: kv.value) }
            } ?? [:]

        let sourceDeviceLabel = parsedJSON["source_device_label"] as? String
        let createdAtDate = Date(timeIntervalSince1970: TimeInterval(createdAtEpochSeconds))

        let record = RemoteEventRecord(
            id: eventId,
            eventType: eventType,
            payload: payloadAsStringsOnly,
            sourceDeviceLabel: sourceDeviceLabel,
            createdAt: createdAtDate,
            completedAt: nil,
            completedStatus: nil
        )
        prependRecentDeliveredEvent(record)

        guard eventType == "dot.command.issued" else { return }

        // Dedup against the persistent ring buffer so a crashed-then-replayed
        // delivery doesn't double-execute.
        if dispatchedEventIdsPersistent.contains(eventId) {
            DotDebugLogger.log("remote.subscriber", "skipping duplicate event", metadata: [
                "eventId": eventId
            ])
            return
        }
        recordDispatchedEventIdPersistent(eventId)

        // Cold-boot replay banner: if the event was created well before
        // "now" we're processing it after the user's Mac woke up — surface
        // a banner rather than silently running a stale command.
        let ageSeconds = Date().timeIntervalSince(createdAtDate)
        if ageSeconds > Self.coldBootReplayBannerThresholdSeconds {
            coldBootReplayBannerEventCount += 1
        }

        // Pull the transcript out of payload.transcript and run it.
        guard let transcript = payloadAsStringsOnly["transcript"], !transcript.isEmpty else {
            DotDebugLogger.log("remote.subscriber", "dot.command.issued without transcript", metadata: [
                "eventId": eventId
            ])
            return
        }

        let agentLoopSourceString = "remote:\(eventId)"
        inFlightCommandEventIdBySourceString[agentLoopSourceString] = eventId
        DotDebugLogger.log("remote.subscriber", "dispatching remote command into agent loop", metadata: [
            "eventId": eventId,
            "transcriptLength": transcript.count
        ])

        companionManager.runTranscriptThroughAgentLoop(
            transcript: transcript,
            source: agentLoopSourceString
        )
    }

    private func handleAgentLoopOutcome(_ outcome: AgentLoopOutcome) {
        // Only react to outcomes whose source we issued.
        guard let originatingEventId = inFlightCommandEventIdBySourceString.removeValue(forKey: outcome.source) else {
            return
        }

        let resultStatusString: String
        switch outcome.status {
        case .completed: resultStatusString = "completed"
        case .cancelled: resultStatusString = "cancelled"
        case .failed:    resultStatusString = "failed"
        }
        let summaryTextTrimmedToWireLimit: String = {
            let baseSummary = outcome.finalSpokenText.isEmpty
                ? (outcome.errorDescription ?? "")
                : outcome.finalSpokenText
            let trimmed = baseSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(trimmed.prefix(200))
        }()

        updateRecentDeliveredEventCompletion(
            eventId: originatingEventId,
            status: resultStatusString
        )

        Task { [weak self] in
            await self?.postCommandCompletedEvent(
                originatingEventId: originatingEventId,
                resultStatus: resultStatusString,
                resultSummary: summaryTextTrimmedToWireLimit,
                stepsExecuted: outcome.stepsExecuted
            )
        }
    }

    // MARK: - Posting follow-up events

    private func postCommandCompletedEvent(
        originatingEventId: String,
        resultStatus: String,
        resultSummary: String,
        stepsExecuted: Int
    ) async {
        guard let installToken = DotInstallTokenStore.currentInstallToken() else { return }
        let postEventsURL = URL(string: "\(AppBundleConfiguration.vibeIdBaseURLString())/events")!
        var postRequest = URLRequest(url: postEventsURL)
        postRequest.httpMethod = "POST"
        postRequest.setValue("Bearer \(installToken)", forHTTPHeaderField: "Authorization")
        postRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let completionPayload: [String: Any] = [
            "id": UUID().uuidString,
            "event_type": "dot.command.completed",
            "payload": [
                "originating_event_id": originatingEventId,
                "status": resultStatus,
                "summary": resultSummary,
                "steps_executed": stepsExecuted
            ] as [String: Any]
        ]
        postRequest.httpBody = try? JSONSerialization.data(withJSONObject: completionPayload)

        do {
            let (_, urlResponse) = try await URLSession.shared.data(for: postRequest)
            if let httpResponse = urlResponse as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                DotDebugLogger.log("remote.subscriber", "command.completed POST failed", metadata: [
                    "originatingEventId": originatingEventId,
                    "statusCode": httpResponse.statusCode
                ])
            }
        } catch {
            DotDebugLogger.log("remote.subscriber", "command.completed POST threw", metadata: [
                "originatingEventId": originatingEventId,
                "error": error.localizedDescription
            ])
        }
    }

    // MARK: - Recent-events list

    private func prependRecentDeliveredEvent(_ deliveredEvent: RemoteEventRecord) {
        recentDeliveredEvents.insert(deliveredEvent, at: 0)
        if recentDeliveredEvents.count > Self.recentDeliveredEventsCapacity {
            recentDeliveredEvents.removeLast(
                recentDeliveredEvents.count - Self.recentDeliveredEventsCapacity
            )
        }
    }

    private func updateRecentDeliveredEventCompletion(eventId: String, status: String) {
        guard let foundIndex = recentDeliveredEvents.firstIndex(where: { $0.id == eventId }) else { return }
        let existing = recentDeliveredEvents[foundIndex]
        recentDeliveredEvents[foundIndex] = RemoteEventRecord(
            id: existing.id,
            eventType: existing.eventType,
            payload: existing.payload,
            sourceDeviceLabel: existing.sourceDeviceLabel,
            createdAt: existing.createdAt,
            completedAt: Date(),
            completedStatus: status
        )
    }

    // MARK: - Persistent dedup

    private func recordDispatchedEventIdPersistent(_ eventId: String) {
        dispatchedEventIdsPersistent.append(eventId)
        if dispatchedEventIdsPersistent.count > Self.persistentDedupRingBufferCapacity {
            dispatchedEventIdsPersistent.removeFirst(
                dispatchedEventIdsPersistent.count - Self.persistentDedupRingBufferCapacity
            )
        }
        UserDefaults.standard.set(
            dispatchedEventIdsPersistent,
            forKey: Self.dispatchedEventIdsUserDefaultsKey
        )
    }

    private static func loadPersistedDispatchedEventIds() -> [String] {
        let storedArray = UserDefaults.standard.array(forKey: dispatchedEventIdsUserDefaultsKey) as? [String]
        return storedArray ?? []
    }

    // MARK: - Stable device id

    private static let subscriberDeviceIdentifierUserDefaultsKey = "DotRemoteControlSubscriberDeviceId"

    private static func resolvePersistentDeviceIdentifier() -> String {
        if let cachedIdentifier = UserDefaults.standard.string(
            forKey: subscriberDeviceIdentifierUserDefaultsKey
        ), !cachedIdentifier.isEmpty {
            return cachedIdentifier
        }
        let freshIdentifier = UUID().uuidString
        UserDefaults.standard.set(freshIdentifier, forKey: subscriberDeviceIdentifierUserDefaultsKey)
        return freshIdentifier
    }
}

// MARK: - Errors

enum RemoteCommandSubscriberError: LocalizedError {
    case notSignedIn
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "not signed in — sign in from the menu bar panel before enabling remote control"
        case .invalidConfiguration:
            return "vibe-id base URL is missing or malformed"
        }
    }
}
