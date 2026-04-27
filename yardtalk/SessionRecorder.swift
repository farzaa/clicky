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

    /// Fired ~20Hz during recording with a normalized 0...1 level so the UI
    /// can show a live mic meter. A flat meter while recording is a visible
    /// signal that the mic isn't actually capturing — the user can release,
    /// fix the input, and try again.
    nonisolated(unsafe) var onAudioLevel: (@Sendable (Float) -> Void)?

    private let outputURL: URL
    private let captureQueue = DispatchQueue(label: "com.yardtalk.capture", qos: .userInteractive)

    nonisolated init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }

    /// Configures and starts the capture pipeline. Order is load-bearing:
    /// AVAssetWriter requires inputs added before startWriting(), and
    /// neither capture source should start producing samples until the
    /// writer is ready to receive them.
    nonisolated func start() async throws {
        NSLog("YardTalk[recorder] start() begin — output: %@", outputURL.lastPathComponent)
        Logger.recorder.info("start() begin — output: \(self.outputURL.lastPathComponent, privacy: .public)")
        try prepareWriter()
        try await configureScreenCapture()
        try configureMicCapture()

        guard let writer, writer.startWriting() else {
            let message = writer?.error?.localizedDescription ?? "startWriting returned false"
            NSLog("YardTalk[recorder] startWriting failed: %@", message)
            Logger.recorder.error("startWriting failed: \(message, privacy: .public)")
            throw SessionRecorderError.writerSetupFailed(message)
        }

        // Mic before screen so the audio session is hot when the first
        // video frame arrives — avoids dropping early audio samples.
        captureSession?.startRunning()
        if let stream {
            try await stream.startCapture()
        }
        startedAt = Date()
        startAudioLevelMonitoring()
        NSLog("YardTalk[recorder] start() complete — capture running")
        Logger.recorder.info("start() complete — capture running")
    }

    /// Stops the pipeline, finalizes the MP4. Returns its file URL and the
    /// wall-clock duration. If no samples were ever processed (a release
    /// faster than the capture pipeline could spin up), the writer is
    /// cancelled and the output file removed; duration returned is 0 and
    /// the caller is responsible for not registering a clip.
    nonisolated func stop() async throws -> (url: URL, duration: TimeInterval) {
        let finishedAt = Date()
        NSLog("YardTalk[recorder] stop() begin")
        Logger.recorder.info("stop() begin")

        stopAudioLevelMonitoring()

        if let stream {
            try? await stream.stopCapture()
        }
        captureSession?.stopRunning()

        // Drain any in-flight sample handlers before marking inputs
        // finished, otherwise late appends would race with finishWriting.
        captureQueue.sync { }

        let duration: TimeInterval = startedAt.map { finishedAt.timeIntervalSince($0) } ?? 0

        guard let writer else {
            NSLog("YardTalk[recorder] stop() — writer was nil (start may have failed)")
            return (outputURL, duration)
        }

        guard anchorHostTime != nil else {
            // No samples ever arrived. Calling finishWriting() on a writer
            // that never had startSession() called produces an MP4 with no
            // moov atom — unplayable. Cancel and delete instead.
            NSLog("YardTalk[recorder] stop() — no samples received, cancelling writer")
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            return (outputURL, duration)
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        await writer.finishWriting()

        if writer.status == .completed {
            NSLog("YardTalk[recorder] stop() — writer completed cleanly, duration=%.2fs", duration)
        } else {
            let errorMessage = writer.error?.localizedDescription ?? "no error"
            NSLog("YardTalk[recorder] stop() — writer ended with status=%ld error=%@",
                  writer.status.rawValue, errorMessage)
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

        guard let display = content.displays.first else {
            throw SessionRecorderError.noDisplay
        }

        // Exclude YardTalk itself so the menu bar panel doesn't show up
        // in the recording when it's open during a hotkey-held capture.
        let excluded = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excluded,
            exceptingWindows: []
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

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        } catch {
            throw SessionRecorderError.streamFailed("addStreamOutput: \(error.localizedDescription)")
        }
        self.stream = stream
    }

    private nonisolated func configureMicCapture() throws {
        guard let micDevice = AVCaptureDevice.default(for: .audio) else {
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

        // Let the audio output and the writer agree on a format. Hardcoding
        // AAC 48 kHz mono / 64 kbps in v1 produced silent (-91 dB) AAC tracks
        // because the writer's encoder couldn't reconcile the device's native
        // PCM format with the requested output. recommendedAudioSettingsForAssetWriter
        // returns settings that match what the output will deliver so the
        // encoder has no work to do beyond AAC packaging.
        let audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4)
            ?? [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ] as [String: Any]
        NSLog("YardTalk[recorder] audio writer settings: %@", "\(audioSettings)")
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
        guard writer.status == .writing else { return }

        // One-time format dump on the first audio sample so we can see what
        // PCM format AVCaptureAudioDataOutput is actually delivering. If
        // sampleRate / channels disagree with the writer's expected encoding
        // we get silent AAC tracks.
        if !isVideo && !didLogAudioFormat {
            didLogAudioFormat = true
            if let formatDesc = CMSampleBufferGetFormatDescription(sb),
               let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                let asbd = asbdPtr.pointee
                NSLog("YardTalk[recorder] audio input format: %.0f Hz, %u ch, formatID=%u, bytesPerFrame=%u",
                      asbd.mSampleRate, asbd.mChannelsPerFrame, asbd.mFormatID, asbd.mBytesPerFrame)
            } else {
                NSLog("YardTalk[recorder] audio input format: <unavailable>")
            }
        }

        // Single host-clock anchor for both inputs — see file header.
        let now = CMClockGetTime(CMClockGetHostTimeClock())

        if anchorHostTime == nil {
            anchorHostTime = now
            writer.startSession(atSourceTime: .zero)
            let kind = isVideo ? "video" : "audio"
            NSLog("YardTalk[recorder] first sample arrived (%@); session started at zero", kind)
            Logger.recorder.info("First sample arrived (\(kind, privacy: .public)); session started at zero")
        }

        let relativePTS = CMTimeSubtract(now, anchorHostTime!)

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

        let input = isVideo ? videoInput : audioInput
        guard let input, input.isReadyForMoreMediaData else { return }

        if !input.append(buffer) {
            let kind = isVideo ? "video" : "audio"
            let errorMessage = writer.error?.localizedDescription ?? "no error"
            Logger.recorder.error(
                "append failed for \(kind, privacy: .public): \(errorMessage, privacy: .public)"
            )
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
        // Reset the published level so the meter doesn't freeze at the
        // last reading after recording ends.
        onAudioLevel?(0)
    }
}

// MARK: - SCStreamDelegate

extension SessionRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger.recorder.error("SCStream stopped with error: \(error.localizedDescription, privacy: .public)")
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
