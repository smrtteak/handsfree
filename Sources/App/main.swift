import AppKit
import AVFoundation
import ApplicationServices
import Vision

// MARK: - Log

/// Gesture numbers only, never camera images. Used to tune thresholds.
final class EventLog {
    let url: URL
    private let queue = DispatchQueue(label: "handsfree.log")
    private let handle: FileHandle?

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Handsfree")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("gestures.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func write(_ message: String) {
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        queue.async { [handle] in
            handle?.write(Data("\(stamp) \(message)\n".utf8))
        }
    }
}

// MARK: - Config

final class ConfigFile {
    let url: URL
    private var modified: Date?

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Handsfree")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")
        // Holds overrides only, so changed defaults still reach this file's owner.
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data("{}\n".utf8).write(to: url)
        }
    }

    /// Returns new settings only when the file changed and still parses.
    func reloadIfChanged(log: EventLog) -> Settings? {
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard date != modified, let data = try? Data(contentsOf: url) else { return nil }
        modified = date
        do {
            return try Settings.decode(from: data)
        } catch {
            log.write("config-error \(error)")
            return nil
        }
    }
}

// MARK: - Sending keys

enum KeySender {
    static func press(_ key: Key) {
        let code: CGKeyCode
        switch key {
        case .space: code = 49
        case .left: code = 123
        case .right: code = 124
        case .down: code = 125
        case .up: code = 126
        case .f: code = 3
        case .s: code = 1
        }
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }

