import Foundation

// Plays synthetic hand movements through the engine. No XCTest because the
// Command Line Tools install doesn't ship it.

enum Fingers { case open, peace, fist, thumbUp, thumbDown, pointLeft, pointRight, pointUp, pointDiagonal }

func makeHand(at c: Point, scale s: Double = 0.2, pinch: Double? = nil, fingers: Fingers = .open,
              touch: TapFinger? = nil) -> HandFrame {
    func at(_ x: Double, _ y: Double) -> Point { Point(x: c.x + x * s, y: c.y + y * s) }
    var h: HandFrame = [
        .wrist: at(0, -1), .middleMCP: c, .indexMCP: at(-0.2, 0),
        .ringMCP: at(0.2, 0), .littleMCP: at(0.35, -0.05),
    ]
    func finger(_ pip: Joint, _ tip: Joint, x: Double, up: Bool) {
        h[pip] = at(x, up ? 0.5 : 0.3)
        h[tip] = at(x, up ? 1.0 : -0.1)
    }
    switch fingers {
    case .open:
        finger(.indexPIP, .indexTip, x: -0.2, up: true)
        finger(.middlePIP, .middleTip, x: 0, up: true)
        finger(.ringPIP, .ringTip, x: 0.2, up: true)
        finger(.littlePIP, .littleTip, x: 0.35, up: true)
    case .peace:
        finger(.indexPIP, .indexTip, x: -0.2, up: true)
        finger(.middlePIP, .middleTip, x: 0, up: true)
        finger(.ringPIP, .ringTip, x: 0.2, up: false)
        finger(.littlePIP, .littleTip, x: 0.35, up: false)
    case .fist, .thumbUp, .thumbDown, .pointLeft, .pointRight, .pointUp, .pointDiagonal:
        finger(.indexPIP, .indexTip, x: -0.2, up: false)
        finger(.middlePIP, .middleTip, x: 0, up: false)
        finger(.ringPIP, .ringTip, x: 0.2, up: false)
        finger(.littlePIP, .littleTip, x: 0.35, up: false)
    }
    h[.thumbTip] = at(-1.0, -0.2)
    if fingers == .peace { h[.thumbTip] = at(0.1, -0.1) }
    if fingers == .fist { h[.thumbTip] = at(-0.3, -0.05) }
    let pointing: [Fingers: (Double, Double)] = [
        .pointRight: (1, 0), .pointLeft: (-1, 0), .pointUp: (0, 1), .pointDiagonal: (0.7, 0.7),
    ]
    if let (dx, dy) = pointing[fingers] {
        h[.indexPIP] = at(-0.2 + dx * 0.5, dy * 0.5)
        h[.indexTip] = at(-0.2 + dx, dy)
        h[.thumbTip] = at(-0.3, -0.05)
    }
    if fingers == .thumbUp { h[.thumbTip] = at(-0.3, 1.0) }
    if fingers == .thumbDown { h[.thumbTip] = at(-0.3, -0.9) }
    if let pinch {
        h[.indexPIP] = at(-0.25, 0.3)
        h[.indexTip] = at(-0.4, 0.4)
        h[.thumbTip] = at(-0.4 + pinch, 0.4)
    }
    if touch == .middle {
        h[.middlePIP] = at(0, 0.3)
        h[.middleTip] = at(0, 0.45)
        h[.thumbTip] = at(-0.08, 0.45)
    }
    if touch == .ring {
        h[.ringPIP] = at(0.2, 0.3)
        h[.ringTip] = at(0.2, 0.45)
        h[.thumbTip] = at(0.12, 0.45)
    }
    return h
}

/// Feeds frames at 30 fps and collects the actions they produce.
final class Scenario {
    let engine = GestureEngine()
    var time = 100.0
    var actions: [Action] = []

    func frame(_ hand: HandFrame?) {
        actions += engine.process(hand: hand, at: time).actions
        time += 1.0 / 30
    }

    func hold(_ seconds: Double, _ hand: HandFrame?) {
        for _ in 0..<Int(seconds * 30) { frame(hand) }
    }

