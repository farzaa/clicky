//
//  CameraOverlayWindow.swift
//  yardtalk
//
//  Floating camera preview bubble that ScreenCaptureKit captures
//  alongside the display. Draggable, right-click for shape/size.
//  SessionRecorder uses `exceptingWindows` to include this window
//  in the recording while excluding the rest of YardTalk.
//

import AVFoundation
import AppKit
import Observation
import OSLog

extension Logger {
    static let camera = Logger(subsystem: "com.yardtalk.app", category: "camera")
}

// MARK: - Types

enum CameraOverlayShape: String, Codable, CaseIterable, Sendable {
    case circle
    case roundedRect

    var displayName: String {
        switch self {
        case .circle: return "Circle"
        case .roundedRect: return "Rounded Rectangle"
        }
    }
}

enum CameraOverlaySize: String, Codable, CaseIterable, Sendable {
    case small
    case medium
    case large

    var dimension: CGFloat {
        switch self {
        case .small: return 120
        case .medium: return 180
        case .large: return 240
        }
    }

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}

struct CameraDeviceInfo: Identifiable, Equatable {
    let id: String
    let name: String
}

// MARK: - Manager

@MainActor
@Observable
final class CameraOverlayManager {
    private(set) var isEnabled = false
    private(set) var availableCameras: [CameraDeviceInfo] = []

    var selectedCameraDeviceID: String? {
        didSet { UserDefaults.standard.set(selectedCameraDeviceID, forKey: "cameraOverlayDeviceID") }
    }

    @ObservationIgnored
    private(set) var shape: CameraOverlayShape = .circle

    @ObservationIgnored
    private(set) var size: CameraOverlaySize = .medium

    @ObservationIgnored
    private var overlayWindow: CameraOverlayNSWindow?

    @ObservationIgnored
    private var captureSession: AVCaptureSession?

    @ObservationIgnored
    private var deviceObservers: [NSObjectProtocol] = []

    var overlayWindowNumber: Int? {
        overlayWindow?.windowNumber
    }

    init() {
        loadPreferences()
        refreshCameras()
        observeDeviceChanges()
    }

    private func observeDeviceChanges() {
        let nc = NotificationCenter.default
        let connected = nc.addObserver(
            forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.object as? AVCaptureDevice)?.hasMediaType(.video) == true else { return }
            guard let self else { return }
            Task { @MainActor in self.refreshCameras() }
        }
        let disconnected = nc.addObserver(
            forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.object as? AVCaptureDevice)?.hasMediaType(.video) == true else { return }
            guard let self else { return }
            Task { @MainActor in
                self.refreshCameras()
                if self.isEnabled, self.selectedCameraDeviceID == nil {
                    self.hideOverlay()
                }
            }
        }
        deviceObservers = [connected, disconnected]
    }

    func refreshCameras() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        availableCameras = discovery.devices.map {
            CameraDeviceInfo(id: $0.uniqueID, name: $0.localizedName)
        }
        if selectedCameraDeviceID == nil ||
            !availableCameras.contains(where: { $0.id == selectedCameraDeviceID }) {
            selectedCameraDeviceID = availableCameras.first?.id
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            switch status {
            case .authorized:
                isEnabled = true
                UserDefaults.standard.set(true, forKey: "cameraOverlayEnabled")
                showOverlay()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    Task { @MainActor [weak self] in
                        guard granted else { return }
                        self?.isEnabled = true
                        UserDefaults.standard.set(true, forKey: "cameraOverlayEnabled")
                        self?.showOverlay()
                    }
                }
            default:
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            isEnabled = false
            UserDefaults.standard.set(false, forKey: "cameraOverlayEnabled")
            hideOverlay()
        }
    }

    func startIfEnabled() {
        guard isEnabled else { return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            showOverlay()
        } else {
            isEnabled = false
            UserDefaults.standard.set(false, forKey: "cameraOverlayEnabled")
        }
    }

    func switchCamera(to deviceID: String) {
        selectedCameraDeviceID = deviceID
        if isEnabled {
            hideOverlay()
            showOverlay()
        }
    }

    func showOverlay() {
        guard overlayWindow == nil else {
            Logger.camera.info("showOverlay skipped — window already exists")
            return
        }
        guard let deviceID = selectedCameraDeviceID else {
            Logger.camera.info("showOverlay skipped — no selectedCameraDeviceID")
            return
        }
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            Logger.camera.warning("showOverlay skipped — device not found for ID: \(deviceID, privacy: .public)")
            return
        }

        Logger.camera.info("setting up capture session for \(device.localizedName, privacy: .public)")
        let session = AVCaptureSession()
        session.sessionPreset = .medium

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                Logger.camera.error("canAddInput returned false")
                return
            }
            session.addInput(input)
        } catch {
            Logger.camera.error("AVCaptureDeviceInput failed: \(error.localizedDescription, privacy: .private)")
            return
        }

        let window = CameraOverlayNSWindow(
            shape: shape,
            size: size,
            captureSession: session
        )

        if let x = UserDefaults.standard.object(forKey: "cameraOverlayX") as? CGFloat,
           let y = UserDefaults.standard.object(forKey: "cameraOverlayY") as? CGFloat {
            let candidate = NSPoint(x: x, y: y)
            let windowRect = NSRect(origin: candidate, size: window.frame.size)
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(windowRect) }
            if onScreen {
                window.setFrameOrigin(candidate)
            } else {
                Logger.camera.info("saved position (\(x, privacy: .public), \(y, privacy: .public)) is off-screen — using default")
            }
        }

        window.onShapeChanged = { [weak self] newShape in
            self?.shape = newShape
            UserDefaults.standard.set(newShape.rawValue, forKey: "cameraOverlayShape")
        }
        window.onSizeChanged = { [weak self] newSize in
            self?.size = newSize
            UserDefaults.standard.set(newSize.rawValue, forKey: "cameraOverlaySize")
        }
        window.onPositionChanged = { origin in
            UserDefaults.standard.set(origin.x, forKey: "cameraOverlayX")
            UserDefaults.standard.set(origin.y, forKey: "cameraOverlayY")
        }

        window.orderFront(nil)
        session.startRunning()
        Logger.camera.info("overlay shown, session running: \(session.isRunning ? "yes" : "NO", privacy: .public)")

        self.overlayWindow = window
        self.captureSession = session
    }

    func moveToDisplay(_ displayID: CGDirectDisplayID) {
        guard let window = overlayWindow else { return }
        let targetScreen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
        guard let screen = targetScreen else { return }
        guard !screen.visibleFrame.intersects(window.frame) else { return }

        let dim = window.frame.size
        let origin = NSPoint(
            x: screen.visibleFrame.maxX - dim.width - 20,
            y: screen.visibleFrame.minY + 20
        )
        window.setFrameOrigin(origin)
        UserDefaults.standard.set(origin.x, forKey: "cameraOverlayX")
        UserDefaults.standard.set(origin.y, forKey: "cameraOverlayY")
        Logger.camera.info("moved overlay to display \(displayID, privacy: .public)")
    }

    func hideOverlay() {
        if let window = overlayWindow {
            UserDefaults.standard.set(window.frame.origin.x, forKey: "cameraOverlayX")
            UserDefaults.standard.set(window.frame.origin.y, forKey: "cameraOverlayY")
        }
        captureSession?.stopRunning()
        captureSession = nil
        overlayWindow?.close()
        overlayWindow = nil
    }

    private func loadPreferences() {
        isEnabled = UserDefaults.standard.bool(forKey: "cameraOverlayEnabled")
        selectedCameraDeviceID = UserDefaults.standard.string(forKey: "cameraOverlayDeviceID")
        if let raw = UserDefaults.standard.string(forKey: "cameraOverlayShape"),
           let s = CameraOverlayShape(rawValue: raw) { shape = s }
        if let raw = UserDefaults.standard.string(forKey: "cameraOverlaySize"),
           let s = CameraOverlaySize(rawValue: raw) { size = s }
    }
}