    // System volume keys, because YouTube's arrow-key volume scrolls the page
    // unless the player itself has focus.
    static func press(_ key: MediaKey) {
        let code: Int32
        switch key {
        case .volumeUp: code = 0
        case .volumeDown: code = 1
        case .mute: code = 7
        }
        for down in [true, false] {
            let state: Int32 = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: Int((code << 16) | (state << 8)), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Controlling page contents

/// For sites with no keyboard shortcuts: finds real on-page buttons through the
/// browser's accessibility tree, and clicks or scrolls over the video.
final class PageController {
    private let queue = DispatchQueue(label: "handsfree.page")
    private let log: EventLog
    private var prepared = Set<String>()

    init(log: EventLog) {
        self.log = log
    }

    private struct Found {
        let element: AXUIElement
        let frame: CGRect
    }

    /// Browsers only build the page's tree once asked, and that takes a moment.
    func prepare(pid: pid_t, profile: SiteProfile) {
        queue.async { [self] in
            guard prepared.insert("\(pid)-\(profile.rawValue)").inserted else { return }
            let app = AXUIElementCreateApplication(pid)
            let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            let enhanced = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            log.write("page-prepare manual=\(manual.rawValue) enhanced=\(enhanced.rawValue)")
        }
    }

    func pressButton(_ labels: [String], pid: pid_t, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            let started = Date()
            var best: Found?
            var bestDistance = CGFloat.infinity
            let windowFrame = focusedWindowFrame(pid: pid) ?? .zero
            let wanted = Set(labels.map { $0.lowercased() })
            let visited = walk(pid: pid) { element, _, label, frame, _ in
                // Off-screen reels stay in the tree as slivers clamped to the window's edge.
                guard wanted.contains(label.lowercased()), frame.height >= 10,
                      windowFrame.contains(frame) else { return }
                let distance = abs(frame.midY - windowFrame.midY)
                if distance < bestDistance {
                    best = Found(element: element, frame: frame)
                    bestDistance = distance
                }
            }
            var pressed = false
            if let best { pressed = press(best) }
            log.write(String(format: "page-button %@ found=%d pressed=%d nodes=%d ms=%.0f",
                             labels.joined(separator: "/"), best == nil ? 0 : 1, pressed ? 1 : 0, visited,
                             Date().timeIntervalSince(started) * 1000))
            DispatchQueue.main.async { completion(pressed) }
        }
    }

    func clickVideo(pid: pid_t, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            let windowFrame = focusedWindowFrame(pid: pid) ?? .zero
            var url: String?
            walk(pid: pid) { element, role, _, _, _ in
                guard role == "AXWebArea", url == nil else { return }
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success {
                    url = (value as? URL)?.absoluteString
                }
            }
            // Away from reels the middle of the page could be a link to anything.
            let onReels = url.map { $0.contains("/reel") } ?? true
            log.write("page-click onReels=\(onReels) urlKnown=\(url != nil)")
            guard onReels, !windowFrame.isEmpty else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            click(at: CGPoint(x: windowFrame.midX, y: windowFrame.midY))
            DispatchQueue.main.async { completion(true) }
        }
    }

    func scroll(up: Bool, pid: pid_t, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard let frame = focusedWindowFrame(pid: pid) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            withCursor(at: CGPoint(x: frame.midX, y: frame.midY)) {
                let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                    wheel1: up ? 700 : -700, wheel2: 0, wheel3: 0)
                event?.post(tap: .cghidEventTap)
            }
            log.write("page-scroll up=\(up)")
            DispatchQueue.main.async { completion(true) }
        }
    }

    private func press(_ found: Found) -> Bool {
        // The name is often on an icon inside the element that takes the press.
        var element = found.element
        for _ in 0..<5 {
            if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent else { break }
            element = parent as! AXUIElement
        }
        click(at: CGPoint(x: found.frame.midX, y: found.frame.midY))
        return true
    }

    private func click(at point: CGPoint) {
        withCursor(at: point) {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                        mouseButton: .left)?.post(tap: .cghidEventTap)
                usleep(30_000)
            }
        }
    }

    /// Puts the cursor back afterwards, so nothing appears to have moved.
    private func withCursor(at point: CGPoint, _ body: () -> Void) {
        let original = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(point)
        usleep(40_000)
        body()
        usleep(40_000)
        if let original { CGWarpMouseCursorPosition(original) }
    }

    private func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        return (window as! AXUIElement)
    }

    private func frame(position: AnyObject?, size: AnyObject?) -> CGRect {
        var origin = CGPoint.zero
        var extent = CGSize.zero
        if let position, CFGetTypeID(position) == AXValueGetTypeID() {
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        }
        if let size, CFGetTypeID(size) == AXValueGetTypeID() {
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
        }
        return CGRect(origin: origin, size: extent)
    }

    private func focusedWindowFrame(pid: pid_t) -> CGRect? {
        guard let window = focusedWindow(pid: pid) else { return nil }
        var position: CFTypeRef?
        var size: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position)
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size)
        let result = frame(position: position, size: size)
        return result.isEmpty ? nil : result
    }

    /// Visits on-screen nodes of the focused window. Returns how many it looked at.
    @discardableResult
    private func walk(pid: pid_t, visit: (AXUIElement, String, String, CGRect, Bool) -> Void) -> Int {
        guard let window = focusedWindow(pid: pid), let bounds = focusedWindowFrame(pid: pid) else { return 0 }
        let attributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                          kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute] as CFArray
        var stack = [window]
        var count = 0
        while let element = stack.popLast(), count < 8000 {
            count += 1
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                  let values = raw as? [AnyObject], values.count == 6 else { continue }
            let box = frame(position: values[3], size: values[4])
            // Reels above and below the current one stay in the tree; skip them.
            if !box.isEmpty, !box.intersects(bounds) { continue }
            let role = values[0] as? String ?? ""
            let title = values[1] as? String ?? ""
            let description = values[2] as? String ?? ""
            visit(element, role, title.isEmpty ? description : title, box, !box.isEmpty)
            if let children = values[5] as? [AXUIElement] { stack.append(contentsOf: children) }
        }
        return count
    }

}

// MARK: - Deciding whether keys are safe to send

enum Target: Equatable {
    case video(String)
    case blocked(String)

    var isVideo: Bool {
        if case .video = self { return true }
        return false
    }
}

func currentTarget(settings: Settings) -> Target {
    guard AXIsProcessTrusted() else { return .blocked("Accessibility permission needed") }
    guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else {
        return .blocked("No active app")
    }
    let name = app.localizedName ?? bundle
    if settings.mediaPlayers.contains(bundle) { return .video(name) }
    guard settings.browsers.contains(bundle) else { return .blocked("\(name) isn't a video app") }

    guard let title = focusedWindowTitle(pid: app.processIdentifier) else {
        return .blocked("Can't read \(name)'s window title")
    }
    if settings.videoTitleKeywords.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
        return .video(title)
    }
    return .blocked("This tab isn't a video site")
}

