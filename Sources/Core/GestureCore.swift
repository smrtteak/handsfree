import Foundation

// Pure gesture logic: no camera, no AppKit. Everything is measured relative to
// the size of the hand, so gestures behave the same near or far from the camera.

struct Point: Equatable {
    var x: Double
    var y: Double
    func distance(to other: Point) -> Double { hypot(x - other.x, y - other.y) }
}

enum Joint: String, CaseIterable {
    case wrist, thumbIP, thumbTip
    case indexMCP, indexPIP, indexTip
    case middleMCP, middlePIP, middleTip
    case ringMCP, ringPIP, ringTip
    case littleMCP, littlePIP, littleTip
}

/// One hand in one video frame. +x is the viewer's right, +y is up.
typealias HandFrame = [Joint: Point]

/// The fingertips the thumb can tap, each with its own command.
enum TapFinger: String, CaseIterable {
    case index, middle, ring

    var action: Action {
        switch self {
        case .index: return .playPause
        case .middle: return .scrollDown
        case .ring: return .scrollUp
        }
    }
}

enum Pose: String { case none, palm, peace, thumbUp, thumbDown, pointLeft, pointRight }

enum Action: String {
    case playPause, seekForward, seekBack, scrollDown, scrollUp
    case volumeUp, volumeDown, mute, fullscreen

    var symbol: String {
        switch self {
        case .playPause: return "⏯"
        case .seekForward: return "⏩"
        case .seekBack: return "⏪"
        case .scrollDown: return "⬇️"
        case .scrollUp: return "⬆️"
        case .volumeUp: return "🔊"
        case .volumeDown: return "🔉"
        case .mute: return "🔇"
        case .fullscreen: return "⛶"
        }
    }
}

enum Key { case space, left, right, up, down, f, s }
enum MediaKey { case volumeUp, volumeDown, mute }

/// What a gesture actually does once the site is known.
indirect enum Command: Equatable {
    case key(Key)
    case media(MediaKey)
    /// Presses the on-page button with one of these names, nearest the middle of the window.
    case pageButton([String], fallback: Command?)
    /// Clicks the middle of the video. Instagram has no pause key.
    case clickVideo
    case scrollWheel(up: Bool)
}

/// Each site gets its own meaning for the same gestures. `Action` names the gesture's
/// default meaning; a profile can send it somewhere else entirely.
enum SiteProfile: String {
    case standard, netflix, instagram

    static func detect(windowTitle: String) -> SiteProfile {
        // A YouTube video can have any site's name in its title.
        if windowTitle.localizedCaseInsensitiveContains("YouTube") { return .standard }
        if windowTitle.localizedCaseInsensitiveContains("Instagram") { return .instagram }
        if windowTitle.localizedCaseInsensitiveContains("Netflix") { return .netflix }
        return .standard
    }

    func command(for action: Action) -> Command {
        switch (self, action) {
        case (.netflix, .scrollDown):
            return .pageButton(["Skip Intro", "Skip Recap", "Skip Credits"], fallback: .key(.s))
        case (.netflix, .scrollUp):
            return .pageButton(["Next Episode"], fallback: nil)

        case (.instagram, .playPause): return .clickVideo
        case (.instagram, .scrollUp): return .scrollWheel(up: true)
        case (.instagram, .seekForward): return .pageButton(["Like", "Unlike"], fallback: nil)
        case (.instagram, .seekBack): return .pageButton(["Save", "Remove"], fallback: nil)
        case (.instagram, .fullscreen): return .pageButton(["Comment"], fallback: nil)

        case (_, .playPause): return .key(.space)
        case (_, .seekForward): return .key(.right)
        case (_, .seekBack): return .key(.left)
        case (_, .scrollDown): return .key(.down)
        case (_, .scrollUp): return .key(.up)
        case (_, .fullscreen): return .key(.f)
        case (_, .volumeUp): return .media(.volumeUp)
        case (_, .volumeDown): return .media(.volumeDown)
        case (_, .mute): return .media(.mute)
        }
    }

