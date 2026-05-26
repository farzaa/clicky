//
//  SessionRecorder.swift
//  yardtalk
//
//  Records a single clip: ScreenCaptureKit video + AVCaptureSession mic
//  audio, baked into one MP4 via AVAssetWriter. Lifecycle is one-shot:
//  start() configures the writer, both capture sources, and starts them
//  in the order AVAssetWriter requires; stop() finalizes and returns the
//  output URL + duration. SessionManager creates a fresh recorder per
//  clip rather than reusing one.
//
//  Concurrency notes: SCStream and AVCaptureSession deliver sample
//  buffers on the queue you give them. We give both the same serial
//  captureQueue so PTS ordering is preserved across video + audio
//  inputs. State is `nonisolated(unsafe)` because the delegate methods
//  must run on captureQueue, not MainActor.
//
//  Timing: SCStream sample buffers carry CMTimes referenced to the host
//  clock; AVCaptureSession audio samples carry CMTimes referenced to the
//  audio session clock. Mixing those domains as PTS values into one
//  AVAssetWriter is what produced the "moov atom not found" failure on
//  the first round of testing — the writer would enter `.failed` state
//  silently and `finishWriting()` then no-op'd, leaving an unplayable
//  file. Fix: synthesize a single timeline from host time at sample
//  arrival, and rebase every sample buffer's PTS via
//  CMSampleBufferCreateCopyWithNewTiming. Both inputs share one clock
//  domain so AVAssetWriter has nothing to reject.
//

import AVFoundation
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

extension Logger {
    static let recorder = Logger(subsystem: "com.yardtalk.app", category: "recorder")
}

enum SessionRecorderError: LocalizedError {
    case noDisplay
    case noMicrophone
    case writerSetupFailed(String)
    case captureSetupFailed(String)
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display available for capture."
        case .noMicrophone: return "No microphone available for capture."
        case .writerSetupFailed(let m): return "Recorder setup failed: \(m)"
        case .captureSetupFailed(let m): return "Mic capture failed: \(m)"
        case .streamFailed(let m): return "Screen capture failed: \(m)"
        }
    }
}

final class SessionRecorder: NSObject, @unchecked Sendable {
    nonisolated(unsafe) private var writer: AVAssetWriter?
    nonisolated(unsafe) private var videoInput: AVAssetWriterInput?
    nonisolated(unsafe) private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    nonisolated(unsafe) private var audioInput: AVAssetWriterInput?
    /// Host-clock CMTime captured at the first sample's arrival. Used as
    /// the anchor from which every appended sample's PTS is measured —
    /// see the file header for why we rebase rather than trust intrinsic
    /// PTS values.
    nonisolated(unsafe) private var anchorHostTime: CMTime?
    nonisolated(unsafe) private var stream: SCStream?
    nonisolated(unsafe) private var captureSession: AVCaptureSession?
    nonisolated(unsafe) private var audioOutput: AVCaptureAudioDataOutput?
    nonisolated(unsafe) private var audioLevelTimer: DispatchSourceTimer?
    nonisolated(unsafe) private var startedAt: Date?
    nonisolated(unsafe) private var didLogAudioFormat = false
    nonisolated(unsafe) private var didLogWriterFailure = false
    nonisolated(unsafe) private var didReceiveAudioSample = false
    nonisolated(unsafe) private var audioWatchdogTimer: DispatchSourceTimer?

    /// Fired ~20Hz during recording with a normalized 0...1 level so the UI
    /// can show a live mic meter. A flat meter while recording is a visible
    /// signal that the mic isn't actually capturing — the user can release,
    /// fix the input, and try again.
    nonisolated(unsafe) var onAudioLevel: (@Sendable (Float) -> Void)?
    /// Fired if no audio samples arrive within the first few seconds of
    /// recording. Gives the UI a chance to warn the user before they
    /// record a long silent clip.
    nonisolated(unsafe) var onAudioNotDetected: (@Sendable () -> Void)?
    /// Fired when the SCStream stops externally (e.g. user clicks "Stop
    /// Sharing" in the macOS menu bar). Not called when stop() is invoked
    /// programmatically — only for unexpected/external termination.
    nonisolated(unsafe) var onStreamStoppedExternally: (@Sendable () -> Void)?
    nonisolated(unsafe) private var stopCalledProgrammatically = false

