//
//  VideoMemoryMonitorManager.swift
//  leanring-buddy
//
//  Dot-side control plane for VideoMemory binary monitors. VideoMemory owns
//  the actual local vision loop; Dot owns user intent, visibility, and the
//  wake-up action so monitors are never silently running without UI.
//

import AppKit
import Foundation

struct VideoMemoryMonitor: Identifiable, Equatable {
    let taskID: String
    let ioID: String
    let taskDescription: String
    let actionInstruction: String?
    let monitorType: String
    let botID: String?
    let status: String
    let done: Bool
    let latestNote: String?
    let hasFrameEvidence: Bool

    var id: String { taskID }

    var displayTitle: String {
        let trimmedDescription = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else { return "Video monitor \(taskID)" }
        if trimmedDescription.count <= 42 { return trimmedDescription }
        return String(trimmedDescription.prefix(39)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    var isDotOwned: Bool {
        (botID ?? "").hasPrefix(VideoMemoryMonitorManager.dotBotIDPrefix)
    }
}

struct VideoMemoryMonitorCreationResult {
    let taskID: String
    let ioID: String
    let triggerCondition: String
    let actionInstruction: String
    let readinessWarning: String?

    var toolResultText: String {
        var lines = [
            "created VideoMemory binary monitor",
            "task_id: \(taskID)",
            "io_id: \(ioID)",
            "trigger: \(triggerCondition)",
            "action: \(actionInstruction)",
            "monitor_type: binary"
        ]
        if let readinessWarning, !readinessWarning.isEmpty {
            lines.append("readiness_warning: \(readinessWarning)")
        }
        return lines.joined(separator: "\n")
    }
}

enum VideoMemoryMonitorSource: String {
    case auto
    case screen
    case facetime
    case camera
    case device
}

@MainActor
final class VideoMemoryMonitorManager: ObservableObject {

    nonisolated static let dotBotIDPrefix = "dot"

    private static let actionInstructionUserDefaultsKey = "DotVideoMemoryMonitorActions"
    private static let notifiedTaskIDsUserDefaultsKey = "DotVideoMemoryMonitorNotifiedTaskIDs"
    private static let dotScreenCameraID = "dot_screen"
    private static let dotScreenIOID = "browser_dot_screen"
    private static let pollIntervalNanoseconds: UInt64 = 3_000_000_000
    private static let screenPublishIntervalNanoseconds: UInt64 = 2_000_000_000

    @Published private(set) var activeMonitors: [VideoMemoryMonitor] = []
    @Published private(set) var isVideoMemoryReachable: Bool = false
    @Published private(set) var lastRefreshError: String?

    var triggerHandler: ((VideoMemoryMonitor) -> Void)?

    private let baseURL: URL
    private let session: URLSession
    private var pollingTask: Task<Void, Never>?
    private var screenFramePublisherTask: Task<Void, Never>?
    private var actionInstructionByTaskID: [String: String]
    private var notifiedTaskIDs: Set<String>
    private var previouslyActiveTaskIDs: Set<String> = []

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:5050")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
        self.actionInstructionByTaskID = Self.loadActionInstructions()
        self.notifiedTaskIDs = Self.loadNotifiedTaskIDs()
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshActiveMonitors()
                self?.updateScreenFramePublisherForCurrentMonitors()
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        stopScreenFramePublisher()
    }

    var activeMonitorCountForOverlay: Int {
        activeMonitors.count
    }

    func taskPageURL(for monitor: VideoMemoryMonitor) -> URL {
        baseURL.appendingPathComponent("task").appendingPathComponent(monitor.taskID)
    }

    func openTaskPage(taskID: String) {
        let taskURL = baseURL.appendingPathComponent("task").appendingPathComponent(taskID)
        NSWorkspace.shared.open(taskURL)
    }

    func listVideoMemoryStateForTool() async -> String {
        do {
            async let devicesObject = requestJSONObject(path: "/api/devices")
            async let tasksObject = requestJSONObject(path: "/api/tasks")
            let (devices, tasks) = try await (devicesObject, tasksObject)
            await refreshActiveMonitors()
            let renderedDevices = Self.renderCompactJSONObject(devices)
            let renderedTasks = Self.renderCompactJSONObject(tasks)
            return """
            VideoMemory is reachable at \(baseURL.absoluteString)

            devices:
            \(renderedDevices)

            tasks:
            \(renderedTasks)
            """
        } catch {
            return "error: VideoMemory is not reachable at \(baseURL.absoluteString): \(error.localizedDescription)"
        }
    }

    func createBinaryMonitor(
        source: VideoMemoryMonitorSource,
        ioID requestedIOID: String?,
        triggerCondition: String,
        actionInstruction: String,
        semanticKeywords: String?
    ) async -> Result<VideoMemoryMonitorCreationResult, Error> {
        let trimmedTriggerCondition = triggerCondition.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedActionInstruction = actionInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTriggerCondition.isEmpty, !trimmedActionInstruction.isEmpty else {
            return .failure(Self.makeError("trigger_condition and action_instruction are required"))
        }

        do {
            let resolvedIOID = try await resolveIOID(
                source: source,
                requestedIOID: requestedIOID,
                triggerCondition: trimmedTriggerCondition
            )
            let normalizedTriggerCondition = Self.normalizedTriggerCondition(
                trimmedTriggerCondition,
                ioID: resolvedIOID
            )
            if resolvedIOID == Self.dotScreenIOID {
                try await ensureDotScreenDeviceIsPublishing()
            }

            var payload: [String: Any] = [
                "io_id": resolvedIOID,
                "task_description": normalizedTriggerCondition,
                "bot_id": "\(Self.dotBotIDPrefix)-binary-monitor",
                "monitor_type": "binary",
                "save_note_frames": true,
                "save_note_videos": false
            ]

            let trimmedSemanticKeywords = semanticKeywords?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedSemanticKeywords.isEmpty {
                payload["semantic_filter_keywords"] = trimmedSemanticKeywords
                payload["semantic_filter_threshold"] = 0.3
                payload["semantic_filter_threshold_mode"] = "absolute"
                payload["semantic_filter_reduce"] = "max"
                payload["semantic_filter_ensemble"] = "off"
            }

            let createdTaskObject = try await postJSONObject(path: "/api/tasks", payload: payload)
            guard let taskID = createdTaskObject["task_id"] as? String,
                  !taskID.isEmpty else {
                throw Self.makeError("VideoMemory did not return a task_id")
            }

            actionInstructionByTaskID[taskID] = trimmedActionInstruction
            Self.saveActionInstructions(actionInstructionByTaskID)

            let readinessWarning = await readinessWarningIfNeeded(ioID: resolvedIOID)
            await refreshActiveMonitors()
            updateScreenFramePublisherForCurrentMonitors()

            return .success(VideoMemoryMonitorCreationResult(
                taskID: taskID,
                ioID: resolvedIOID,
                triggerCondition: normalizedTriggerCondition,
                actionInstruction: trimmedActionInstruction,
                readinessWarning: readinessWarning
            ))
        } catch {
            return .failure(error)
        }
    }

    func stopMonitor(taskID: String) async -> String {
        let trimmedTaskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTaskID.isEmpty else {
            return "error: task_id is required"
        }

        let previousActionInstruction = actionInstructionByTaskID[trimmedTaskID]
        let wasPreviouslyActive = previouslyActiveTaskIDs.contains(trimmedTaskID)
        let wasAlreadyNotified = notifiedTaskIDs.contains(trimmedTaskID)

        do {
            notifiedTaskIDs.insert(trimmedTaskID)
            previouslyActiveTaskIDs.remove(trimmedTaskID)
            actionInstructionByTaskID.removeValue(forKey: trimmedTaskID)
            Self.saveNotifiedTaskIDs(notifiedTaskIDs)
            Self.saveActionInstructions(actionInstructionByTaskID)

            _ = try await postJSONObject(
                path: "/api/task/\(Self.urlPathEscaped(trimmedTaskID))/stop",
                payload: [:]
            )
            activeMonitors.removeAll { $0.taskID == trimmedTaskID }
            updateScreenFramePublisherForCurrentMonitors()
            DotDebugLogger.log("videomemory.monitor", "stopped monitor", metadata: [
                "taskID": trimmedTaskID
            ])
            return "stopped VideoMemory monitor task_id: \(trimmedTaskID)"
        } catch {
            if let previousActionInstruction {
                actionInstructionByTaskID[trimmedTaskID] = previousActionInstruction
            }
            if wasPreviouslyActive {
                previouslyActiveTaskIDs.insert(trimmedTaskID)
            }
            if !wasAlreadyNotified {
                notifiedTaskIDs.remove(trimmedTaskID)
            }
            Self.saveNotifiedTaskIDs(notifiedTaskIDs)
            Self.saveActionInstructions(actionInstructionByTaskID)
            return "error: failed to stop VideoMemory monitor \(trimmedTaskID): \(error.localizedDescription)"
        }
    }

    func refreshActiveMonitors() async {
        do {
            let tasksObject = try await requestJSONObject(path: "/api/tasks")
            let fetchedTasks = Self.parseTasksResponse(tasksObject)
            let fetchedActiveMonitors = fetchedTasks
                .filter { !$0.done && $0.status.lowercased() == "active" }
                .sorted { $0.taskID.localizedStandardCompare($1.taskID) == .orderedAscending }

            let activeTaskIDs = Set(fetchedActiveMonitors.map(\.taskID))
            let fetchedDoneTasks = fetchedTasks.filter { $0.done || $0.status.lowercased() == "done" }
            for doneTask in fetchedDoneTasks {
                guard previouslyActiveTaskIDs.contains(doneTask.taskID),
                      notifiedTaskIDs.contains(doneTask.taskID) == false,
                      actionInstructionByTaskID[doneTask.taskID] != nil else {
                    continue
                }
                notifiedTaskIDs.insert(doneTask.taskID)
                Self.saveNotifiedTaskIDs(notifiedTaskIDs)
                DotDebugLogger.log("videomemory.monitor", "monitor triggered", metadata: [
                    "taskID": doneTask.taskID,
                    "ioID": doneTask.ioID,
                    "descriptionLength": doneTask.taskDescription.count
                ])
                triggerHandler?(doneTask)
            }

            activeMonitors = fetchedActiveMonitors
            previouslyActiveTaskIDs.formUnion(activeTaskIDs)
            isVideoMemoryReachable = true
            lastRefreshError = nil
        } catch {
            isVideoMemoryReachable = false
            lastRefreshError = error.localizedDescription
            activeMonitors = []
            DotDebugLogger.log("videomemory.monitor", "refresh failed", metadata: [
                "error": error.localizedDescription
            ])
        }
    }

    private func resolveIOID(
        source: VideoMemoryMonitorSource,
        requestedIOID: String?,
        triggerCondition: String
    ) async throws -> String {
        let trimmedRequestedIOID = requestedIOID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedRequestedIOID.isEmpty {
            return trimmedRequestedIOID
        }

        let resolvedSource: VideoMemoryMonitorSource
        if source == .auto {
            resolvedSource = Self.inferSource(from: triggerCondition)
        } else {
            resolvedSource = source
        }

        switch resolvedSource {
        case .screen:
            return Self.dotScreenIOID
        case .facetime:
            return try await preferredFaceTimeIOID()
        case .camera, .device, .auto:
            return try await preferredCameraIOID()
        }
    }

    private static func inferSource(from triggerCondition: String) -> VideoMemoryMonitorSource {
        let lowercasedCondition = triggerCondition.lowercased()
        let screenKeywords = [
            "youtube", "browser", "chrome", "safari", "screen", "window", "tab",
            "website", "web page", "slack", "cursor", "desktop"
        ]
        if screenKeywords.contains(where: { lowercasedCondition.contains($0) }) {
            return .screen
        }
        return .camera
    }

    private static func normalizedTriggerCondition(_ triggerCondition: String, ioID: String) -> String {
        let trimmedTriggerCondition = triggerCondition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ioID == dotScreenIOID else { return trimmedTriggerCondition }

        let lowercasedCondition = trimmedTriggerCondition.lowercased()
        guard lowercasedCondition.contains("youtube") else {
            return trimmedTriggerCondition
        }

        let alreadyDescribesAppState = [
            "website",
            "web site",
            "app",
            "page",
            "video player",
            "player",
            "watch page",
            "browser tab"
        ].contains { lowercasedCondition.contains($0) }
        guard alreadyDescribesAppState == false else {
            return trimmedTriggerCondition
        }

        return "The YouTube website, app, browser tab, watch page, or video player is open on the screen. The word YouTube appearing only in instructions, transcripts, monitor labels, or Dot confirmation text does not count."
    }

    private func preferredFaceTimeIOID() async throws -> String {
        let devicesObject = try await requestJSONObject(path: "/api/devices")
        let devices = Self.parseDevicesResponse(devicesObject)
        if devices.contains(where: { $0.ioID == "browser_facetime" }) {
            return "browser_facetime"
        }
        if let faceTimeDevice = devices.first(where: { $0.name.lowercased().contains("facetime") }) {
            return faceTimeDevice.ioID
        }
        return try await preferredCameraIOID(from: devices)
    }

    private func preferredCameraIOID() async throws -> String {
        let devicesObject = try await requestJSONObject(path: "/api/devices")
        return try await preferredCameraIOID(from: Self.parseDevicesResponse(devicesObject))
    }

    private func preferredCameraIOID(from devices: [VideoMemoryDevice]) async throws -> String {
        if devices.contains(where: { $0.ioID == "browser_facetime" }) {
            return "browser_facetime"
        }
        if let runningCamera = devices.first(where: { $0.ingestorRunning }) {
            return runningCamera.ioID
        }
        if let firstCamera = devices.first {
            return firstCamera.ioID
        }
        throw Self.makeError("VideoMemory did not report any camera devices")
    }

    private func ensureDotScreenDeviceIsPublishing() async throws {
        startScreenFramePublisherIfNeeded()
        try await publishCurrentScreenFrameOnce()
        _ = try await postJSONObject(
            path: "/api/browser-camera/\(Self.dotScreenCameraID)/register",
            payload: [:]
        )
    }

    private func startScreenFramePublisherIfNeeded() {
        guard screenFramePublisherTask == nil else { return }
        screenFramePublisherTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await self?.publishCurrentScreenFrameOnce()
                } catch {
                    DotDebugLogger.log("videomemory.screen", "screen frame publish failed", metadata: [
                        "error": error.localizedDescription
                    ])
                }
                try? await Task.sleep(nanoseconds: Self.screenPublishIntervalNanoseconds)
            }
        }
        DotDebugLogger.log("videomemory.screen", "started screen frame publisher")
    }

    private func stopScreenFramePublisher() {
        guard screenFramePublisherTask != nil else { return }
        screenFramePublisherTask?.cancel()
        screenFramePublisherTask = nil
        DotDebugLogger.log("videomemory.screen", "stopped screen frame publisher")
    }

    private func updateScreenFramePublisherForCurrentMonitors() {
        let shouldPublishScreenFrames = activeMonitors.contains { monitor in
            monitor.ioID == Self.dotScreenIOID
        }
        if shouldPublishScreenFrames {
            startScreenFramePublisherIfNeeded()
        } else {
            stopScreenFramePublisher()
        }
    }

    private func publishCurrentScreenFrameOnce() async throws {
        let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        guard let primaryScreenCapture = screenCaptures.first(where: \.isCursorScreen) ?? screenCaptures.first else {
            throw Self.makeError("screen capture produced no frames")
        }

        var request = URLRequest(url: absoluteURL(path: "/api/browser-camera/\(Self.dotScreenCameraID)/frame"))
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = primaryScreenCapture.imageData

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Self.makeError("invalid VideoMemory frame upload response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Self.makeError("screen frame upload failed (\(httpResponse.statusCode)): \(body)")
        }
    }

    private func readinessWarningIfNeeded(ioID: String) async -> String? {
        do {
            let readiness = try await requestJSONObject(path: "/api/device/\(Self.urlPathEscaped(ioID))/readiness")
            guard let ready = readiness["ready"] as? Bool, ready == false else { return nil }
            let warnings = readiness["warnings"] as? [String] ?? []
            return warnings.isEmpty ? "device is not ready yet" : warnings.joined(separator: " ")
        } catch {
            return "could not read device readiness: \(error.localizedDescription)"
        }
    }

    private func requestJSONObject(path: String) async throws -> [String: Any] {
        var request = URLRequest(url: absoluteURL(path: path))
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        return try Self.decodeJSONObject(data: data, response: response)
    }

    private func postJSONObject(path: String, payload: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: absoluteURL(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        return try Self.decodeJSONObject(data: data, response: response)
    }

    private func absoluteURL(path: String) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath.isEmpty {
            components.path = normalizedPath
        } else {
            components.path = "/\(basePath)\(normalizedPath)"
        }
        return components.url ?? baseURL
    }

    private static func decodeJSONObject(data: Data, response: URLResponse) throws -> [String: Any] {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw makeError("invalid HTTP response")
        }
        let parsedObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let errorText = parsedObject?["error"] as? String
                ?? parsedObject?["message"] as? String
                ?? body
            throw makeError("VideoMemory API error (\(httpResponse.statusCode)): \(errorText)")
        }
        guard let parsedObject else {
            throw makeError("VideoMemory returned non-JSON response")
        }
        return parsedObject
    }

    private static func parseTasksResponse(_ tasksObject: [String: Any]) -> [VideoMemoryMonitor] {
        guard let taskDictionaries = tasksObject["tasks"] as? [[String: Any]] else { return [] }
        return taskDictionaries.compactMap { taskDictionary in
            guard let taskID = taskDictionary["task_id"] as? String else { return nil }
            let notes = taskDictionary["task_note"] as? [[String: Any]] ?? []
            let latestNote = notes.last?["content"] as? String
            let hasFrameEvidence = notes.contains { note in
                (note["has_frame"] as? Bool) == true
            }
            return VideoMemoryMonitor(
                taskID: taskID,
                ioID: taskDictionary["io_id"] as? String ?? "",
                taskDescription: taskDictionary["task_desc"] as? String ?? "",
                actionInstruction: loadActionInstructions()[taskID],
                monitorType: taskDictionary["monitor_type"] as? String ?? "",
                botID: taskDictionary["bot_id"] as? String,
                status: taskDictionary["status"] as? String ?? "",
                done: (taskDictionary["done"] as? Bool) ?? false,
                latestNote: latestNote,
                hasFrameEvidence: hasFrameEvidence
            )
        }
    }

    private struct VideoMemoryDevice {
        let ioID: String
        let name: String
        let source: String
        let ingestorRunning: Bool
    }

    private static func parseDevicesResponse(_ devicesObject: [String: Any]) -> [VideoMemoryDevice] {
        guard let devicesByCategory = devicesObject["devices"] as? [String: Any],
              let cameraDevices = devicesByCategory["camera"] as? [[String: Any]] else {
            return []
        }
        return cameraDevices.compactMap { deviceDictionary in
            guard let ioID = deviceDictionary["io_id"] as? String else { return nil }
            return VideoMemoryDevice(
                ioID: ioID,
                name: deviceDictionary["name"] as? String ?? "",
                source: deviceDictionary["source"] as? String ?? "",
                ingestorRunning: (deviceDictionary["ingestor_running"] as? Bool) ?? false
            )
        }
    }

    private static func renderCompactJSONObject(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: object)
        }
        return text
    }

    private static func loadActionInstructions() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: actionInstructionUserDefaultsKey) as? [String: String] ?? [:]
    }

    private static func saveActionInstructions(_ actions: [String: String]) {
        UserDefaults.standard.set(actions, forKey: actionInstructionUserDefaultsKey)
    }

    private static func loadNotifiedTaskIDs() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: notifiedTaskIDsUserDefaultsKey) ?? []
        return Set(array)
    }

    private static func saveNotifiedTaskIDs(_ taskIDs: Set<String>) {
        UserDefaults.standard.set(Array(taskIDs).sorted(), forKey: notifiedTaskIDsUserDefaultsKey)
    }

    private static func urlPathEscaped(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text
    }

    private static func makeError(_ description: String) -> NSError {
        NSError(
            domain: "VideoMemoryMonitorManager",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