    func symbol(for action: Action) -> String {
        switch (self, action) {
        case (.netflix, .scrollDown): return "⏭"
        case (.netflix, .scrollUp): return "📺"
        case (.instagram, .seekForward): return "❤️"
        case (.instagram, .seekBack): return "🔖"
        case (.instagram, .fullscreen): return "💬"
        default: return action.symbol
        }
    }

    var guide: String {
        switch self {
        case .standard:
            return """
            🤏 Tap thumb to index: play / pause
            🤏 Tap thumb to middle: scroll down     ring: scroll up
            👉 Point left / right: seek
            👍👎 Hold: volume up / down
            ✋ Hold still: mute     ✌️ Hold: fullscreen
            """
        case .netflix:
            return """
            🤏 Tap thumb to index: play / pause
            🤏 Tap thumb to middle: skip intro     ring: next episode
            👉 Point left / right: seek
            👍👎 Hold: volume up / down
            ✋ Hold still: mute     ✌️ Hold: fullscreen
            """
        case .instagram:
            return """
            🤏 Tap thumb to index: play / pause
            🤏 Tap thumb to middle: next reel     ring: previous reel
            👉 Hold point right: like     left: save
            👍👎 Hold: volume up / down
            ✋ Hold still: mute     ✌️ Hold: comments
            """
        }
    }
}

/// Every tunable value. Stored as JSON so thresholds change without a rebuild.
struct Settings: Codable, Equatable {
    // Pinch, as thumb-to-index distance divided by hand size.
    var pinchEnter = 0.28
    var pinchRelease = 0.48
    var pinchFrames = 2
    var armTime = 0.12
    var indexOutRatio = 1.05

    // Tap.
    var tapMaxDuration = 0.6
    var tapMaxMovement = 0.6
    var tapCooldown = 0.5

    // Held poses.
    var holdTime = 1.0
    var holdDrift = 0.4
    var poseGrace = 0.15
    var fingerExtendedRatio = 1.1
    var palmThumbRatio = 0.7

    // Thumbs up/down keep changing the volume while held.
    var thumbHoldTime = 0.35
    var thumbRepeat = 0.3
    var thumbMinReach = 0.6

    // Pointing left or right keeps seeking while held.
    var pointHoldTime = 0.45
    var pointRepeat = 0.5
    var pointMinLength = 0.5
    var pointDominance = 1.5
    // The hand passes through a pointing shape on its way into a tap, with the finger
    // curving toward a nearby thumb. A real point is straight, with the thumb out of the way.
    var pointStraightness = 0.9
    var pointMinThumbGap = 0.8
    // A tap's opening and closing hand shouldn't read as a held pose, or the reverse.
    var poseLockoutAfterTap = 0.6
    var tapLockoutAfterPoint = 0.5
    // Instagram's point means like or save, so it takes longer and never repeats.
    var pointHoldTimeInstagram = 0.6

    // Tracking.
    var minHandScale = 0.05
    var lostGrace = 0.25
    var teleportDistance = 3.0
    var smoothing = 0.5
    var minJointConfidence = 0.2
    var mirrorX = true

    // Feedback.
    var showFeedback = true

    // Where gestures are allowed to send keys.
    var browsers = [
        "com.google.Chrome", "com.brave.Browser", "com.apple.Safari",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "org.mozilla.firefox",
    ]
    var videoTitleKeywords = [
        "YouTube", "Netflix", "Instagram", "TikTok", "Reels", "Prime Video", "Disney+", "Hotstar",
        "Hulu", "HBO Max", "Twitch", "Vimeo",
    ]
    var mediaPlayers = [
        "org.videolan.vlc", "com.apple.QuickTimePlayerX", "com.colliderli.iina", "com.apple.TV",
    ]

    func adjusted(for profile: SiteProfile) -> Settings {
        var copy = self
        if profile == .instagram {
            copy.pointHoldTime = pointHoldTimeInstagram
            copy.pointRepeat = .infinity
        }
        return copy
    }