    private let outputURL: URL
    private let targetDisplayID: CGDirectDisplayID?
    private let micDeviceUniqueID: String?
    private let cameraOverlayWindowID: CGWindowID?
    private let captureQueue = DispatchQueue(label: "com.yardtalk.capture", qos: .userInteractive)

    private let includeSelfInRecording: Bool

    nonisolated init(outputURL: URL, displayID: CGDirectDisplayID? = nil, micDeviceUniqueID: String? = nil, cameraOverlayWindowID: CGWindowID? = nil, includeSelfInRecording: Bool = false) {
        self.outputURL = outputURL
        self.targetDisplayID = displayID
        self.micDeviceUniqueID = micDeviceUniqueID
        self.cameraOverlayWindowID = cameraOverlayWindowID
        self.includeSelfInRecording = includeSelfInRecording
        super.init()
    }

    /// Configures and starts the capture pipeline. Order is load-bearing:
    /// AVAssetWriter requires inputs added before startWriting(), and
    /// neither capture source should start producing samples until the
    /// writer is ready to receive them.
    nonisolated func start() async throws {
        Logger.recorder.info("start() begin — output: \(self.outputURL.lastPathComponent, privacy: .public)")
        try prepareWriter()
        try await configureScreenCapture()
        try configureMicCapture()

        guard let writer, writer.startWriting() else {
            let message = writer?.error?.localizedDescription ?? "startWriting returned false"
            Logger.recorder.error("startWriting failed: \(message, privacy: .private)")
            throw SessionRecorderError.writerSetupFailed(message)
        }

        captureSession?.startRunning()
        let sessionRunning = captureSession?.isRunning ?? false
        Logger.recorder.info("mic session running: \(sessionRunning ? "yes" : "NO", privacy: .public), device: \(self.micDeviceUniqueID ?? "system-default", privacy: .public)")
        if let stream {
            try await stream.startCapture()
        }
        startedAt = Date()
        startAudioLevelMonitoring()
        startAudioWatchdog()
        Logger.recorder.info("start() complete — capture running")
    }

    /// Stops the pipeline, finalizes the MP4. Returns its file URL and the
    /// wall-clock duration. If no samples were ever processed (a release
    /// faster than the capture pipeline could spin up), the writer is
    /// cancelled and the output file removed; duration returned is 0 and
    /// the caller is responsible for not registering a clip.
    nonisolated func stop() async throws -> (url: URL, duration: TimeInterval) {
        let finishedAt = Date()
        Logger.recorder.info("stop() begin")

        stopAudioLevelMonitoring()
        stopAudioWatchdog()
        stopCalledProgrammatically = true

        if let stream {
            try? await stream.stopCapture()
        }
        captureSession?.stopRunning()

        // Drain any in-flight sample handlers before marking inputs
        // finished, otherwise late appends would race with finishWriting.
        captureQueue.sync { }

        let duration: TimeInterval = startedAt.map { finishedAt.timeIntervalSince($0) } ?? 0

        guard let writer else {
            Logger.recorder.warning("stop() — writer was nil (start may have failed)")
            return (outputURL, duration)
        }

        guard anchorHostTime != nil else {
            // No samples ever arrived. Calling finishWriting() on a writer
            // that never had startSession() called produces an MP4 with no
            // moov atom — unplayable. Cancel and delete instead. Return
            // duration 0 so the caller discards the clip.
            Logger.recorder.warning("stop() — no samples received, cancelling writer (wall-clock was \(duration, privacy: .public)s)")
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            return (outputURL, 0)
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        await writer.finishWriting()

        if writer.status == .completed {
            Logger.recorder.info("stop() — writer completed cleanly, duration=\(duration, privacy: .public)s")
        } else {
            let errorMessage = writer.error?.localizedDescription ?? "no error"
            Logger.recorder.error("stop() — writer ended with status=\(writer.status.rawValue, privacy: .public) error=\(errorMessage, privacy: .private)")
        }

        return (outputURL, duration)
    }

    // MARK: - Setup

    private nonisolated func prepareWriter() throws {
        try? FileManager.default.removeItem(at: outputURL)
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw SessionRecorderError.writerSetupFailed(error.localizedDescription)
        }
    }

