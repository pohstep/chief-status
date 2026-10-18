import AppKit

enum ChiefPalette {
    static let orange = NSColor(srgbRed: 243.0 / 255.0, green: 156.0 / 255.0, blue: 40.0 / 255.0, alpha: 1)
    static let eye = NSColor(srgbRed: 26.0 / 255.0, green: 20.0 / 255.0, blue: 16.0 / 255.0, alpha: 1)
    static let grey = NSColor(srgbRed: 142.0 / 255.0, green: 142.0 / 255.0, blue: 147.0 / 255.0, alpha: 1)
    static let eyeOnGrey = NSColor(srgbRed: 40.0 / 255.0, green: 40.0 / 255.0, blue: 42.0 / 255.0, alpha: 1)
    static let red = NSColor(srgbRed: 229.0 / 255.0, green: 72.0 / 255.0, blue: 77.0 / 255.0, alpha: 1)
    static let eyeOnRed = NSColor(srgbRed: 42.0 / 255.0, green: 16.0 / 255.0, blue: 18.0 / 255.0, alpha: 1)
    static let done = NSColor(srgbRed: 46.0 / 255.0, green: 184.0 / 255.0, blue: 102.0 / 255.0, alpha: 1)
    /// The small "another bot is stale" dot on the working cube.
    static let black = NSColor(srgbRed: 17.0 / 255.0, green: 17.0 / 255.0, blue: 19.0 / 255.0, alpha: 1)
}

enum BarTone: Equatable {
    case grey
    case orange
    case red
    /// Every working bot has gone 30+ min without a post.
    case black
    /// A bot is waiting on you.
    case indigo
}

/// What the menu bar cube shows, in priority order:
/// any failed → red. Else any bot needs input → "?" cube. Else any working bot that posted in the last 30 min → working cube,
/// plus a small black dot if another working bot is stale. Else any stale working bot → "404" cube.
/// The working, "?" and "404" cubes all use the icon colour from Settings (Default is today's orange).
/// Else grey (idle or finished).
struct BarState: Equatable {
    var tone: BarTone
    var staleDot: Bool = false
    var staleCount: Int = 0
    var needsCount: Int = 0

    var toolTip: String {
        switch tone {
        case .red:
            return "Chief Status — an agent failed"
        case .indigo:
            return needsCount == 1 ? "Chief Status — a bot needs you" : "Chief Status — \(needsCount) bots need you"
        case .orange:
            if staleDot {
                return "Chief Status — working · \(staleCount) maybe stale (no update for 30+ min)"
            }
            return "Chief Status — working"
        case .black:
            return staleCount == 1
                ? "Chief Status — maybe stale: the working bot hasn't posted for 30+ min"
                : "Chief Status — maybe stale: \(staleCount) working bots haven't posted for 30+ min"
        case .grey:
            return "Chief Status — idle"
        }
    }

    static func from(bots: [Bot], now: Date, staleAfterMinutes: Int) -> BarState {
        if bots.contains(where: { $0.status == "failed" }) {
            return BarState(tone: .red)
        }
        let needs = bots.filter { $0.status == "needs_input" }.count
        if needs > 0 {
            return BarState(tone: .indigo, needsCount: needs)
        }
        let working = bots.filter { $0.status == "working" }
        let stale = working.filter { $0.isFaded(now: now, staleAfterMinutes: staleAfterMinutes) }.count
        if working.count > stale {
            return BarState(tone: .orange, staleDot: stale > 0, staleCount: stale)
        }
        if stale > 0 {
            return BarState(tone: .black, staleCount: stale)
        }
        return BarState(tone: .grey)
    }
}

struct IconPose: Equatable {
    var bob: CGFloat = 0
    var squashX: CGFloat = 1
    var squashY: CGFloat = 1
    var rotation: CGFloat = 0
    var eyeShift: CGFloat = 0
    var eyeOpen: CGFloat = 1
    var shake: CGFloat = 0
}

enum SpecialMove: CaseIterable, Equatable {
    case twirl
    case hop
    case wiggle
    case look
    case blink
}

/// Draws the menu-bar face and plays its motion.
/// Orange: a gentle bob with a little squash, plus a short move every few seconds.
/// Grey: a slow blink now and then. Red: one small shake, then still.
/// The "?" cube and the "404" cube stay still.
final class FaceAnimator {
    var onImage: ((NSImage) -> Void)?

    private var tone: BarTone = .grey
    private var staleDot = false
    private var hasTone = false
    private var timer: Timer?
    private var clock: Clock = .stopped

    private var move: SpecialMove?
    private var moveStart: TimeInterval = 0
    private var moveDuration: TimeInterval = 0
    private var nextMoveAt: TimeInterval = 0
    private var lastMove: SpecialMove?