    /// Overlays a possibly partial config on the defaults, so missing keys keep their default.
    static func decode(from data: Data) throws -> Settings {
        let defaults = try JSONEncoder().encode(Settings())
        var merged = try JSONSerialization.jsonObject(with: defaults) as! [String: Any]
        guard let overrides = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        merged.merge(overrides) { _, new in new }
        return try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: merged))
    }
}

struct HandMetrics {
    let scale: Double
    let pinchRatio: Double
    let pinchPoint: Point
    let center: Point
    let indexOut: Bool
    let pose: Pose
    /// Thumb-to-fingertip distance for each tappable finger, in hand sizes.
    let tapRatios: [TapFinger: Double]
    /// The closest fingertip that's held out from the palm, if any.
    let touchFinger: TapFinger?
    let touchRatio: Double
    /// Closest fingertip of any kind, to tell when the thumb is clear of them all.
    let closestRatio: Double

    init?(_ hand: HandFrame, settings: Settings) {
        guard let wrist = hand[.wrist], let middleMCP = hand[.middleMCP],
              let thumbTip = hand[.thumbTip], let indexTip = hand[.indexTip] else { return nil }

        // Palm width keeps the scale honest when the hand tilts toward the camera.
        var scale = wrist.distance(to: middleMCP)
        if let a = hand[.indexMCP], let b = hand[.littleMCP] {
            scale = max(scale, a.distance(to: b) * 1.3)
        }
        guard scale > 0 else { return nil }

        func extended(_ pip: Joint, _ tip: Joint) -> Bool {
            guard let p = hand[pip], let t = hand[tip] else { return false }
            return wrist.distance(to: t) > wrist.distance(to: p) * settings.fingerExtendedRatio
        }
        let index = extended(.indexPIP, .indexTip)
        let middle = extended(.middlePIP, .middleTip)
        let ring = extended(.ringPIP, .ringTip)
        let little = extended(.littlePIP, .littleTip)

        self.scale = scale
        pinchRatio = thumbTip.distance(to: indexTip) / scale
        pinchPoint = Point(x: (thumbTip.x + indexTip.x) / 2, y: (thumbTip.y + indexTip.y) / 2)
        center = middleMCP

        // In a fist the index tip folds back toward the palm; in a pinch it stays out.
        if let mcp = hand[.indexMCP] {
            indexOut = wrist.distance(to: indexTip) > wrist.distance(to: mcp) * settings.indexOutRatio
        } else {
            indexOut = false
        }

        // In a fist the fingertips fold back toward the palm and the thumb rests on them.
        func held(out tip: Joint, knuckle: Joint) -> Bool {
            guard let t = hand[tip], let k = hand[knuckle] else { return false }
            return wrist.distance(to: t) > wrist.distance(to: k) * settings.indexOutRatio
        }
        let joints: [(TapFinger, Joint, Joint)] = [
            (.index, .indexTip, .indexMCP), (.middle, .middleTip, .middleMCP), (.ring, .ringTip, .ringMCP),
        ]
        var ratios: [TapFinger: Double] = [:]
        var bestFinger: TapFinger?
        var bestRatio = Double.infinity
        for (finger, tip, knuckle) in joints {
            guard let t = hand[tip] else { continue }
            let ratio = thumbTip.distance(to: t) / scale
            ratios[finger] = ratio
            if ratio < bestRatio, held(out: tip, knuckle: knuckle) {
                bestFinger = finger
                bestRatio = ratio
            }
        }
        tapRatios = ratios
        touchFinger = bestFinger
        touchRatio = bestRatio
        closestRatio = ratios.values.min() ?? .infinity

        let thumbReach = (thumbTip.y - middleMCP.y) / scale
        if index && middle && ring && little && pinchRatio > settings.palmThumbRatio {
            pose = .palm
        } else if index && middle && !ring && !little {
            pose = .peace
        } else if index && !middle && !ring && !little, let mcp = hand[.indexMCP], let pip = hand[.indexPIP],
                  mcp.distance(to: indexTip) >= (mcp.distance(to: pip) + pip.distance(to: indexTip)) * settings.pointStraightness,
                  pinchRatio >= settings.pointMinThumbGap,
                  abs(indexTip.x - mcp.x) >= settings.pointMinLength * scale,
                  abs(indexTip.x - mcp.x) >= abs(indexTip.y - mcp.y) * settings.pointDominance {
            pose = indexTip.x > mcp.x ? .pointRight : .pointLeft
        } else if !index && !middle && !ring && !little && abs(thumbReach) > settings.thumbMinReach {
            pose = thumbReach > 0 ? .thumbUp : .thumbDown
        } else {
            pose = .none
        }
    }
}