    /// Moves a hand in a straight line, open by default.
    func move(from a: Point, to b: Point, seconds: Double, scale: Double = 0.2, pinch: Double? = nil) {
        let n = Int(seconds * 30)
        for i in 0...n {
            let t = Double(i) / Double(n)
            frame(makeHand(at: Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                           scale: scale, pinch: pinch))
        }
    }
}

var failures = 0
func check(_ name: String, _ actual: [Action], _ expected: [Action]) {
    if actual == expected {
        print("  ok    \(name)")
    } else {
        failures += 1
        print("  FAIL  \(name): expected \(expected.map(\.rawValue)), got \(actual.map(\.rawValue))")
    }
}
func checkTrue(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("  ok    \(name)")
    } else {
        failures += 1
        print("  FAIL  \(name) \(detail)")
    }
}

let home = Point(x: 0.8, y: 0.5)
let open = makeHand(at: home)
let closed = makeHand(at: home, pinch: 0.1)

print("Tap")
do {
    let s = Scenario()
    s.hold(0.3, open); s.hold(0.2, closed); s.hold(0.3, open)
    check("quick pinch plays/pauses once", s.actions, [.playPause])
}
do {
    let s = Scenario()
    s.hold(0.3, open); s.hold(0.2, closed); s.hold(0.7, open); s.hold(0.2, closed); s.hold(0.3, open)
    check("two separate taps fire twice", s.actions, [.playPause, .playPause])
}
do {
    let s = Scenario()
    s.hold(0.3, open); s.hold(1.5, closed); s.hold(0.3, open)
    check("long still pinch does nothing", s.actions, [])
}
do {
    let s = Scenario()
    s.hold(0.3, open)
    for _ in 0..<15 {
        s.frame(makeHand(at: home, pinch: 0.27 * 0.2 / 0.2))
        s.frame(makeHand(at: home, pinch: 0.32))
    }
    s.hold(0.3, open)
    checkTrue("jitter at the threshold fires at most once", s.actions.count <= 1, "\(s.actions)")
}

print("Accidental movements")
do {
    let s = Scenario()
    s.hold(1, closed); s.hold(0.3, open)
    check("hand arriving already pinched does nothing", s.actions, [])
}
do {
    let s = Scenario()
    s.hold(0.3, open); s.hold(0.5, makeHand(at: home, fingers: .fist)); s.hold(0.3, open)
    check("closing into a fist does nothing", s.actions, [])
}
do {
    let s = Scenario()
    s.hold(0.3, open); s.hold(0.1, closed); s.hold(1, nil)
    check("hand leaving mid-pinch does not tap", s.actions, [])
}
do {
    let s = Scenario()
    s.hold(0.3, open); s.hold(0.2, closed)
    s.hold(0.1, nil)
    s.hold(0.1, closed); s.hold(0.3, open)
    check("brief tracking dropout still counts as one tap", s.actions, [.playPause])
}
do {
    let s = Scenario()
    for i in 0..<60 {
        let x = 0.8 + sin(Double(i) / 3) * 0.3
        s.frame(makeHand(at: Point(x: x, y: 0.5)))
    }
    check("waving an open hand does nothing", s.actions, [])
}
do {
    let s = Scenario()
    s.hold(0.4, open); s.frame(nil); s.hold(0.1, open)
    check("palm shown briefly does nothing", s.actions, [])
}

func offset(_ x: Double, _ y: Double) -> Point { Point(x: home.x + x, y: home.y + y) }
print("Pointing")
do {
    let s = Scenario()
    s.hold(0.6, makeHand(at: home, fingers: .pointRight))
    check("pointing right seeks forward", s.actions, [.seekForward])
}
do {
    let s = Scenario()
    s.hold(0.6, makeHand(at: home, fingers: .pointLeft))
    check("pointing left seeks back", s.actions, [.seekBack])
}
do {
    let s = Scenario()
    s.hold(1.5, makeHand(at: home, fingers: .pointRight))
    checkTrue("holding the point keeps seeking",
              s.actions.count >= 2 && s.actions.allSatisfy { $0 == .seekForward }, "\(s.actions)")
}
do {
    let s = Scenario()
    s.hold(0.3, makeHand(at: home, fingers: .pointRight))
    check("pointing only briefly does nothing", s.actions, [])
}
do {
    let s = Scenario()
    s.hold(1, makeHand(at: home, fingers: .pointUp))
    check("pointing up does nothing", s.actions, [])
}
do {
    let s = Scenario()
    s.hold(1, makeHand(at: home, fingers: .pointDiagonal))
    check("pointing diagonally does nothing", s.actions, [])
}
do {
    let s = Scenario()
    s.hold(0.4, open); s.move(from: home, to: offset(0.3, 0), seconds: 0.2)
    check("flicking an open hand does nothing now", s.actions, [])
}
do {
    let s = Scenario()
    s.hold(0.3, open); s.move(from: home, to: offset(0.3, 0), seconds: 0.5, pinch: 0.1); s.hold(0.3, makeHand(at: offset(0.3, 0)))
    check("moving while pinched does nothing", s.actions, [])
}