func focusedWindowTitle(pid: pid_t) -> String? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.2)
    var window: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
          let window else { return nil }
    var title: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
    else { return nil }
    return title as? String
}

// MARK: - Camera and hand tracking

struct TrackedFrame {
    var output: EngineOutput
    /// Joints in display space: 0...1, mirrored like a selfie, origin bottom-left.
    var joints: [CGPoint]
}

final class HandTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onFrame: ((TrackedFrame) -> Void)?

    private let queue = DispatchQueue(label: "handsfree.camera", qos: .userInteractive)
    private let engine = GestureEngine()
    private let request = VNDetectHumanHandPoseRequest()
    private var active = false

    private static let jointNames: [Joint: VNHumanHandPoseObservation.JointName] = [
        .wrist: .wrist, .thumbIP: .thumbIP, .thumbTip: .thumbTip,
        .indexMCP: .indexMCP, .indexPIP: .indexPIP, .indexTip: .indexTip,
        .middleMCP: .middleMCP, .middlePIP: .middlePIP, .middleTip: .middleTip,
        .ringMCP: .ringMCP, .ringPIP: .ringPIP, .ringTip: .ringTip,
        .littleMCP: .littleMCP, .littlePIP: .littlePIP, .littleTip: .littleTip,
    ]

    func configure() -> Bool {
        request.maximumHandCount = 1
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addOutput(output)
        session.commitConfiguration()
        return true
    }

    func setRunning(_ running: Bool) {
        queue.async { [session] in
            if running, !session.isRunning { session.startRunning() }
            if !running, session.isRunning { session.stopRunning() }
        }
    }

    /// Off the video tab there's nothing to control, so skip the tracking work.
    func setActive(_ value: Bool) {
        queue.async { [self] in
            if active && !value { engine.reset() }
            active = value
        }
    }

    func apply(_ settings: Settings) {
        queue.async { [self] in engine.settings = settings }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard active, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let aspect = Double(CVPixelBufferGetWidth(buffer)) / Double(CVPixelBufferGetHeight(buffer))

        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        try? handler.perform([request])

        var hand: HandFrame?
        var display: [CGPoint] = []
        if let observation = request.results?.first {
            var joints = HandFrame()
            let minimum = Float(engine.settings.minJointConfidence)
            for (joint, name) in Self.jointNames {
                guard let point = try? observation.recognizedPoint(name), point.confidence >= minimum
                else { continue }
                let x = engine.settings.mirrorX ? 1 - point.location.x : point.location.x
                joints[joint] = Point(x: x * aspect, y: point.location.y)
                display.append(CGPoint(x: 1 - point.location.x, y: point.location.y))
            }
            hand = joints
        }

        let result = engine.process(hand: hand, at: time)
        onFrame?(TrackedFrame(output: result, joints: display))
    }
}

// MARK: - On-screen feedback

/// A small corner icon that floats over fullscreen video without ever taking focus.
final class HUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?
    private static let size = NSSize(width: 52, height: 52)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        background.material = .hudWindow
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        panel.contentView = background

        label.font = .systemFont(ofSize: 24)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 10, width: Self.size.width, height: 32)
        background.addSubview(label)
    }

    func show(_ symbol: String, duration: TimeInterval = 0.6) {
        hideWork?.cancel()
        label.stringValue = symbol

        if let screen = NSScreen.main {
            let frame = screen.frame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - Self.size.width - 20,
                                         y: frame.maxY - Self.size.height - 20))
        }
        panel.alphaValue = 0.85
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [panel] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

final class SkeletonView: NSView {
    var joints: [CGPoint] = [] { didSet { needsDisplay = true } }
    var pinching = false

    override func draw(_ dirtyRect: NSRect) {
        (pinching ? NSColor.systemGreen : NSColor.systemYellow).setFill()
        for joint in joints {
            let center = CGPoint(x: joint.x * bounds.width, y: joint.y * bounds.height)
            NSBezierPath(ovalIn: NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)).fill()
        }
    }
}