enum Phase: Equatable {
    case noHand
    case tooFar
    case open
    case pinching
    case holding(Pose, progress: Double)
}

struct EngineOutput {
    var actions: [Action] = []
    var phase: Phase = .noHand
    var metrics: HandMetrics?
}

final class GestureEngine {
    var settings: Settings

    private struct Pinch {
        let start: TimeInterval
        let anchor: Point
        let scale: Double
        var moved = false
        var openFrames = 0
        var finger: TapFinger
    }

    private struct Hold {
        let pose: Pose
        var start: TimeInterval
        var origin: Point
        var lastMatch: TimeInterval
        var fired = false
        var lastFire = -Double.infinity
    }

    private var pinch: Pinch?
    private var hold: Hold?
    private var closedFrames = 0
    private var closedFinger: TapFinger?
    private var readySince: TimeInterval?
    private var lastSeen = -Double.infinity
    private var lastTap = -Double.infinity
    private var lastPinchEnd = -Double.infinity
    private var lastPoint = -Double.infinity
    private var smoothed: Point?

    init(settings: Settings = Settings()) {
        self.settings = settings
    }

    func reset() {
        pinch = nil
        hold = nil
        closedFrames = 0
        readySince = nil
        smoothed = nil
        closedFinger = nil
    }

    func process(hand: HandFrame?, at time: TimeInterval) -> EngineOutput {
        var output = EngineOutput()

        guard let hand, let metrics = HandMetrics(hand, settings: settings) else {
            if time - lastSeen > settings.lostGrace { reset() }
            return output
        }
        output.metrics = metrics

        guard metrics.scale >= settings.minHandScale else {
            if time - lastSeen > settings.lostGrace { reset() }
            output.phase = .tooFar
            return output
        }

        // A jump this large is a different hand or a tracking glitch, not movement.
        if let previous = smoothed,
           previous.distance(to: metrics.pinchPoint) > settings.teleportDistance * metrics.scale {
            reset()
        }
        lastSeen = time

        let point: Point
        if let previous = smoothed {
            let a = settings.smoothing
            point = Point(x: previous.x + (metrics.pinchPoint.x - previous.x) * a,
                          y: previous.y + (metrics.pinchPoint.y - previous.y) * a)
        } else {
            point = metrics.pinchPoint
        }
        smoothed = point

        if pinch != nil {
            updatePinch(metrics, point: point, time: time, output: &output)
        } else if !beginPinchIfReady(metrics, point: point, time: time, output: &output) {
            updateHold(metrics, time: time, output: &output)
        }
        return output
    }

    /// Returns true when a pinch started on this frame.
    private func beginPinchIfReady(_ m: HandMetrics, point: Point, time: TimeInterval,
                                   output: inout EngineOutput) -> Bool {
        let touching = m.touchRatio < settings.pinchEnter ? m.touchFinger : nil
        closedFrames = (touching != nil && touching == closedFinger) ? closedFrames + 1 : (touching == nil ? 0 : 1)
        closedFinger = touching
        if m.closestRatio > settings.pinchRelease, readySince == nil { readySince = time }

        // The fingers must be seen apart first, so a hand that arrives already
        // pinched (holding a snack, resting on the chin) can never fire a tap.
        guard closedFrames >= settings.pinchFrames, let finger = touching, let ready = readySince,
              time - ready >= settings.armTime,
              time - lastPoint >= settings.tapLockoutAfterPoint else { return false }

        pinch = Pinch(start: time, anchor: point, scale: m.scale, finger: finger)
        hold = nil
        readySince = nil
        output.phase = .pinching
        return true
    }