    private var blinkOn = false
    private var blinkStart: TimeInterval = 0
    private var blinkDuration: TimeInterval = 0.45
    private var nextBlinkAt: TimeInterval = 0

    private var shakeOn = false
    private var shakeStart: TimeInterval = 0

    private enum Clock: Equatable {
        case stopped
        case frames(TimeInterval)
        case waiting
    }

    func setState(_ state: BarState) {
        staleDot = state.staleDot
        setTone(state.tone)
    }

    func setTone(_ tone: BarTone) {
        let now = ProcessInfo.processInfo.systemUptime
        if !hasTone || tone != self.tone {
            begin(tone, now: now)
            self.tone = tone
            hasTone = true
        }
        advance(now: now)
        render(now: now)
        armClock(now: now)
    }

    private func begin(_ tone: BarTone, now: TimeInterval) {
        move = nil
        blinkOn = false
        shakeOn = false
        switch tone {
        case .orange:
            nextMoveAt = now + Double.random(in: 6 ... 12)
        case .grey:
            nextBlinkAt = now + Double.random(in: 8 ... 15)
        case .red:
            shakeOn = true
            shakeStart = now
        case .black, .indigo:
            break
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        advance(now: now)
        render(now: now)
        armClock(now: now)
    }

    private func advance(now: TimeInterval) {
        switch tone {
        case .orange:
            if move != nil, now >= moveStart + moveDuration {
                self.move = nil
                nextMoveAt = now + Double.random(in: 6 ... 12)
            }
            if move == nil, now >= nextMoveAt {
                startMove(now: now)
            }
        case .grey:
            if blinkOn, now >= blinkStart + blinkDuration {
                blinkOn = false
                nextBlinkAt = now + Double.random(in: 8 ... 15)
            }
            if !blinkOn, now >= nextBlinkAt {
                blinkOn = true
                blinkStart = now
                blinkDuration = 0.45
            }
        case .red:
            if shakeOn, now >= shakeStart + 0.4 {
                shakeOn = false
            }
        case .black, .indigo:
            break
        }
    }

    private func startMove(now: TimeInterval) {
        let pool = SpecialMove.allCases.filter { $0 != lastMove }
        let choices = pool.isEmpty ? Array(SpecialMove.allCases) : pool
        let picked = choices[Int.random(in: 0 ..< choices.count)]
        lastMove = picked
        move = picked
        moveStart = now
        switch picked {
        case .blink:
            moveDuration = Double.random(in: 0.6 ... 0.8)
        case .twirl:
            moveDuration = Double.random(in: 0.9 ... 1.2)
        default:
            moveDuration = Double.random(in: 0.6 ... 1.2)
        }
    }

    private func render(now: TimeInterval) {
        let pose = FaceMotion.pose(
            tone: tone,
            time: now,
            move: move,
            moveStart: moveStart,
            moveDuration: moveDuration,
            blinkOn: blinkOn,
            blinkStart: blinkStart,
            blinkDuration: blinkDuration,
            shakeOn: shakeOn,
            shakeStart: shakeStart
        )
        onImage?(StatusIcon.image(tone: tone, pose: pose, staleDot: staleDot))
    }

    private func desiredClock() -> Clock {
        switch tone {
        case .orange:
            return .frames(move == nil ? 1.0 / 12.0 : 1.0 / 20.0)
        case .grey:
            return blinkOn ? .frames(1.0 / 20.0) : .waiting
        case .red:
            return shakeOn ? .frames(1.0 / 20.0) : .stopped
        case .black, .indigo:
            return .stopped
        }
    }

    private func armClock(now: TimeInterval) {
        let desired = desiredClock()
        if desired == clock, timer != nil {
            return
        }
        timer?.invalidate()
        timer = nil
        clock = desired
        switch desired {
        case .stopped:
            break
        case .frames(let interval):
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                self?.tick()
            }
            timer.tolerance = interval * 0.15
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        case .waiting:
            let delay = max(0.05, nextBlinkAt - now)
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }
}

enum FaceMotion {
    static func pose(
        tone: BarTone,
        time: TimeInterval,
        move: SpecialMove?,
        moveStart: TimeInterval,
        moveDuration: TimeInterval,
        blinkOn: Bool,
        blinkStart: TimeInterval,
        blinkDuration: TimeInterval,
        shakeOn: Bool,
        shakeStart: TimeInterval
    ) -> IconPose {
        switch tone {
        case .orange:
            return orangePose(time: time, move: move, moveStart: moveStart, moveDuration: moveDuration)
        case .grey:
            return greyPose(time: time, blinkOn: blinkOn, blinkStart: blinkStart, blinkDuration: blinkDuration)
        case .red:
            return redPose(time: time, shakeOn: shakeOn, shakeStart: shakeStart)
        case .black, .indigo:
            return IconPose()
        }
    }