print("Finger taps")
let onMiddle = makeHand(at: home, touch: .middle)
let onRing = makeHand(at: home, touch: .ring)
do {
    let s = Scenario()
    s.hold(0.3, open); s.hold(0.2, onMiddle); s.hold(0.3, open)
    check("thumb to middle finger scrolls down", s.actions, [.scrollDown])
}
do {
    let s = Scenario()
    s.hold(0.3, open); s.hold(0.2, onRing); s.hold(0.3, open)
    check("thumb to ring finger scrolls up", s.actions, [.scrollUp])
}
do {
    let s = Scenario()
    s.hold(0.3, open); s.hold(0.1, onMiddle); s.hold(0.15, onRing); s.hold(0.3, open)
    check("brushing the middle finger on the way to the ring only scrolls up", s.actions, [.scrollUp])
}
do {
    let s = Scenario()
    s.hold(0.3, open)
    for _ in 0..<3 { s.hold(0.2, onMiddle); s.hold(0.6, open) }
    check("each middle tap scrolls once", s.actions, [.scrollDown, .scrollDown, .scrollDown])
}
do {
    let s = Scenario()
    s.hold(1, onMiddle); s.hold(0.3, open)
    check("hand arriving with the thumb on a finger does nothing", s.actions, [])
}
do {
    let s = Scenario()
    s.hold(0.3, open); s.hold(1.5, onRing); s.hold(0.3, open)
    check("long touch on the ring finger does nothing", s.actions, [])
}
do {
    let s = Scenario()
    s.hold(0.3, open); s.hold(0.1, onMiddle); s.hold(1, nil)
    check("hand leaving mid-tap does nothing", s.actions, [])
}
do {
    let s = Scenario()
    s.hold(0.3, open); s.hold(0.5, makeHand(at: home, fingers: .peace)); s.hold(0.3, open)
    check("thumb resting on a curled ring finger in a peace sign doesn't scroll",
          s.actions.filter { $0 == .scrollUp || $0 == .scrollDown }, [])
}

print("Held poses")
do {
    let s = Scenario()
    s.hold(2, open)
    check("held palm mutes exactly once", s.actions, [.mute])
}
do {
    let s = Scenario()
    s.hold(1.5, open); s.hold(0.4, makeHand(at: home, fingers: .fist)); s.hold(1.5, open)
    check("dropping and re-making the palm mutes again", s.actions, [.mute, .mute])
}
do {
    let s = Scenario()
    s.hold(2, makeHand(at: home, fingers: .peace))
    check("held peace sign toggles fullscreen once", s.actions, [.fullscreen])
}
do {
    let s = Scenario()
    s.hold(1.3, makeHand(at: home, fingers: .thumbUp))
    checkTrue("held thumbs up keeps raising the volume",
              s.actions.count >= 3 && s.actions.allSatisfy { $0 == .volumeUp }, "\(s.actions)")
}
do {
    let s = Scenario()
    s.hold(1.3, makeHand(at: home, fingers: .thumbDown))
    checkTrue("held thumbs down keeps lowering the volume",
              s.actions.count >= 3 && s.actions.allSatisfy { $0 == .volumeDown }, "\(s.actions)")
}
do {
    let s = Scenario()
    s.hold(0.2, makeHand(at: home, fingers: .thumbUp))
    check("brief thumbs up does nothing", s.actions, [])
}
do {
    let s = Scenario()
    s.hold(2, makeHand(at: home, fingers: .fist))
    check("held fist does nothing", s.actions, [])
}