// MARK: - NSWindow

final class CameraOverlayNSWindow: NSWindow {
    private let previewView: CameraPreviewView
    private var currentShape: CameraOverlayShape
    private var currentSize: CameraOverlaySize

    private var isFullscreen = false
    private var pipFrame: NSRect = .zero
    private var pipShape: CameraOverlayShape = .circle
    private var hintField: NSTextField?

    var onShapeChanged: ((CameraOverlayShape) -> Void)?
    var onSizeChanged: ((CameraOverlaySize) -> Void)?
    var onPositionChanged: ((NSPoint) -> Void)?

    init(shape: CameraOverlayShape, size: CameraOverlaySize, captureSession: AVCaptureSession) {
        self.currentShape = shape
        self.currentSize = size
        self.pipShape = shape
        let dim = size.dimension
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let origin = NSPoint(
            x: screenFrame.maxX - dim - 20,
            y: screenFrame.minY + 20
        )

        previewView = CameraPreviewView(captureSession: captureSession, shape: shape)

        super.init(
            contentRect: NSRect(origin: origin, size: NSSize(width: dim, height: dim)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        isMovableByWindowBackground = true
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        contentView = previewView
    }

    override var canBecomeKey: Bool { false }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if event.clickCount == 2 {
            toggleFullscreen()
        } else {
            onPositionChanged?(frame.origin)
        }
    }

    private func toggleFullscreen() {
        guard let screen = self.screen ?? NSScreen.main else { return }

        if isFullscreen {
            shrinkToPIP()
        } else {
            expandToFullscreen(on: screen)
        }
    }

    private func expandToFullscreen(on screen: NSScreen) {
        pipFrame = frame
        pipShape = currentShape
        isFullscreen = true
        isMovableByWindowBackground = false

        previewView.updateShape(.roundedRect, cornerFraction: 0)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(screen.frame, display: true)
        } completionHandler: { [weak self] in
            self?.showFullscreenHint()
        }
    }

