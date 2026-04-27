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

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

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
    nonisolated(unsafe) private var sessionStartTime: CMTime?
    nonisolated(unsafe) private var stream: SCStream?
    nonisolated(unsafe) private var captureSession: AVCaptureSession?
    nonisolated(unsafe) private var startedAt: Date?

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
        try prepareWriter()
        let display = try await configureScreenCapture()
        try configureMicCapture()

        guard let writer, writer.startWriting() else {
            throw SessionRecorderError.writerSetupFailed(
                writer?.error?.localizedDescription ?? "startWriting returned false"
            )
        }

        // Mic before screen so the audio session is hot when the first
        // video frame arrives — avoids dropping early audio samples.
        captureSession?.startRunning()
        if let stream {
            try await stream.startCapture()
        }
        startedAt = Date()
        _ = display // silence unused
    }

    /// Stops the pipeline, finalizes the MP4. Returns its file URL and the
    /// wall-clock duration (close enough for v1 metadata; the exact PTS
    /// duration is encoded in the MP4 itself).
    nonisolated func stop() async throws -> (url: URL, duration: TimeInterval) {
        let finishedAt = Date()

        if let stream {
            try? await stream.stopCapture()
        }
        captureSession?.stopRunning()

        // Drain any in-flight sample handlers before marking inputs
        // finished, otherwise late appends would race with finishWriting.
        captureQueue.sync { }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        if let writer {
            await writer.finishWriting()
        }

        let duration: TimeInterval = startedAt.map { finishedAt.timeIntervalSince($0) } ?? 0
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

    private nonisolated func configureScreenCapture() async throws -> SCDisplay {
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

        return display
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

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard let writer, writer.canAdd(audioInput) else {
            throw SessionRecorderError.writerSetupFailed("cannot add audio input")
        }
        writer.add(audioInput)
        self.audioInput = audioInput
        self.captureSession = session
    }

    // MARK: - Sample handling (captureQueue)

    private nonisolated func handleSampleOnCaptureQueue(_ sb: CMSampleBuffer, isVideo: Bool) {
        guard let writer else { return }
        guard CMSampleBufferDataIsReady(sb) else { return }
        guard writer.status == .writing else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if sessionStartTime == nil {
            sessionStartTime = pts
            writer.startSession(atSourceTime: pts)
        }

        let input = isVideo ? videoInput : audioInput
        if let input, input.isReadyForMoreMediaData {
            input.append(sb)
        }
    }
}

// MARK: - SCStreamDelegate

extension SessionRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("⚠️ SessionRecorder: SCStream stopped with error: \(error)")
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