/// Camera view for testing. It floats above the video and doesn't take focus,
/// so the video tab stays the active window.
final class PreviewPanel: NSObject, NSWindowDelegate {
    let panel: NSPanel
    let skeleton = SkeletonView()
    private let readout = NSTextField(labelWithString: "Waiting for camera…")
    private let guideLabel = NSTextField(wrappingLabelWithString: SiteProfile.standard.guide)
    private let videoSize = NSSize(width: 320, height: 180)
    var onClose: (() -> Void)?

    init(session: AVCaptureSession) {
        let height: CGFloat = 180 + 122
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: height),
                        styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Handsfree"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: height))
        panel.contentView = content

        let video = NSView(frame: NSRect(x: 0, y: 122, width: videoSize.width, height: videoSize.height))
        video.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.frame = video.bounds
        layer.videoGravity = .resizeAspect
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        video.layer?.addSublayer(layer)
        content.addSubview(video)

        skeleton.frame = video.frame
        content.addSubview(skeleton)

        guideLabel.font = .systemFont(ofSize: 11)
        guideLabel.frame = NSRect(x: 10, y: 26, width: 300, height: 90)
        content.addSubview(guideLabel)

        readout.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.lineBreakMode = .byTruncatingTail
        readout.frame = NSRect(x: 10, y: 6, width: 300, height: 16)
        content.addSubview(readout)
    }

    func show() {
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 16, y: area.minY + 16))
        }
        panel.orderFrontRegardless()
    }

    func setReadout(_ text: String) { readout.stringValue = text }
    func setGuide(_ text: String) { guideLabel.stringValue = text }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log: EventLog
    private let page: PageController
    private let config = ConfigFile()
    private let tracker = HandTracker()
    private let hud = HUD()
    private var preview: PreviewPanel?
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let previewItem = NSMenuItem(title: "Show Camera View", action: #selector(togglePreview), keyEquivalent: "")

    private var settings = Settings()
    private var enabled = true
    private var previewOpen = false
    private var target = Target.blocked("Starting…")
    private var lastPhase = Phase.noHand
    private var lastReadout = Date.distantPast
    private var cameraReady = false
    private var profile = SiteProfile.standard

    override init() {
        log = EventLog()
        page = PageController(log: log)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        tracker.onFrame = { [weak self] frame in
            DispatchQueue.main.async { self?.handle(frame) }
        }
        reloadConfig()

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openAccessibilitySettings() }

        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { self.cameraAnswered(granted) }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func cameraAnswered(_ granted: Bool) {
        guard granted else {
            statusLine.title = "Camera permission needed"
            log.write("camera-denied")
            return
        }
        guard tracker.configure() else {
            statusLine.title = "Couldn't open the camera"
            log.write("camera-failed")
            return
        }
        cameraReady = true
        tracker.setRunning(enabled)
        log.write("camera-started")
        tick()
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖐"

        let menu = NSMenu()
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        enabledItem.target = self
        enabledItem.state = .on
        menu.addItem(enabledItem)
        previewItem.target = self
        menu.addItem(previewItem)
        menu.addItem(.separator())
        let accessItem = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessItem.target = self
        menu.addItem(accessItem)
        let configItem = NSMenuItem(title: "Open Settings File", action: #selector(openConfig), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)
        let logItem = NSMenuItem(title: "Open Gesture Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Handsfree", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func reloadConfig() {
        if let updated = config.reloadIfChanged(log: log) {
            settings = updated
            tracker.apply(updated.adjusted(for: profile))
            log.write("config-loaded")
        }
    }

    private func tick() {
        reloadConfig()
        statusItem.button?.title = AXIsProcessTrusted() ? "🖐" : "🖐⚠️"
        let newTarget = currentTarget(settings: settings)
        if newTarget != target {
            log.write("target \(newTarget)")
            target = newTarget
        }
        updateProfile()
        tracker.setActive(enabled && cameraReady && (target.isVideo || previewOpen))

        guard cameraReady else { return }
        if !enabled {
            statusLine.title = "Paused (camera off)"
        } else {
            switch target {
            case .video(let name): statusLine.title = "Active: \(name)"
            case .blocked(let reason): statusLine.title = "Idle: \(reason)"
            }
        }
    }

    private func updateProfile() {
        var newProfile = SiteProfile.standard
        if case .video(let title) = target { newProfile = SiteProfile.detect(windowTitle: title) }
        if newProfile != .standard, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            page.prepare(pid: pid, profile: newProfile)
        }
        guard newProfile != profile else { return }
        profile = newProfile
        log.write("profile \(newProfile.rawValue)")
        tracker.apply(settings.adjusted(for: newProfile))
        preview?.setGuide(newProfile.guide)
    }

    private func handle(_ frame: TrackedFrame) {
        preview?.skeleton.joints = frame.joints
        preview?.skeleton.pinching = frame.output.phase == .pinching

        if frame.output.phase != lastPhase {
            log.write("phase \(frame.output.phase)")
            lastPhase = frame.output.phase
        }

        for action in frame.output.actions { run(action) }

        if Date().timeIntervalSince(lastReadout) > 0.2 {
            lastReadout = Date()
            updateReadout(frame.output)
        }
    }

    private func run(_ action: Action) {
        // Re-check at the moment of sending: the user may have just switched tabs.
        let now = currentTarget(settings: settings)
        target = now
        switch now {
        case .video:
            updateProfile()
            let current = profile
            perform(current.command(for: action)) { [weak self] done in
                guard let self else { return }
                if self.settings.showFeedback { self.hud.show(done ? current.symbol(for: action) : "🚫") }
                self.log.write("action \(action.rawValue) \(done ? "sent" : "missed") profile=\(current.rawValue)")
            }
        case .blocked(let reason):
            // Only the camera view keeps tracking off a video tab, so this is test feedback.
            // A missing permission always shows: otherwise every gesture silently does nothing.
            if !AXIsProcessTrusted() {
                hud.show("🔒", duration: 1.5)
            } else if settings.showFeedback {
                hud.show("🚫")
            }
            log.write("action \(action.rawValue) blocked: \(reason)")
        }
    }

    private func perform(_ command: Command, completion: @escaping (Bool) -> Void) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        switch command {
        case .key(let key):
            KeySender.press(key)
            completion(true)
        case .media(let key):
            KeySender.press(key)
            completion(true)
        case .pageButton(let labels, let fallback):
            page.pressButton(labels, pid: pid) { [weak self] pressed in
                if !pressed, let fallback {
                    self?.perform(fallback, completion: completion)
                } else {
                    completion(pressed)
                }
            }
        case .clickVideo:
            page.clickVideo(pid: pid, completion: completion)
        case .scrollWheel(let up):
            page.scroll(up: up, pid: pid, completion: completion)
        }
    }

    private func updateReadout(_ output: EngineOutput) {
        guard let m = output.metrics else {
            preview?.setReadout("no hand  ·  \(statusLine.title)")
            return
        }
        let text = String(format: "pinch %.2f  size %.2f  pose %@  ·  %@",
                          m.pinchRatio, m.scale, m.pose.rawValue, statusLine.title)
        preview?.setReadout(text)
        log.write(String(format: "metrics pinch=%.3f touch=%@:%.3f scale=%.3f x=%.3f y=%.3f pose=%@ indexOut=%@",
                         m.pinchRatio, m.touchFinger?.rawValue ?? "none", m.touchRatio, m.scale,
                         m.pinchPoint.x, m.pinchPoint.y, m.pose.rawValue, m.indexOut ? "1" : "0"))
    }

    private func setPreview(open: Bool) {
        if open {
            if preview == nil {
                let created = PreviewPanel(session: tracker.session)
                created.onClose = { [weak self] in
                    self?.previewOpen = false
                    self?.previewItem.title = "Show Camera View"
                    self?.tick()
                }
                preview = created
            }
            preview?.setGuide(profile.guide)
            preview?.show()
            previewOpen = true
            previewItem.title = "Hide Camera View"
        } else {
            preview?.panel.close()
        }
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        enabledItem.state = enabled ? .on : .off
        tracker.setRunning(enabled && cameraReady)
        log.write(enabled ? "enabled" : "paused")
        tick()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func togglePreview() { setPreview(open: !previewOpen) }
    @objc private func openConfig() { NSWorkspace.shared.open(config.url) }
    @objc private func openLog() { NSWorkspace.shared.open(log.url) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