    private static func orangePose(
        time: TimeInterval,
        move: SpecialMove?,
        moveStart: TimeInterval,
        moveDuration: TimeInterval
    ) -> IconPose {
        let phase = time * (2 * Double.pi) / 1.6
        let wave = CGFloat(sin(phase))
        var pose = IconPose()
        pose.bob = wave * 0.9
        pose.squashY = 1 + 0.035 * wave
        pose.squashX = 1 - 0.035 * wave

        guard let move = move else { return pose }
        let progress = unit(time, start: moveStart, duration: moveDuration)
        let env = sin(.pi * progress)
        pose.bob *= (1 - env)
        pose.squashX = pose.squashX * (1 - env) + env
        pose.squashY = pose.squashY * (1 - env) + env

        switch move {
        case .twirl:
            pose.rotation = smooth(progress) * 2 * .pi
        case .hop:
            pose.bob += sin(.pi * progress) * 0.7
            let land = max(0, (progress - 0.62) / 0.38)
            let landEnv = sin(.pi * min(1, land))
            pose.squashY = 1 - 0.12 * landEnv
            pose.squashX = 1 + 0.10 * landEnv
        case .wiggle:
            pose.rotation = sin(progress * 3 * 2 * .pi) * env * (7 * .pi / 180)
        case .look:
            pose.eyeShift = sin(progress * 2 * 2 * .pi) * env * 1.0
        case .blink:
            pose.eyeOpen = 1 - 0.82 * env
        }
        return pose
    }

    private static func greyPose(
        time: TimeInterval,
        blinkOn: Bool,
        blinkStart: TimeInterval,
        blinkDuration: TimeInterval
    ) -> IconPose {
        var pose = IconPose()
        guard blinkOn else { return pose }
        let progress = unit(time, start: blinkStart, duration: blinkDuration)
        pose.eyeOpen = 1 - 0.82 * sin(.pi * progress)
        return pose
    }

    private static func redPose(time: TimeInterval, shakeOn: Bool, shakeStart: TimeInterval) -> IconPose {
        var pose = IconPose()
        guard shakeOn else { return pose }
        let progress = unit(time, start: shakeStart, duration: 0.4)
        pose.shake = sin(progress * 3 * 2 * .pi) * (1 - progress) * 0.6
        return pose
    }

    private static func unit(_ time: TimeInterval, start: TimeInterval, duration: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 1 }
        let raw = (time - start) / duration
        return min(1, max(0, CGFloat(raw)))
    }

    private static func smooth(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}

/// Fill for the working, stale "404" and needs-you cubes. Idle grey and failed red ignore this.
enum WorkingFill {
    /// Today's orange.
    case palette
    /// The colour saved in Settings.
    case stored
    /// One preset or a custom colour, used by the preview sheets.
    case colour(NSColor)
}

enum StatusIcon {
    static let pointSize: CGFloat = 18