    private nonisolated func configureScreenCapture() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw SessionRecorderError.streamFailed(error.localizedDescription)
        }

        let display: SCDisplay
        if let targetID = targetDisplayID,
           let match = content.displays.first(where: { $0.displayID == targetID }) {
            display = match
        } else if let first = content.displays.first {
            display = first
        } else {
            throw SessionRecorderError.noDisplay
        }

        let excluded: [SCRunningApplication]
        if includeSelfInRecording {
            excluded = []
        } else {
            excluded = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
        }
        var exceptedWindows: [SCWindow] = []
        if !includeSelfInRecording,
           let overlayID = cameraOverlayWindowID,
           let scWindow = content.windows.first(where: { $0.windowID == overlayID }) {
            exceptedWindows.append(scWindow)
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excluded,
            exceptingWindows: exceptedWindows
        )

        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30 fps cap
        config.queueDepth = 5
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: display.width,
            AVVideoHeightKey: display.height,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        guard let writer, writer.canAdd(videoInput) else {
            throw SessionRecorderError.writerSetupFailed("cannot add video input")
        }
        writer.add(videoInput)
        self.videoInput = videoInput
        self.pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: nil
        )

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        } catch {
            throw SessionRecorderError.streamFailed("addStreamOutput: \(error.localizedDescription)")
        }
        self.stream = stream
    }

    private nonisolated func configureMicCapture() throws {
        let micDevice: AVCaptureDevice
        if let uid = micDeviceUniqueID,
           let selected = AVCaptureDevice(uniqueID: uid) {
            micDevice = selected
        } else if let fallback = AVCaptureDevice.default(for: .audio) {
            micDevice = fallback
        } else {
            throw SessionRecorderError.noMicrophone
        }

        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: micDevice)
        } catch {
            throw SessionRecorderError.captureSetupFailed(error.localizedDescription)
        }
        guard session.canAddInput(input) else {
            throw SessionRecorderError.captureSetupFailed("cannot add mic input")
        }
        session.addInput(input)

        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(audioOutput) else {
            throw SessionRecorderError.captureSetupFailed("cannot add audio output")
        }
        session.addOutput(audioOutput)

        // Let the audio output recommend settings that match the format it
        // will deliver, then patch a hole: in testing, the recommended dict
        // came back without AVEncoderBitRateKey, which leaves the AAC
        // encoder with an invalid default — the writer silently transitions
        // to .failed mid-recording and finishWriting() then no-ops, leaving
        // a moov-atom-less MP4. Forcing a sane default bitrate when one
        // isn't recommended fixes that.
        var audioSettings: [String: Any] = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4)
            ?? [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
            ]
        if audioSettings[AVEncoderBitRateKey] == nil {
            audioSettings[AVEncoderBitRateKey] = 64_000
        }
        Logger.recorder.info("audio writer settings: \("\(audioSettings)", privacy: .public)")
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard let writer, writer.canAdd(audioInput) else {
            throw SessionRecorderError.writerSetupFailed("cannot add audio input")
        }
        writer.add(audioInput)
        self.audioInput = audioInput
        self.audioOutput = audioOutput
        self.captureSession = session
    }

    // MARK: - Sample handling (captureQueue)

    private nonisolated func handleSampleOnCaptureQueue(_ sb: CMSampleBuffer, isVideo: Bool) {
        guard let writer else { return }
        guard CMSampleBufferDataIsReady(sb) else { return }

        // If the writer slipped into .failed mid-recording (encoder choked,
        // PTS mismatch, etc.), log it once so we know which sample type
        // tripped it. Otherwise we silently drop every subsequent sample
        // and finishWriting() no-ops on a .failed writer — exactly the
        // moov-atom-less broken-file outcome seen in earlier rounds.
        if writer.status != .writing {
            if writer.status == .failed && !didLogWriterFailure {
                didLogWriterFailure = true
                let kind = isVideo ? "video" : "audio"
                let errorMessage = writer.error?.localizedDescription ?? "no error"
                Logger.recorder.error("writer entered .failed during \(kind, privacy: .public) sample: \(errorMessage, privacy: .private)")
            }
            return
        }

        // One-time format dump on the first audio sample so we can see what
        // PCM format AVCaptureAudioDataOutput is actually delivering. If
        // sampleRate / channels disagree with the writer's expected encoding
        // we get silent AAC tracks.
        if !isVideo && !didReceiveAudioSample {
            didReceiveAudioSample = true
        }

        if !isVideo && !didLogAudioFormat {
            didLogAudioFormat = true
            if let formatDesc = CMSampleBufferGetFormatDescription(sb),
               let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                let asbd = asbdPtr.pointee
                Logger.recorder.info("audio input format: \(asbd.mSampleRate, privacy: .public) Hz, \(asbd.mChannelsPerFrame, privacy: .public) ch, formatID=\(asbd.mFormatID, privacy: .public), bytesPerFrame=\(asbd.mBytesPerFrame, privacy: .public)")
            } else {
                Logger.recorder.info("audio input format: <unavailable>")
            }
        }

        // Single host-clock anchor for both inputs — see file header.
        let now = CMClockGetTime(CMClockGetHostTimeClock())

        if anchorHostTime == nil {
            anchorHostTime = now
            writer.startSession(atSourceTime: .zero)
            let kind = isVideo ? "video" : "audio"
            Logger.recorder.info("First sample arrived (\(kind, privacy: .public)); session started at zero")
        }

        let relativePTS = CMTimeSubtract(now, anchorHostTime!)

        if isVideo {
            guard let adaptor = pixelBufferAdaptor,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sb),
                  adaptor.assetWriterInput.isReadyForMoreMediaData else { return }

            if !adaptor.append(pixelBuffer, withPresentationTime: relativePTS) {
                let errorMessage = writer.error?.localizedDescription ?? "no error"
                Logger.recorder.error("append failed for video: \(errorMessage, privacy: .public)")
            }
        } else {
            var newTiming = CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(sb),
                presentationTimeStamp: relativePTS,
                decodeTimeStamp: .invalid
            )

            var rebased: CMSampleBuffer?
            let result = CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sb,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &newTiming,
                sampleBufferOut: &rebased
            )

            guard result == noErr, let buffer = rebased else {
                Logger.recorder.warning("CMSampleBufferCreateCopyWithNewTiming returned \(result, privacy: .public)")
                return
            }

            guard let audioInput, audioInput.isReadyForMoreMediaData else { return }
            if !audioInput.append(buffer) {
                let errorMessage = writer.error?.localizedDescription ?? "no error"
                Logger.recorder.error("append failed for audio: \(errorMessage, privacy: .public)")
            }
        }
    }

    // MARK: - Audio level monitoring

    private nonisolated func startAudioLevelMonitoring() {
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard let audioOutput = self.audioOutput,
                  let connection = audioOutput.connections.first,
                  let channel = connection.audioChannels.first else {
                return
            }
            let dB = channel.averagePowerLevel
            // Map -50 dB (mic essentially silent) to 0 dB (full scale) onto
            // 0...1. -50 dB chosen empirically: ambient room noise sits
            // around -55 to -45, normal speech -30 to -10, peaks at 0 dB.
            let normalized = max(0, min(1, (dB + 50) / 50))
            self.onAudioLevel?(normalized)
        }
        timer.resume()
        audioLevelTimer = timer
    }

    private nonisolated func stopAudioLevelMonitoring() {
        audioLevelTimer?.cancel()
        audioLevelTimer = nil
        onAudioLevel?(0)
    }

    // MARK: - Audio watchdog

    private nonisolated func startAudioWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + .seconds(3))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if !self.didReceiveAudioSample {
                Logger.recorder.warning("No audio samples received after 3s — mic may not be delivering data")
                self.onAudioNotDetected?()
            }
            self.audioWatchdogTimer?.cancel()
            self.audioWatchdogTimer = nil
        }
        timer.resume()
        audioWatchdogTimer = timer
    }

    private nonisolated func stopAudioWatchdog() {
        audioWatchdogTimer?.cancel()
        audioWatchdogTimer = nil
    }
}

// MARK: - SCStreamDelegate

extension SessionRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger.recorder.error("SCStream stopped with error: \(error.localizedDescription, privacy: .public)")
        if !stopCalledProgrammatically {
            Logger.recorder.warning("stream stopped externally (user stopped sharing?) — notifying manager")
            onStreamStoppedExternally?()
        }
    }
}

// MARK: - SCStreamOutput

extension SessionRecorder: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        handleSampleOnCaptureQueue(sampleBuffer, isVideo: true)
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension SessionRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        handleSampleOnCaptureQueue(sampleBuffer, isVideo: false)
    }
}