    private func shrinkToPIP() {
        isFullscreen = false
        dismissHint()

        previewView.updateShape(pipShape)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(self.pipFrame, display: true)
        } completionHandler: { [weak self] in
            self?.isMovableByWindowBackground = true
        }
    }

    private func showFullscreenHint() {
        guard hintField == nil, let contentView else { return }

        let label = NSTextField(labelWithString: "Double-click to minimize")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.5)
        label.drawsBackground = true
        label.isBezeled = false
        label.alignment = .center
        label.sizeToFit()
        label.wantsLayer = true
        label.layer?.cornerRadius = 6

        let padding: CGFloat = 16
        label.frame.size.width += padding * 2
        label.frame.size.height += 8
        label.frame.origin = NSPoint(
            x: (contentView.bounds.width - label.frame.width) / 2,
            y: 40
        )
        label.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        label.alphaValue = 0

        contentView.addSubview(label)
        hintField = label

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            label.animator().alphaValue = 1
        } completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.fadeOutHint()
            }
        }
    }

    private func fadeOutHint() {
        guard let label = hintField else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            label.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.dismissHint()
        }
    }

    private func dismissHint() {
        hintField?.removeFromSuperview()
        hintField = nil
    }

    func updateShape(_ shape: CameraOverlayShape) {
        currentShape = shape
        previewView.updateShape(shape)
    }

    func updateShape(_ shape: CameraOverlayShape, cornerFraction: CGFloat) {
        currentShape = shape
        previewView.updateShape(shape, cornerFraction: cornerFraction)
    }

    func updateSize(_ newSize: CameraOverlaySize) {
        currentSize = newSize
        let dim = newSize.dimension
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let newOrigin = NSPoint(x: center.x - dim / 2, y: center.y - dim / 2)
        setFrame(NSRect(origin: newOrigin, size: NSSize(width: dim, height: dim)), display: true, animate: true)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        if isFullscreen {
            let minimize = NSMenuItem(title: "Exit Fullscreen", action: #selector(minimizeAction), keyEquivalent: "")
            minimize.target = self
            menu.addItem(minimize)
        } else {
            let fullscreen = NSMenuItem(title: "Fullscreen", action: #selector(fullscreenAction), keyEquivalent: "")
            fullscreen.target = self
            menu.addItem(fullscreen)

            menu.addItem(.separator())

            let shapeItem = NSMenuItem(title: "Shape", action: nil, keyEquivalent: "")
            let shapeMenu = NSMenu()
            for shape in CameraOverlayShape.allCases {
                let item = NSMenuItem(title: shape.displayName, action: #selector(shapeAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = shape.rawValue
                item.state = shape == currentShape ? .on : .off
                shapeMenu.addItem(item)
            }
            shapeItem.submenu = shapeMenu
            menu.addItem(shapeItem)

            let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
            let sizeMenu = NSMenu()
            for s in CameraOverlaySize.allCases {
                let item = NSMenuItem(title: s.displayName, action: #selector(sizeAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = s.rawValue
                item.state = s == currentSize ? .on : .off
                sizeMenu.addItem(item)
            }
            sizeItem.submenu = sizeMenu
            menu.addItem(sizeItem)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: previewView)
    }

    @objc private func fullscreenAction() {
        guard let screen = self.screen ?? NSScreen.main else { return }
        expandToFullscreen(on: screen)
    }

    @objc private func minimizeAction() {
        shrinkToPIP()
    }

    @objc private func shapeAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let shape = CameraOverlayShape(rawValue: rawValue) else { return }
        updateShape(shape)
        onShapeChanged?(shape)
    }

    @objc private func sizeAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let size = CameraOverlaySize(rawValue: rawValue) else { return }
        updateSize(size)
        onSizeChanged?(size)
    }
}

// MARK: - Preview View

final class CameraPreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let borderLayer = CAShapeLayer()
    private var currentShape: CameraOverlayShape
    private var cornerFractionOverride: CGFloat?

    init(captureSession: AVCaptureSession, shape: CameraOverlayShape) {
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        currentShape = shape
        super.init(frame: .zero)

        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)

        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.25).cgColor
        borderLayer.lineWidth = 2
        layer?.addSublayer(borderLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        updateMask()
    }

    func updateShape(_ shape: CameraOverlayShape) {
        cornerFractionOverride = nil
        currentShape = shape
        updateMask()
    }

    func updateShape(_ shape: CameraOverlayShape, cornerFraction: CGFloat) {
        cornerFractionOverride = cornerFraction
        currentShape = shape
        updateMask()
    }

    private func updateMask() {
        let rect = bounds
        guard rect.width > 0, rect.height > 0 else { return }

        let path: CGPath
        if let fraction = cornerFractionOverride, fraction <= 0 {
            // Fullscreen — no mask, no border
            layer?.mask = nil
            borderLayer.path = nil
            borderLayer.frame = rect
            return
        }

        switch currentShape {
        case .circle:
            path = CGPath(ellipseIn: rect, transform: nil)
        case .roundedRect:
            let fraction = cornerFractionOverride ?? 0.15
            let radius = min(rect.width, rect.height) * fraction
            path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }

        let maskLayer = CAShapeLayer()
        maskLayer.path = path
        layer?.mask = maskLayer

        borderLayer.path = path
        borderLayer.frame = rect
    }
}