    static func image(
        tone: BarTone,
        pose: IconPose,
        staleDot: Bool = false,
        working: WorkingFill = .stored
    ) -> NSImage {
        switch tone {
        case .black:
            let fill = IconInk.fill(working)
            let ink = IconInk.ink(on: fill)
            let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { _ in
                paintMark("404", fill: fill, ink: ink, size: 7.5)
                return true
            }
            image.isTemplate = false
            return image
        case .indigo:
            let fill = IconInk.fill(working)
            let ink = IconInk.ink(on: fill)
            let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { _ in
                paintMark("?", fill: fill, ink: ink, size: 12)
                return true
            }
            image.isTemplate = false
            return image
        case .orange, .red, .grey:
            break
        }

        let paintFill: NSColor
        let paintEye: NSColor
        switch tone {
        case .orange:
            paintFill = IconInk.fill(working)
            paintEye = IconInk.ink(on: paintFill)
        case .red:
            paintFill = ChiefPalette.red
            paintEye = ChiefPalette.eyeOnRed
        case .grey:
            paintFill = ChiefPalette.grey
            paintEye = ChiefPalette.eyeOnGrey
        case .black, .indigo:
            paintFill = ChiefPalette.orange
            paintEye = ChiefPalette.eye
        }

        let pose = pose
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { _ in
            paint(fill: paintFill, eye: paintEye, pose: pose)
            if staleDot {
                paintStaleDot()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 18pt face, inset 1pt, corner radius 5. Eyes are 2.2×4.6pt ovals with a 3pt gap,
    /// centred as a pair on x = 9, bottoms at y = 8.6 before blink and bob.
    private static func paint(fill: NSColor, eye: NSColor, pose: IconPose) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if let graphics = NSGraphicsContext.current {
            graphics.shouldAntialias = true
            graphics.imageInterpolation = .high
        }

        let bob = pose.bob
        let centre = NSPoint(x: 9, y: 9 + bob)
        let fit = fitScale(pose: pose, centre: centre)
        let transform = NSAffineTransform()
        transform.translateX(by: centre.x + pose.shake, yBy: centre.y)
        transform.rotate(byRadians: pose.rotation)
        transform.scaleX(by: pose.squashX * fit, yBy: pose.squashY * fit)
        transform.translateX(by: -centre.x, yBy: -centre.y)
        transform.concat()

        let face = NSRect(x: 1, y: 1 + bob, width: 16, height: 16)
        fill.setFill()
        NSBezierPath(roundedRect: face, xRadius: 5, yRadius: 5).fill()

        let eyeWidth: CGFloat = 2.2
        let fullHeight: CGFloat = 4.6
        let gap: CGFloat = 3
        let open = min(1, max(0.15, pose.eyeOpen))
        let height = fullHeight * open
        let eyeCentreY = 8.6 + fullHeight / 2 + bob
        let eyeY = eyeCentreY - height / 2
        let leftX = 9 - (eyeWidth * 2 + gap) / 2 + pose.eyeShift
        eye.setFill()
        NSBezierPath(ovalIn: NSRect(x: leftX, y: eyeY, width: eyeWidth, height: height)).fill()
        let rightX = leftX + eyeWidth + gap
        NSBezierPath(ovalIn: NSRect(x: rightX, y: eyeY, width: eyeWidth, height: height)).fill()
    }

    /// Stale "404" cube or needs-you "?" cube: the same 16pt face in the icon colour,
    /// with the mark where the eyes go, dark or white to suit the fill. No outline.
    private static func paintMark(_ mark: String, fill: NSColor, ink: NSColor, size fontSize: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if let graphics = NSGraphicsContext.current {
            graphics.shouldAntialias = true
        }
        let face = NSRect(x: 1, y: 1, width: 16, height: 16)
        fill.setFill()
        NSBezierPath(roundedRect: face, xRadius: 5, yRadius: 5).fill()

        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .heavy)
        let text = NSAttributedString(string: mark, attributes: [
            .font: font,
            .foregroundColor: ink,
            .kern: -0.2,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: 9 - size.width / 2, y: 9 - size.height / 2 + 0.2))
    }

    /// Small black dot with a light rim, bottom right: working, but another working bot is stale.
    private static func paintStaleDot() {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let dot = NSRect(x: 11.6, y: 0.4, width: 6, height: 6)
        let ring = NSBezierPath(ovalIn: dot)
        NSColor.white.setFill()
        ring.fill()
        ChiefPalette.black.setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: 1.1, dy: 1.1)).fill()
    }

    /// Scale so a rotated or squashed face stays inside the 18pt square.
    private static func fitScale(pose: IconPose, centre: NSPoint) -> CGFloat {
        let halfX = 8 * abs(pose.squashX)
        let halfY = 8 * abs(pose.squashY)
        let cosine = abs(cos(pose.rotation))
        let sine = abs(sin(pose.rotation))
        let halfW = cosine * halfX + sine * halfY
        let halfH = sine * halfX + cosine * halfY
        guard halfW > 0.001, halfH > 0.001 else { return 1 }
        let cx = centre.x + pose.shake
        let cy = centre.y
        let roomX = min(cx, pointSize - cx)
        let roomY = min(cy, pointSize - cy)
        guard roomX > 0, roomY > 0 else { return 1 }
        return min(1, roomX / halfW, roomY / halfH)
    }
}

/// The icon colour from Settings, and a dark or white ink that reads on it (eyes, "404", "?").
enum IconInk {
    static func fill(_ working: WorkingFill) -> NSColor {
        switch working {
        case .palette:
            return ChiefPalette.orange
        case .stored:
            let choice = IconColorSetting.load()
            if choice.isDefault {
                return ChiefPalette.orange
            }
            return choice.nsColor
        case .colour(let fill):
            return fill
        }
    }

    /// Dark ink when it contrasts more with the fill than white does, otherwise white.
    static func ink(on fill: NSColor) -> NSColor {
        let surface = luminance(fill)
        let dark = ratio(surface, luminance(ChiefPalette.eye))
        let white = ratio(surface, 1)
        return dark >= white ? ChiefPalette.eye : NSColor.white
    }

    static func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            return 0
        }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    private static func channel(_ value: CGFloat) -> CGFloat {
        if value <= 0.04045 {
            return value / 12.92
        }
        let linear = (Double(value) + 0.055) / 1.055
        return CGFloat(pow(linear, 2.4))
    }

    private static func ratio(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let lighter = max(lhs, rhs)
        let darker = min(lhs, rhs)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