    private func updatePinch(_ m: HandMetrics, point: Point, time: TimeInterval,
                             output: inout EngineOutput) {
        guard var p = pinch else { return }

        // Reaching for the ring finger can brush the middle one on the way, so the tap
        // belongs to the fingertip the thumb ends up on.
        if let finger = m.touchFinger, finger != p.finger, m.touchRatio < settings.pinchEnter {
            p.finger = finger
            p.openFrames = 0
        }

        // A fingertip that drops out of tracking stays closed, it hasn't been released.
        let ratio = m.tapRatios[p.finger] ?? 0
        p.openFrames = ratio > settings.pinchRelease ? p.openFrames + 1 : 0
        if p.openFrames >= settings.pinchFrames {
            if !p.moved, time - p.start <= settings.tapMaxDuration,
               time - lastTap >= settings.tapCooldown {
                output.actions.append(p.finger.action)
                lastTap = time
            }
            pinch = nil
            lastPinchEnd = time
            closedFrames = 0
            readySince = time
            output.phase = .open
            return
        }

        // Opening fingers shift the midpoint, so don't read a release as movement.
        if p.openFrames == 0, point.distance(to: p.anchor) / p.scale > settings.tapMaxMovement {
            p.moved = true
        }

        pinch = p
        output.phase = .pinching
    }

    private func updateHold(_ m: HandMetrics, time: TimeInterval, output: inout EngineOutput) {
        output.phase = .open

        if time - lastPinchEnd < settings.poseLockoutAfterTap {
            hold = nil
            return
        }

        guard m.pose != .none else {
            if let h = hold, time - h.lastMatch > settings.poseGrace { hold = nil }
            return
        }

        guard var h = hold, h.pose == m.pose else {
            hold = Hold(pose: m.pose, start: time, origin: m.center, lastMatch: time)
            output.phase = .holding(m.pose, progress: 0)
            return
        }

        h.lastMatch = time
        // A moving hand is waving or talking, not deliberately holding a pose.
        if m.center.distance(to: h.origin) > settings.holdDrift * m.scale {
            h.start = time
            h.origin = m.center
        }

        // Volume and seeking keep going while held; the others fire once.
        let required: Double
        let repeatEvery: Double?
        switch m.pose {
        case .thumbUp, .thumbDown: (required, repeatEvery) = (settings.thumbHoldTime, settings.thumbRepeat)
        case .pointLeft, .pointRight: (required, repeatEvery) = (settings.pointHoldTime, settings.pointRepeat)
        default: (required, repeatEvery) = (settings.holdTime, nil)
        }
        let progress = min(1, (time - h.start) / required)
        if progress >= 1 {
            let repeatDue = repeatEvery.map { time - h.lastFire >= $0 } ?? false
            if !h.fired || repeatDue {
                h.fired = true
                h.lastFire = time
                switch m.pose {
                case .palm: output.actions.append(.mute)
                case .peace: output.actions.append(.fullscreen)
                case .thumbUp: output.actions.append(.volumeUp)
                case .thumbDown: output.actions.append(.volumeDown)
                case .pointLeft:
                    output.actions.append(.seekBack)
                    lastPoint = time
                case .pointRight:
                    output.actions.append(.seekForward)
                    lastPoint = time
                case .none: break
                }
            }
        }
        hold = h
        // Stay quiet after firing until the pose is dropped and made again.
        if !h.fired { output.phase = .holding(m.pose, progress: progress) }
    }
}