print("Tapping and pointing stay separate")
do {
    let s = Scenario()
    var bent = makeHand(at: home, fingers: .pointRight)
    bent[.indexPIP] = Point(x: bent[.indexPIP]!.x, y: bent[.indexPIP]!.y + 0.12)
    s.hold(1.5, bent)
    check("a curved index finger isn't a point", s.actions, [])
}
do {
    let s = Scenario()
    var near = makeHand(at: home, fingers: .pointRight)
    let tip = near[.indexTip]!
    near[.thumbTip] = Point(x: tip.x - 0.1, y: tip.y - 0.06)
    s.hold(1.5, near)
    check("a thumb close to the fingertip isn't a point", s.actions, [])
}
do {
    let s = Scenario()
    let pointing = makeHand(at: home, fingers: .pointRight)
    s.hold(0.3, open); s.hold(0.2, closed); s.hold(0.5, pointing); s.hold(0.3, open)
    check("the hand opening after a tap doesn't also seek", s.actions, [.playPause])
}
do {
    let s = Scenario()
    let pointing = makeHand(at: home, fingers: .pointRight)
    s.hold(0.3, open); s.hold(0.2, closed); s.hold(1.5, pointing)
    check("a deliberate point after a tap still works", s.actions.prefix(2).map { $0 }, [.playPause, .seekForward])
}
do {
    let s = Scenario()
    let pointing = makeHand(at: home, fingers: .pointRight)
    s.hold(0.3, open); s.hold(0.25, pointing); s.hold(0.2, closed); s.hold(0.3, open)
    check("a brief pointing shape before a tap only taps", s.actions, [.playPause])
}
do {
    let s = Scenario()
    let pointing = makeHand(at: home, fingers: .pointRight)
    s.hold(0.3, open); s.hold(0.6, pointing); s.hold(0.1, open); s.hold(0.1, closed); s.hold(0.3, open)
    check("dropping a point doesn't also tap", s.actions, [.seekForward])
}

print("Site profiles")
checkTrue("Instagram title is detected", SiteProfile.detect(windowTitle: "Instagram – Audio playing - Brave") == .instagram)
checkTrue("Netflix title is detected", SiteProfile.detect(windowTitle: "Home - Netflix - Google Chrome") == .netflix)
checkTrue("YouTube video about Netflix stays on YouTube controls",
          SiteProfile.detect(windowTitle: "Why Netflix won - YouTube - Google Chrome") == .standard)
checkTrue("YouTube point right still seeks", SiteProfile.standard.command(for: .seekForward) == .key(.right))
checkTrue("Instagram pause doesn't send a scrolling key", SiteProfile.instagram.command(for: .playPause) == .clickVideo)
checkTrue("Instagram previous reel scrolls up", SiteProfile.instagram.command(for: .scrollUp) == .scrollWheel(up: true))
checkTrue("Instagram point right likes", SiteProfile.instagram.command(for: .seekForward) == .pageButton(["Like", "Unlike"], fallback: nil))
checkTrue("Instagram point left saves", SiteProfile.instagram.command(for: .seekBack) == .pageButton(["Save", "Remove"], fallback: nil))
checkTrue("Netflix point right still seeks", SiteProfile.netflix.command(for: .seekForward) == .key(.right))
do {
    let s = Scenario()
    s.engine.settings = Settings().adjusted(for: .instagram)
    s.hold(3, makeHand(at: home, fingers: .pointRight))
    check("holding a point on Instagram likes once, never unlikes", s.actions, [.seekForward])
}
do {
    let s = Scenario()
    s.engine.settings = Settings().adjusted(for: .instagram)
    s.hold(0.45, makeHand(at: home, fingers: .pointRight))
    check("a short point on Instagram doesn't like", s.actions, [])
}

print("Settings")
do {
    let partial = try Settings.decode(from: Data(#"{"pinchEnter": 0.5}"#.utf8))
    checkTrue("partial config keeps other defaults",
              partial.pinchEnter == 0.5 && partial.holdTime == Settings().holdTime)
    checkTrue("bad config is rejected", (try? Settings.decode(from: Data("nope".utf8))) == nil)
} catch {
    checkTrue("settings decode", false, "\(error)")
}

print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
