// Floating window for Grand Theft Audio and ytmusic.sh: a record that condenses as the
// song becomes yours, in the notch, which opens to show it. Reads commands one
// per line:
//   LISTEN <text>              loose cloud of dots mid-screen, "Listening" and <text> under it
//   TITLE <song name>
//   ARTIST <artist>
//   STATUS <text>              what's happening (before the download: finding; after: tagging)
//   PROG <done> <total> <estimate> <speed> <eta>  the groove condenses; numbers, or NA
//   PICK <file>                playlist picker in the island. <file> lists playlist names,
//                              one per line, recently used first; <file>.recent holds how many
//                              of them are recent and <file>.last the names picked last time
//                              (both optional). The choice goes to <file>.answer, one name per
//                              line, empty = skipped.
//   COVER <file>               album art for the label: an .m4a with a cover, or an image
//   TRACK <persistent id>      the song in Music: clicking the finished island shows it there
//   OWNED <text>               finished; <text> says where it went ("Added to Late nights")
//   ALREADY <text>             it was already in the library
//   RETRY <shortcut name>      what "Try again" runs after a FAIL
//   JOB <pid>                  the download running in the background: clicking the record
//                              to stop ends it and everything it started
//   FAIL <title>|<text>        cools down and stays up with Try again / Dismiss
//   DONE <text>                finished (ytmusic.sh on its own); closes shortly after
//   HIDE / SHOW                tucks it into the notch, as the hide button does, or brings it back
//   CLOSE                      fades out now
// Clicking the record before it's finished stops everything: the Shortcut's runner (--while),
// the JOB's processes, and it leaves F.stop so HearItOwnIt.scpt ends quietly too.
// Usage:
//   ytprogress              reads stdin; the window closes when stdin ends.
//   ytprogress --watch F    reads lines appended to file F, so several scripts can
//                           take turns writing to one window. Closes after a result, on
//                           CLOSE, if F is deleted, or after a minute with no new lines, and
//                           deletes F when it closes.
//   --while PID             also fades out as soon as process PID ends (the Shortcut's
//                           runner, so stopping the Shortcut removes the window). A result
//                           already on screen stays.
// Built by build_hearit_shortcut.py. By hand (universal, macOS 12+, so it also runs on Intel Macs):
//   swiftc -O -target arm64-apple-macos12 ytprogress.swift -o /tmp/ytp-arm64
//   swiftc -O -target x86_64-apple-macos12 ytprogress.swift -o /tmp/ytp-x86_64
//   lipo -create /tmp/ytp-arm64 /tmp/ytp-x86_64 -o ytprogress && codesign -fs - ytprogress
import AppKit
import AVFoundation

let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
let moreContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

/// The palette, taken from the app icon.
enum Ink {
    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    static let field = hex(0x160C1A)
    static let disc = hex(0x0B060D)
    static let label = hex(0x2A1A2E)
    static let plum = hex(0x5A1A45)
    static let ink = hex(0xF4EEF2)
    static let muted = hex(0xA89AA6)
    static let vapor = hex(0xDCE3F0)   // loose dots: pale and cool
    static let crimson = hex(0xFF3B5C)
    static let ember = hex(0xFF8A3D)
    static let ash = hex(0x6E6470)     // cooled, after a failure
    static let picked = hex(0xFF5F4C)  // between crimson and ember, for small dots
    static let heat = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: [crimson.cgColor, ember.cgColor] as CFArray, locations: [0, 1])!
}

/// Moves `value` toward `target`, covering most of the distance in about 3/rate seconds.
/// Every eased value in the window goes through this, so they all share one feel.
func approach(_ value: Double, _ target: Double, rate: Double, dt: Double) -> Double {
    value + (target - value) * (1 - exp(-rate * dt))
}
func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
/// Smootherstep: starts and ends at rest, no overshoot. The island and the flight use it.
func smooth(_ x: Double) -> Double {
    let t = clamp01(x)
    return t * t * t * (t * (t * 6 - 15) + 10)
}
func hash1(_ a: Double, _ b: Double) -> Double {
    let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
    return h - floor(h)
}

func makeLabel(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor,
               digits: Bool = false) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = digits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return l
}

/// The record. Drawn at a 52pt design size and scaled, so the big listening cloud and the
/// docked disc are the same drawing. One spiral groove from the label out to the rim: solid
/// up to `condensed`, loose dots past it.
final class Disc: NSView {
    static let size: CGFloat = 52
    var condensed = 0.0   // 0…1, how much of the groove is solid
    var vapor = 1.0       // 1 = loose cloud (listening), 0 = held in the groove
    var cool = 0.0        // 1 = failed: ash instead of ink
    var glow = 0.0        // the rim's one pulse when it's yours
    var gather = 0.0      // pointer over the listening cloud: it pulls in
    var ring = 0.0        // a pale ring at the rim: a click stops the download
    var spin = 0.0, time = 0.0
    var art: CGImage?
    var artAlpha = 0.0
    var clickable = false { didSet { window?.invalidateCursorRects(for: self) } }
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private static let dots = 380, turns = 4.5

    /// Every song in the air at once: each loose dot is a shade of a colour from one of these
    /// palettes. They condense to ink as the song becomes one record.
    private static let palettes: [[UInt32]] = [
        [0xFF6B6B, 0xFF8E53, 0xFFB347, 0xFFD56B, 0xF67280],  // sunset
        [0x00B4D8, 0x48CAE4, 0x90E0EF, 0x00F5D4, 0x3A86FF],  // ocean
        [0x2DC653, 0x6BCB77, 0xA7C957, 0x52B788, 0xB5E48C],  // forest
        [0x9D4EDD, 0xC77DFF, 0xE0AAFF, 0xB5179E, 0x7B6CF6],  // violet
        [0xF72585, 0x4CC9F0, 0x7FFF00, 0xFFEA00, 0xFF00E5],  // neon
        [0xFFC8DD, 0xBDE0FE, 0xCDB4DB, 0xA2D2FF, 0xFFAFCC],  // pastel
        [0xE63946, 0x2A9D8F, 0xE9C46A, 0xF4A261, 0x8AB17D],  // earth
        [0xF9C80E, 0xF86624, 0xEA3546, 0x43BCCD, 0xA06CD5],  // citrus
        [0xFF7AA2, 0xFFB5C2, 0xFF4D6D, 0xC9184A, 0xFF8FA3],  // rose
        [0x80FFDB, 0x72EFDD, 0x64DFDF, 0x56CFE1, 0x5390D9],  // aqua
    ]
    private static let colors: [(Double, Double, Double)] = (0..<dots).map { i in
        let d = Double(i)
        let pal = palettes[Int(hash1(d, 21.7) * Double(palettes.count)) % palettes.count]
        let v = pal[Int(hash1(d, 33.1) * Double(pal.count)) % pal.count]
        let shade = 0.78 + 0.34 * hash1(d, 47.9)  // a shade of it: darker or lighter
        func c(_ x: UInt32) -> Double { min(1, Double(x & 0xff) / 255 * shade) }
        return (c(v >> 16), c(v >> 8), c(v))
    }
    private static let rIn = 10.5, rOut = 23.0, rim = 24.0, labelR = 8.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    // The window never becomes active, so every click is a "first" click: take it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { !clickable }
    override func mouseDown(with event: NSEvent) {
        if clickable { onClick?() } else { super.mouseDown(with: event) }
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func resetCursorRects() { if clickable { addCursorRect(bounds, cursor: .pointingHand) } }

    private func mix(_ a: NSColor, _ b: NSColor, _ t: Double) -> NSColor {
        a.blended(withFraction: CGFloat(clamp01(t)), of: b) ?? a
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let k = min(bounds.width, bounds.height) / Disc.size
        ctx.scaleBy(x: k, y: k)
        let c = CGPoint(x: Disc.size / 2, y: Disc.size / 2)
        let front = clamp01(condensed)
        let shrink = 1 - 0.25 * vapor  // loose, the rings sit closer in so the cloud fits
        // Clockwise, like a record seen from above.
        func point(_ s: Double, dr: Double = 0, da: Double = 0) -> CGPoint {
            let r = (Disc.rIn + (Disc.rOut - Disc.rIn) * s) * shrink + dr
            let a = 2 * .pi * Disc.turns * s - spin + da
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
        func circle(_ r: Double) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }

        // Loose, the dots float in a dark field of their own, so they read over any window.
        if vapor > 0.005 {
            let a = 0.9 * vapor
            let field = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                   colors: [Ink.field.withAlphaComponent(a).cgColor,
                                            Ink.field.withAlphaComponent(a * 0.85).cgColor,
                                            Ink.field.withAlphaComponent(0).cgColor] as CFArray,
                                   locations: [0, 0.72, 1])!
            ctx.drawRadialGradient(field, startCenter: c, startRadius: 0, endCenter: c, endRadius: Disc.size / 2,
                                   options: [])
        }

        // The disc itself has weight only as far as the song has condensed.
        let body = front * (1 - vapor)
        if body > 0.005 {
            ctx.setFillColor(Ink.disc.withAlphaComponent(0.94 * body).cgColor)
            ctx.fillEllipse(in: circle(Disc.rim))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.13 * body).cgColor)
            ctx.setLineWidth(0.5)
            ctx.strokeEllipse(in: circle(Disc.rim - 0.25))
        }

        // The cut groove: one unbroken line from the label to the cutting point.
        if front > 0.002 {
            let steps = max(2, Int(front * 900))
            ctx.beginPath()
            for i in 0...steps {
                let p = point(front * Double(i) / Double(steps))
                if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.setStrokeColor(mix(Ink.ink, Ink.ash, cool).withAlphaComponent(0.62).cgColor)
            ctx.setLineWidth(0.55)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }

        // Loose dots past the cutting point: tight just ahead of it, scattered further out.
        let pale = mix(Ink.vapor, Ink.ash, cool).usingColorSpace(.sRGB) ?? Ink.vapor
        let tint = clamp01(vapor) * (1 - cool)  // full colour while loose in the air
        let hold = 1 - 0.6 * gather
        for i in 0..<Disc.dots {
            let s = (Double(i) + 0.5) / Double(Disc.dots)
            guard s > front else { continue }
            let h1 = hash1(Double(i), 1.3), h2 = hash1(Double(i), 4.7), h3 = hash1(Double(i), 9.1)
            let far = clamp01((s - front) / 0.3)
            if h3 < 0.5 * far * (1 - vapor) { continue }  // thinner away from the front
            let amp = (0.3 + 2.6 * far + 3.6 * vapor) * hold
            let drift = sin(time * (0.35 + 0.5 * h2) + h1 * 6.283)
            let dr = amp * ((h1 - 0.5) * 1.4 + 0.45 * drift)
            let da = amp * 0.05 * ((h2 - 0.5) * 2 + 0.6 * cos(time * (0.3 + 0.4 * h1) + h3 * 6.283))
            let p = point(s, dr: dr, da: da)
            let r = 0.42 + 0.38 * (1 - far) * (1 - vapor) + 0.18 * h3
            let a = (0.95 - 0.5 * far) * (1 - 0.3 * vapor * h2)
            let (cr, cg, cb) = Disc.colors[i]
            ctx.setFillColor(red: pale.redComponent + (cr - pale.redComponent) * tint,
                             green: pale.greenComponent + (cg - pale.greenComponent) * tint,
                             blue: pale.blueComponent + (cb - pale.blueComponent) * tint, alpha: a)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }

        // The cutting point.
        if front > 0.01 && front < 0.99 {
            let p = point(front), r = 0.95
            let a = (1 - vapor) * (1 - clamp01((front - 0.95) / 0.04))  // gone once it reaches the rim
            ctx.setFillColor(mix(Ink.ink, Ink.ash, cool).withAlphaComponent(a).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }

        // The label: dark, then heat as it finishes; the album cover is pressed in as soon as it's known.
        let label = circle(Disc.labelR + 1.5 * artAlpha)
        let heat = clamp01((front - 0.86) / 0.14) * (1 - cool)
        if body > 0.005 {
            ctx.setFillColor(Ink.label.withAlphaComponent(body).cgColor)
            ctx.fillEllipse(in: label)
        }
        if heat > 0.005 {
            ctx.saveGState()
            ctx.addEllipse(in: label)
            ctx.clip()
            ctx.setAlpha(CGFloat(heat))
            ctx.drawLinearGradient(Ink.heat, start: CGPoint(x: label.minX, y: label.maxY),
                                   end: CGPoint(x: label.maxX, y: label.minY), options: [])
            ctx.restoreGState()
        }
        if let art, artAlpha > 0.005 {
            ctx.saveGState()
            ctx.addEllipse(in: label)
            ctx.clip()
            ctx.setAlpha(CGFloat(artAlpha))
            ctx.draw(art, in: label)
            ctx.restoreGState()
        }
        if body > 0.2 {
            ctx.setFillColor(Ink.field.withAlphaComponent(body).cgColor)
            ctx.fillEllipse(in: circle(0.8))
        }

        // A pale ring at the rim while the pointer is on the working record (a click stops it).
        if ring > 0.005 {
            ctx.setStrokeColor(Ink.ink.withAlphaComponent(ring).cgColor)
            ctx.setLineWidth(0.9)
            ctx.strokeEllipse(in: circle(Disc.rim + 0.4))
        }

        // Rim glow: the one place the work allows itself to burn.
        if glow > 0.005 {
            ctx.saveGState()
            ctx.addEllipse(in: circle(Disc.rim + 0.6))
            ctx.setLineWidth(1.6)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.setAlpha(CGFloat(glow))
            let ring = circle(Disc.rim + 2)
            ctx.drawLinearGradient(Ink.heat, start: CGPoint(x: ring.minX, y: ring.maxY),
                                   end: CGPoint(x: ring.maxX, y: ring.minY), options: [])
            ctx.restoreGState()
        }
    }
}

/// A surface: the listening caption, and the picker (plain: it sits inside the island). Field
/// colour, hairline, 18pt continuous corners (clamped to half its height), optional plum bleed.
class Card: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var clickable = false { didSet { window?.invalidateCursorRects(for: self) } }
    private let bleed = CAGradientLayer()

    init(bleed withBleed: Bool, plain: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = plain ? nil : Ink.field.withAlphaComponent(moreContrast ? 1 : 0.94).cgColor
        layer?.borderWidth = plain ? 0 : 1
        layer?.borderColor = NSColor.white.withAlphaComponent(moreContrast ? 0.3 : 0.08).cgColor
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        if withBleed {
            bleed.colors = [Ink.plum.withAlphaComponent(0.55).cgColor, Ink.plum.withAlphaComponent(0).cgColor]
            bleed.startPoint = CGPoint(x: 0, y: 0.5)
            bleed.endPoint = CGPoint(x: 0.6, y: 0.5)
            layer?.insertSublayer(bleed, at: 0)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = min(18, bounds.height / 2)
        bleed.frame = bounds
        CATransaction.commit()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { !clickable }
    override func mouseDown(with event: NSEvent) {
        if clickable { onClick?() } else { super.mouseDown(with: event) }
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func resetCursorRects() { if clickable { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// The window's buttons. Primary: ink fill; secondary: hairline that floods with fill on hover.
final class PillButton: NSButton {
    let primary: Bool
    var text: String { didSet { restyle(); invalidateIntrinsicContentSize() } }
    private var hovering = false { didSet { restyle() } }

    init(_ text: String, primary: Bool, target: AnyObject?, action: Selector) {
        self.primary = primary
        self.text = text
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        focusRingType = .exterior
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedTitle.size().width) + 28, height: 28)
    }
    override var isEnabled: Bool { didSet { restyle() } }
    override var isHighlighted: Bool { didSet { restyle() } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }

    private func restyle() {
        let fg = primary ? Ink.field : Ink.ink
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: isEnabled ? fg : fg.withAlphaComponent(0.45),
        ])
        let live = isEnabled && (hovering || isHighlighted)
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduceMotion ? 0 : 0.25)
        if primary {
            let a: CGFloat = !isEnabled ? 0.35 : isHighlighted ? 0.75 : live ? 1 : 0.88
            layer?.backgroundColor = Ink.ink.withAlphaComponent(a).cgColor
            layer?.borderWidth = 0
        } else {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(isHighlighted ? 0.18 : live ? 0.12 : 0).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.white.withAlphaComponent(live ? 0.3 : 0.16).cgColor
        }
        CATransaction.commit()
    }
}

/// The notch, opened: pure black like the camera housing, so the two read as one shape. Its
/// top edge sits on the screen's top edge and flares into the menu bar with small concave
/// shoulders, the way the hardware notch does; the bottom corners are round.
final class Island: NSView {
    static let shoulder: CGFloat = 10
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var clickable = false { didSet { window?.invalidateCursorRects(for: self) } }
    private let fill = CAShapeLayer()
    private let clip = CAShapeLayer()
    private let glow = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fill.fillColor = NSColor.black.cgColor
        // Warmth bleeding in behind the disc, as in the icon.
        glow.type = .radial
        glow.colors = [Ink.plum.withAlphaComponent(0.75).cgColor, Ink.plum.withAlphaComponent(0).cgColor]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(fill)
        layer?.addSublayer(glow)
        layer?.mask = clip
        layer?.masksToBounds = true  // the text, too, stays inside while it grows
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The outline for an island `size` big, in its own coordinates.
    static func path(_ size: CGSize) -> CGPath {
        let b = CGRect(origin: .zero, size: size)
        let s = min(Island.shoulder, b.height / 2, b.width / 4)
        let r = max(0, min(24, b.height - s, (b.width - 2 * s) / 2))
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: b.height))
        p.addQuadCurve(to: CGPoint(x: s, y: b.height - s), control: CGPoint(x: s, y: b.height))
        p.addLine(to: CGPoint(x: s, y: r))
        p.addQuadCurve(to: CGPoint(x: s + r, y: 0), control: CGPoint(x: s, y: 0))
        p.addLine(to: CGPoint(x: b.width - s - r, y: 0))
        p.addQuadCurve(to: CGPoint(x: b.width - s, y: r), control: CGPoint(x: b.width - s, y: 0))
        p.addLine(to: CGPoint(x: b.width - s, y: b.height - s))
        p.addQuadCurve(to: CGPoint(x: b.width, y: b.height), control: CGPoint(x: b.width - s, y: b.height))
        p.closeSubpath()
        return p
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let b = CGRect(origin: .zero, size: newSize)
        let p = Island.path(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [fill, clip] {
            l.frame = b
            l.path = p
        }
        CATransaction.commit()
    }

    /// Places the warm glow behind the disc (island coordinates).
    func setGlow(center: CGPoint, radius: CGFloat, alpha: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
        glow.opacity = alpha
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { if clickable { onClick?() } }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func resetCursorRects() { if clickable { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// The island's hide button: the minimize dash of a window's yellow button, on a faint
/// circle that fills in under the pointer.
final class HideButton: NSView {
    var onClick: (() -> Void)?
    var enabled = true { didSet { window?.invalidateCursorRects(for: self) } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let live = enabled && hovering
        NSColor.white.withAlphaComponent(pressed && live ? 0.26 : live ? 0.17 : 0.08).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
        let dash = NSBezierPath()
        dash.move(to: NSPoint(x: bounds.midX - 4.5, y: bounds.midY))
        dash.line(to: NSPoint(x: bounds.midX + 4.5, y: bounds.midY))
        dash.lineWidth = 1.6
        dash.lineCapStyle = .round
        (live ? Ink.ink : Ink.muted).setStroke()
        dash.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if enabled && bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { if enabled { addCursorRect(bounds, cursor: .pointingHand) } }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Hide" }
    override func accessibilityHelp() -> String? { "Tucks the window into the notch. The download keeps going." }
    override func accessibilityPerformPress() -> Bool { if enabled { onClick?() }; return true }
}

/// The genie: a picture of the open island poured into a point in the notch, the way a
/// window minimizes into its Dock icon. The island and the target share the screen's top
/// edge, so the funnel hangs from it: the sides first bend in toward the target, then the
/// picture is drawn up through the bend and squeezed into it.
final class GenieView: NSView {
    private var strips: [CGImage] = []
    var source = NSRect.zero     // the open island, in this view's coordinates
    var target = NSRect.zero     // where it goes, with the same top edge
    var progress = 0.0 { didSet { needsDisplay = true } }  // 0 open … 1 gone

    /// Cuts the picture into 2px rows once, so each frame only places them.
    func load(_ image: CGImage) {
        let rows = 2
        strips = stride(from: 0, to: image.height, by: rows).compactMap {
            image.cropping(to: CGRect(x: 0, y: $0, width: image.width, height: min(rows, image.height - $0)))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !strips.isEmpty, progress < 1 else { return }
        let bend = smooth(progress / 0.45), pour = smooth((progress - 0.2) / 0.8)
        let top = source.maxY, hs = Double(source.height), ht = Double(target.height)
        let depth = hs + (ht - hs) * pour    // how far down the picture still reaches
        ctx.setAlpha(CGFloat(1 - smooth((progress - 0.82) / 0.18)))
        ctx.interpolationQuality = .medium
        let n = Double(strips.count)
        for (i, strip) in strips.enumerated() {
            let z0 = Double(i) / n * depth, z1 = Double(i + 1) / n * depth
            // 1 at the target's depth and above, easing to 0 at the island's bottom edge.
            let pull = hs > ht ? 1 - smooth(((z0 + z1) / 2 - ht) / (hs - ht)) : 1
            let k = CGFloat(bend * pull)
            let l = source.minX + (target.minX - source.minX) * k
            let r = source.maxX + (target.maxX - source.maxX) * k
            // A hair taller than its slot, so neighbouring rows never show a seam.
            ctx.draw(strip, in: CGRect(x: l, y: top - CGFloat(z1) - 0.25, width: r - l, height: CGFloat(z1 - z0) + 0.5))
        }
    }
}

/// Borderless panels can't take keyboard focus by default; the picker's search field needs it.
/// It also has to reach into the menu bar, where the notch is.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One row of the playlist picker. A click toggles it; the dot gathers into a heat dot.
final class PlaylistRow: NSView {
    enum Kind { case playlist, create, last }
    let name: String
    let kind: Kind
    var selected = false { didSet { update(animated: selected != oldValue) } }
    var highlighted = false { didSet { update() } }
    var onClick: (() -> Void)?
    let label = makeLabel("", 13, .regular, Ink.ink)
    private let ring = CAShapeLayer()
    private let fill = CAShapeLayer()
    private var hovering = false { didSet { update() } }

    init(name: String, kind: Kind = .playlist) {
        self.name = name
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        label.stringValue = name
        let dot = CGRect(x: 0, y: 0, width: 9, height: 9)
        for l in [ring, fill] {
            l.bounds = dot
            l.path = CGPath(ellipseIn: dot.insetBy(dx: 0.5, dy: 0.5), transform: nil)
            layer?.addSublayer(l)
        }
        ring.fillColor = nil
        ring.lineWidth = 1
        if kind == .create { ring.lineDashPattern = [1.5, 1.5] }
        if kind == .last { ring.isHidden = true }
        fill.fillColor = Ink.picked.cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: kind == .last ? 10 : 28),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.position = CGPoint(x: 15, y: bounds.midY)
        fill.position = ring.position
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { kind == .playlist ? .checkBox : .button }
    override func accessibilityLabel() -> String? { label.stringValue }
    override func accessibilityValue() -> Any? { kind == .playlist ? (selected ? 1 : 0) : nil }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    private func update(animated: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.opacity = selected ? 1 : 0
        ring.strokeColor = (selected ? NSColor.clear : Ink.muted.withAlphaComponent(0.8)).cgColor
        CATransaction.commit()
        if animated && selected && !reduceMotion {
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = 0.3
            a.toValue = 1
            a.duration = 0.25
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fill.add(a, forKey: "gather")
        }
        let tint: CGFloat = highlighted || hovering ? 0.08 : selected ? 0.04 : 0
        layer?.backgroundColor = NSColor.white.withAlphaComponent(tint).cgColor
        label.textColor = selected || highlighted ? Ink.ink : Ink.ink.withAlphaComponent(0.86)
    }
}

/// Playlist picker inside the island, under the song: a search field (which also names new
/// playlists), "same as last time", the playlists with recently used first, and Skip / Add.
/// It doesn't take the keyboard until you click it. Return picks the highlighted row (or
/// adds), Esc skips.
final class PlaylistPicker: Card, NSTextFieldDelegate {
    static let height: CGFloat = 300
    var onDone: (([String]) -> Void)?
    let search = NSTextField()
    private(set) var touched = false
    private let hint = makeLabel("Click to choose", 11, .regular, Ink.muted)
    private let well = NSView()
    private let stack = NSStackView()
    private var addButton: PillButton!
    private var rows: [PlaylistRow] = []
    private var headers: [NSView] = []
    private let newRow = PlaylistRow(name: "", kind: .create)
    private var lastRow: PlaylistRow?
    private let last: [String]
    private var chosen: [String] = []   // in the order they were picked
    private var cursor: PlaylistRow?

    init(names: [String], recent: Int, last: [String]) {
        self.last = last.filter { names.contains($0) }
        super.init(bleed: false, plain: true)

        let title = makeLabel("Add to a playlist", 12, .semibold, Ink.ink)
        search.placeholderAttributedString = NSAttributedString(string: "Search, or name a new playlist", attributes: [
            .foregroundColor: Ink.muted, .font: NSFont.systemFont(ofSize: 13),
        ])
        search.font = .systemFont(ofSize: 13)
        search.textColor = Ink.ink
        search.isBordered = false
        search.isBezeled = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.delegate = self
        well.wantsLayer = true
        well.layer?.cornerRadius = 8
        well.layer?.cornerCurve = .continuous
        well.layer?.borderWidth = 1
        well.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        setFocused(false)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        newRow.onClick = { [weak self] in self?.createFromSearch() }
        stack.addArrangedSubview(newRow)
        if !self.last.isEmpty {
            let row = PlaylistRow(name: "", kind: .last)
            let s = NSMutableAttributedString(string: "Same as last time  ", attributes: [
                .foregroundColor: Ink.ink, .font: NSFont.systemFont(ofSize: 13, weight: .medium)])
            s.append(NSAttributedString(string: self.last.joined(separator: ", "), attributes: [
                .foregroundColor: Ink.muted, .font: NSFont.systemFont(ofSize: 13)]))
            row.label.attributedStringValue = s
            row.onClick = { [weak self] in if let self { self.onDone?(self.last) } }
            lastRow = row
            stack.addArrangedSubview(row)
        }
        let recent = min(recent, names.count)
        for (i, name) in names.enumerated() {
            if recent > 0 && (i == 0 || i == recent) {
                let h = makeLabel(i == 0 ? "Recent" : "All playlists", 11, .semibold, Ink.muted)
                let box = NSView()
                h.translatesAutoresizingMaskIntoConstraints = false
                box.addSubview(h)
                NSLayoutConstraint.activate([
                    box.heightAnchor.constraint(equalToConstant: 24),
                    h.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
                    h.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4),
                ])
                headers.append(box)
                stack.addArrangedSubview(box)
            }
            let row = PlaylistRow(name: name)
            row.onClick = { [weak self, weak row] in if let row { self?.toggle(row) } }
            rows.append(row)
            stack.addArrangedSubview(row)
        }
        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let doc = FlippedView()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = doc
        doc.addSubview(stack)

        let skip = PillButton("Skip", primary: false, target: self, action: #selector(skip))
        skip.keyEquivalent = "\u{1b}"
        addButton = PillButton("Add", primary: true, target: self, action: #selector(add))
        addButton.keyEquivalent = "\r"

        for v in [title, hint, well, search, scroll, skip, addButton, doc, stack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        for v in [title, hint, well, scroll, skip, addButton] as [NSView] { addSubview(v) }
        well.addSubview(search)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            hint.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),

            well.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            well.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            well.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            well.heightAnchor.constraint(equalToConstant: 28),
            search.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 9),
            search.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -9),
            search.centerYAnchor.constraint(equalTo: well.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: well.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -10),

            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),

            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            addButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            skip.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -8),
            skip.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
        ])
        filter()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The window took (or gave back) the keyboard.
    func setKey(_ key: Bool) {
        if key { touched = true }
        hint.stringValue = key ? "Return adds · Esc skips" : "Click to choose"
    }

    /// Lights the search well while you're typing in it.
    func setFocused(_ focused: Bool) {
        well.layer?.borderColor = NSColor.white.withAlphaComponent(focused ? 0.34 : 0.1).cgColor
    }

    private func toggle(_ row: PlaylistRow) {
        row.selected.toggle()
        if row.selected { chosen.append(row.name) } else { chosen.removeAll { $0 == row.name } }
        updateAdd()
    }

    /// Adds what's typed in the search field as a new playlist, picked.
    private func createFromSearch() {
        let name = search.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let row = PlaylistRow(name: name)
        row.onClick = { [weak self, weak row] in if let row { self?.toggle(row) } }
        rows.insert(row, at: 0)
        stack.insertArrangedSubview(row, at: 1)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        toggle(row)
        search.stringValue = ""
        filter()
    }

    private func filter() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        for row in rows {
            row.isHidden = !q.isEmpty && !row.name.localizedCaseInsensitiveContains(q)
        }
        for h in headers { h.isHidden = !q.isEmpty }
        lastRow?.isHidden = !q.isEmpty
        let exists = rows.contains { $0.name.caseInsensitiveCompare(q) == .orderedSame }
        newRow.isHidden = q.isEmpty || exists
        if !newRow.isHidden { newRow.label.stringValue = "New playlist “\(q)”" }
        moveCursor(to: nil)
        updateAdd()
    }

    private func updateAdd() {
        addButton.text = chosen.count > 1 ? "Add to \(chosen.count) playlists" : "Add"
        addButton.isEnabled = !chosen.isEmpty || !newRow.isHidden
    }

    private func moveCursor(to row: PlaylistRow?) {
        cursor?.highlighted = false
        cursor = row
        row?.highlighted = true
        if let row { row.scrollToVisible(row.bounds) }
    }

    private func moveCursor(by step: Int) {
        let visible = stack.arrangedSubviews.compactMap { $0 as? PlaylistRow }.filter { !$0.isHidden }
        guard !visible.isEmpty else { return }
        let i = cursor.flatMap { visible.firstIndex(of: $0) }.map { $0 + step } ?? (step > 0 ? 0 : visible.count - 1)
        moveCursor(to: visible[min(max(0, i), visible.count - 1)])
    }

    func controlTextDidChange(_ note: Notification) { filter() }

    /// Return in the search field: pick the highlighted row; else the playlist you typed
    /// (or the top match), else create it as a new one; with nothing typed, add.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): moveCursor(by: 1); return true
        case #selector(NSResponder.moveUp(_:)): moveCursor(by: -1); return true
        case #selector(NSResponder.cancelOperation(_:)): skip(); return true
        case #selector(NSResponder.insertNewline(_:)):
            if let row = cursor, !row.isHidden { row.onClick?(); return true }
            let q = search.stringValue.trimmingCharacters(in: .whitespaces)
            let visible = rows.filter { !$0.isHidden }
            let match = rows.first { $0.name.caseInsensitiveCompare(q) == .orderedSame } ?? visible.first
            if q.isEmpty { add() }
            else if let row = match { toggle(row); search.stringValue = ""; filter() }
            else { createFromSearch() }
            return true
        default:
            return false
        }
    }

    @objc func add() {
        if !newRow.isHidden { createFromSearch() }
        onDone?(chosen)
    }
    @objc func skip() { onDone?([]) }
}

final class HUD: NSObject, NSApplicationDelegate {
    let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                         styleMask: [.nonactivatingPanel, .borderless],
                         backing: .buffered, defer: false)
    let island = Island()
    let caption = Card(bleed: false)
    let captionTitle = makeLabel("Listening", 12, .semibold, Ink.ink)
    let captionText = makeLabel("Play the song near your Mac.", 12, .regular, Ink.muted)
    let disc = Disc()
    let titleLabel = makeLabel("YouTube → Music", 13, .semibold, Ink.ink)
    let artistLabel = makeLabel("", 12, .regular, Ink.muted)
    let statusLabel = makeLabel("Starting", 11, .regular, Ink.muted, digits: true)
    var actions: NSStackView?
    var picker: PlaylistPicker?
    var pickerOpened = 0.0

    // While listening the cloud sits big in the middle of the screen. On the first other
    // command it flies up into the notch's ear, and the island pours out of it to show the song.
    enum Phase { case listening, traveling, docked }
    enum Outcome { case none, owned, already, failed }
    var phase = Phase.docked
    var outcome = Outcome.none
    let bigSize: CGFloat = 160
    let discSize: CGFloat = 80      // the record in the open island
    let discSlot: CGFloat = 64      // the room it's laid out in: the record is drawn bigger than
                                    // its slot, over the margins, so the island keeps its size
    var screen = NSRect.zero        // the whole screen we're on; the island hangs from its top
    var notch = NSRect.zero         // the camera housing, or a zero-height slot at the top centre
    var hasNotch = false
    var topInset: CGFloat = 0       // the notch (or menu bar) height: text starts below it
    var settingFrame = false

    // The island opens on one smooth curve from the notch, once the disc has touched it.
    var openStart: Double?          // when the notch began opening (nil: open, no animation)
    var closeStart: Double?         // when it began folding back in
    var shape = NSRect.zero         // the open island, its height easing toward islandTarget()
    var collapsing = false

    // Hidden, the island pours into the notch like a window minimizing into its Dock icon,
    // and the record keeps turning small beside the camera until you click it back open.
    let hideButton = HideButton()
    let genie = GenieView()
    let compactLabel = makeLabel("", 11, .semibold, Ink.ink, digits: true)  // the percentage, beside the notch
    var tucked = false              // hidden in the notch (or on its way there)
    var tuckStart: Double?          // the genie is playing
    var heldLines: [String] = []    // commands that arrived mid-genie, for when it's done
    var hideAlpha = 0.0
    var stopHint = 0.0             // the pointer is on the working record: a click stops it
    var jobPid: pid_t?              // the download, for stopping it
    var stopped = false

    // The driver: one value, ownership 0…1, that everything on the disc follows.
    var base = 0.0                  // what the last command set
    var creep: (lo: Double, hi: Double, start: Double)?  // slow progress while a step has no numbers
    var shown = 0.0                 // what's drawn; eases toward the target
    var pace = 0.12                 // spin speed, eases toward the stage's
    var downloaded = false
    var glowStart: Double?
    var hoverIsland = false, hoverDisc = false
    var statusText = ""
    var holdUntil: Double?          // a result stays up until this clock time
    var closing = false, closeWhenDocked = false, closeAfterPick = false
    var pendingPick: String?        // PICK that arrived mid-flight; shown once the island is open
    var retryShortcut: String?
    var trackID: String?            // the song's persistent ID in Music, for "show it in Music"
    var lastTick = CACurrentMediaTime()
    var now: Double { CACurrentMediaTime() }

    var travelStart = 0.0
    var travelFrom = NSRect.zero    // disc rect (screen coords) when the trip began
    var captionFrom = NSRect.zero   // caption rect (screen coords), so it fades where it was

    func applicationDidFinishLaunching(_ note: Notification) {
        // Above the menu bar, so the island can grow out of the notch.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let root = NSView(frame: panel.contentView!.bounds)
        panel.contentView = root
        for v in [island, genie, caption, disc] as [NSView] { root.addSubview(v) }
        for v in [titleLabel, artistLabel, statusLabel, hideButton, compactLabel] as [NSView] { island.addSubview(v) }
        for v in [captionTitle, captionText] as [NSView] { caption.addSubview(v) }
        genie.isHidden = true
        compactLabel.alignment = .center
        compactLabel.alphaValue = 0
        hideButton.alphaValue = 0

        island.onHover = { [weak self] in self?.hoverIsland = $0; self?.showStatus() }
        island.onClick = { [weak self] in self?.islandClicked() }
        disc.onHover = { [weak self] in self?.hoverDisc = $0; self?.hoverListening(); self?.showStatus() }
        disc.onClick = { [weak self] in self?.discClicked() }
        hideButton.onClick = { [weak self] in self?.hide() }

        findNotch()
        // Opened by hearit_listen.sh (the file starts with LISTEN): the cloud, mid-screen.
        if let path = watchPath, (try? String(contentsOfFile: path, encoding: .utf8))?.hasPrefix("LISTEN") == true {
            phase = .listening
            disc.vapor = 1
            disc.clickable = true
            island.isHidden = true
            layoutListening()
        } else {
            disc.vapor = 0
            caption.isHidden = true
            open()
        }

        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self, let p = self.picker else { return }
            p.setKey(true)
            self.panel.makeFirstResponder(p.search)
        }
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.picker?.setKey(false)
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        if phase == .listening { announce("Listening. Play the song near your Mac.") }

        // The one clock: everything that moves is stepped here.
        let clock = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(clock, forMode: .common)

        if let pid = ownerPid {
            let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] timer in
                guard kill(pid, 0) != 0 && errno == ESRCH else { return }
                timer.invalidate()
                // The last lines may still be on their way: give them a moment.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.abandon() }
            }
            RunLoop.main.add(t, forMode: .common)
        }

        Thread.detachNewThread { [weak self] in
            if let path = watchPath {
                HUD.watch(path) { line in DispatchQueue.main.async { self?.handle(line) } }
            } else {
                while let line = readLine() {
                    DispatchQueue.main.async { self?.handle(line) }
                }
            }
            DispatchQueue.main.async { self?.requestClose() }
        }
    }

    /// The screen with the pointer, and its camera housing. Without a notch (an external
    /// display, an older Mac) the island opens from a slot at the top centre instead.
    func findNotch() {
        let mouse = NSEvent.mouseLocation
        let scr = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        screen = scr.frame
        let top = scr.safeAreaInsets.top
        if top > 0, let l = scr.auxiliaryTopLeftArea, let r = scr.auxiliaryTopRightArea {
            hasNotch = true
            notch = NSRect(x: screen.minX + l.width, y: screen.maxY - top,
                           width: screen.width - l.width - r.width, height: top)
            topInset = top
        } else {
            notch = NSRect(x: screen.midX - 60, y: screen.maxY, width: 120, height: 0)
            topInset = max(0, screen.maxY - scr.visibleFrame.maxY)
        }
    }

    /// Follows a file like `tail -f`, calling `send` for each new line. Returns when
    /// the file is gone or nothing new arrives for `idleLimit` seconds.
    static func watch(_ path: String, send: (String) -> Void) {
        let idleLimit: TimeInterval = 60
        var offset: UInt64 = 0
        var pending = Data()
        var lastLine = Date()
        while let fh = FileHandle(forReadingAtPath: path) {
            try? fh.seek(toOffset: offset)
            let data = fh.readDataToEndOfFile()
            try? fh.close()
            if !data.isEmpty {
                offset += UInt64(data.count)
                pending.append(data)
                lastLine = Date()
                while let nl = pending.firstIndex(of: 10) {
                    send(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                    pending = Data(pending[(nl + 1)...])
                }
            }
            if Date().timeIntervalSince(lastLine) > idleLimit { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: Commands

    func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first, !closing else { return }
        let rest = parts.count > 1 ? parts[1] : ""
        // Mid-genie, lines wait for it to land. Hidden, a choice to make or a failure brings
        // the island back out first.
        if tuckStart != nil { heldLines.append(line); return }
        if tucked && (cmd == "PICK" || cmd == "FAIL") { heldLines.append(line); restore(); return }
        // Listening is over (a CLOSE just fades out where it is).
        if phase == .listening && !["LISTEN", "CLOSE", "RETRY", "COVER", "TRACK", "JOB", "HIDE", "SHOW"].contains(cmd) { travel() }
        switch cmd {
        case "LISTEN":
            if !rest.isEmpty { captionText.stringValue = rest }
            base = 0
            layoutListening()
        case "TITLE":
            titleLabel.stringValue = rest
            if outcome == .none { announce("Heard \(rest)") }
        case "ARTIST":
            artistLabel.stringValue = rest
        case "STATUS":
            guard outcome == .none else { return }
            setStatus(rest)
            creep = downloaded ? (0.86, 0.95, now) : (0.12, 0.24, now)
        case "PROG":
            let f = rest.split(separator: " ").map { Double($0) }
            guard outcome == .none, f.count >= 5, let done = f[0] else { return }
            guard let total = f[1] ?? f[2], total > 0 else { return }
            let frac = min(done / total, 1)
            base = max(base, 0.25 + 0.6 * frac)
            creep = nil
            if frac >= 0.999 { downloaded = true }
            var text = "Downloading · \(Int(frac * 100))%"
            if let eta = f[4], eta > 0 { text += " · \(Int(eta))s left" }
            setStatus(text)
            compactLabel.stringValue = "\(Int(frac * 100))%"
        case "COVER":
            loadCover(rest)
        case "TRACK":
            trackID = rest.isEmpty ? nil : rest
        case "OWNED":
            finish(.owned, rest.isEmpty ? "In your library" : "In your library · " + rest)
        case "ALREADY":
            finish(.already, rest.isEmpty ? "Already in your library" : "Already in your library · " + rest)
        case "DONE":
            finish(.owned, rest, quick: true)
        case "RETRY":
            retryShortcut = rest.isEmpty ? nil : rest
        case "JOB":
            jobPid = pid_t(rest)
        case "FAIL":
            fail(rest)
        case "PICK":
            if phase == .docked { showPicker(rest) } else { pendingPick = rest }
        case "HIDE":
            hide()
        case "SHOW":
            restore()
        case "CLOSE":
            fadeOut()
        default:
            break
        }
    }

    func setStatus(_ text: String) {
        statusText = text
        showStatus()
    }

    /// The status line, or what a click does while the pointer is over a finished island.
    func showStatus() {
        statusLabel.stringValue = hoverIsland && island.clickable && !tucked ? "Click to show it in Music"
            : hoverDisc && canStop ? "Click the record to stop" : statusText
    }

    /// Still working, open, with nothing waiting on you: the record stops it, and it can hide.
    var canStop: Bool { phase == .docked && outcome == .none && !tucked && !closing }
    var canHide: Bool { canStop && picker == nil && pendingPick == nil && closeStart == nil }

    /// The song is in the library (or was already): the disc finishes, the cover presses
    /// in, the rim glows once, and the island stays open a moment so you can see it.
    func finish(_ o: Outcome, _ text: String, quick: Bool = false) {
        guard outcome == .none else { return }
        outcome = o
        base = 1
        creep = nil
        glowStart = now
        statusLabel.textColor = Ink.ink
        setStatus(text)
        island.clickable = !quick
        disc.clickable = !quick
        compactLabel.stringValue = "✓"
        compactLabel.textColor = Ink.picked
        if o == .already { NSSound(named: "Tink")?.play() }
        holdUntil = now + (quick ? 1.6 : 3.4)
        announce(quick ? text : "\(titleLabel.stringValue). \(text)")
    }

    /// Something went wrong: the groove cools, and the island says why and offers a retry.
    func fail(_ rest: String) {
        guard outcome == .none else { return }
        outcome = .failed
        let parts = rest.split(separator: "|", maxSplits: 1).map(String.init)
        titleLabel.stringValue = parts.first ?? "Something went wrong"
        artistLabel.stringValue = parts.count > 1 ? parts[1] : ""
        artistLabel.maximumNumberOfLines = 3
        artistLabel.lineBreakMode = .byWordWrapping
        statusLabel.isHidden = true
        disc.clickable = false
        creep = nil
        base = shown
        var buttons: [NSView] = [PillButton("Dismiss", primary: retryShortcut == nil, target: self, action: #selector(dismiss))]
        if retryShortcut != nil {
            buttons.append(PillButton("Try again", primary: true, target: self, action: #selector(retry)))
        }
        let row = NSStackView(views: buttons)
        row.spacing = 8
        island.addSubview(row)
        actions = row
        NSSound(named: "Basso")?.play()
        holdUntil = now + 15
        announce("\(titleLabel.stringValue). \(artistLabel.stringValue)")
    }

    @objc func dismiss() { fadeOut() }

    @objc func retry() {
        if let name = retryShortcut { run("/usr/bin/shortcuts", ["run", name]) }
        fadeOut()
    }

    /// Brings Music forward with the new song selected in the library (or just opens Music
    /// when there's no track to point at).
    func showInMusic() {
        guard island.clickable else { return }
        if let id = trackID, !id.isEmpty, id.allSatisfy(\.isHexDigit) {
            run("/usr/bin/osascript", ["-e", """
                tell application "Music"
                    activate
                    try
                        reveal (some track of library playlist 1 whose persistent ID is "\(id)")
                    end try
                end tell
                """])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app"))
        }
        fadeOut()
    }

    func run(_ tool: String, _ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        try? p.run()
    }

    /// The record: listening or working, a click stops it all; hidden, it brings the island
    /// back; finished, it shows the song in Music.
    func discClicked() {
        if tucked { islandClicked(); return }
        if phase == .listening || canStop { stop(); return }
        if outcome == .owned || outcome == .already { showInMusic() }
    }

    func islandClicked() {
        guard tuckStart == nil else { return }
        if tucked && outcome == .none { restore() } else { showInMusic() }
    }

    /// Stops listening, or the download once the song is known: leaves F.stop for
    /// HearItOwnIt.scpt, ends the Shortcut's runner and every process the download started.
    func stop() {
        guard !stopped else { return }
        stopped = true
        if let path = watchPath { FileManager.default.createFile(atPath: path + ".stop", contents: nil) }
        var pids = jobPid.map { tree($0) } ?? []
        if let pid = ownerPid { pids += tree(pid) }
        pids.removeAll { $0 == getpid() }
        for pid in pids { kill(pid, SIGTERM) }
        // Anything that ignored it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { for pid in pids { kill(pid, SIGKILL) } }
        picker = nil
        pendingPick = nil
        closeAfterPick = false
        closeWhenDocked = false
        announce("Stopped")
        fadeOut()
    }

    /// `pid` and everything under it, from one `ps` listing.
    func tree(_ pid: pid_t) -> [pid_t] {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-o", "pid=,ppid="]
        p.standardOutput = out
        guard (try? p.run()) != nil else { return [pid] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var children: [pid_t: [pid_t]] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ").compactMap { pid_t($0) }
            if f.count == 2 { children[f[1], default: []].append(f[0]) }
        }
        var all = [pid], i = 0
        while i < all.count { all += children[all[i]] ?? []; i += 1 }
        return all
    }

    func hoverListening() {
        guard phase == .listening && !stopped else { return }
        captionText.stringValue = hoverDisc ? "Click the dots to stop." : "Play the song near your Mac."
        layoutListening()
    }

    /// Loads the album cover for the label, shrunk once so drawing it every frame is cheap.
    func loadCover(_ path: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let url = URL(fileURLWithPath: path)
            var data: Data?
            if ["jpg", "jpeg", "png", "heic"].contains(url.pathExtension.lowercased()) {
                data = try? Data(contentsOf: url)
            } else {
                let asset = AVURLAsset(url: url)
                data = AVMetadataItem.metadataItems(from: asset.commonMetadata, withKey: AVMetadataKey.commonKeyArtwork,
                                                    keySpace: .common).first?.dataValue
            }
            guard let data, let src = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let ctx = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: 128, height: 128))
            let small = ctx.makeImage()
            DispatchQueue.main.async { self?.disc.art = small }
        }
    }

    func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: The clock

    func tick() {
        let t = now
        let dt = min(0.1, t - lastTick)
        lastTick = t
        guard !closing || collapsing else { return }

        var target = base
        if let c = creep { target = max(target, c.lo + (c.hi - c.lo) * (1 - exp(-(t - c.start) / 5))) }
        shown = approach(shown, target, rate: reduceMotion ? 12 : 4, dt: dt)
        disc.condensed = shown
        disc.vapor = approach(disc.vapor, phase == .listening ? 1 : outcome == .failed ? 0.5 : 0, rate: 3, dt: dt)
        disc.cool = approach(disc.cool, outcome == .failed ? 1 : 0, rate: 3, dt: dt)
        disc.gather = approach(disc.gather, phase == .listening && hoverDisc ? 1 : 0, rate: 10, dt: dt)
        disc.artAlpha = approach(disc.artAlpha, phase != .listening && outcome != .failed && disc.art != nil ? 1 : 0,
                                 rate: 4, dt: dt)
        if let g = glowStart {
            let p = (t - g) / 1.4
            disc.glow = reduceMotion ? (p < 1 ? 0.7 : 0) : p < 1 ? sin(p * .pi) : 0
        }
        if !reduceMotion {
            let speed = phase == .listening ? 0.12 : outcome == .failed ? 0.05 : outcome != .none ? 0.8 : 0.5
            pace = approach(pace, speed, rate: 2, dt: dt)
            disc.spin += pace * dt
            disc.time += dt
        }
        disc.needsDisplay = true

        switch phase {
        case .traveling: travelStep()
        case .docked: stepIsland(t, dt)
        case .listening: break
        }

        if let p = picker {
            let editing = (panel.firstResponder as? NSTextView)?.delegate === p.search
            p.setFocused(editing && panel.isKeyWindow)
            if !p.touched && t - pickerOpened > 60 { p.onDone?([]) }  // nobody's there: skip
        }
        if let h = holdUntil, !closing {
            if hoverIsland { holdUntil = max(h, t + 1.2) }
            else if t >= h && phase == .docked && picker == nil { holdUntil = nil; fadeOut() }
        }
    }

    // MARK: Layout

    /// The cloud mid-screen, the caption pill under it.
    func layoutListening() {
        let gap: CGFloat = 14, h: CGFloat = 30
        captionTitle.sizeToFit()
        captionText.sizeToFit()
        let capW = 14 + captionTitle.frame.width + 6 + captionText.frame.width + 14
        let w = max(bigSize, capW) + 20
        let visible = NSScreen.screens.first { $0.frame == screen }?.visibleFrame ?? screen
        setFrame(NSRect(x: (visible.midX - w / 2).rounded(), y: (visible.midY - bigSize / 2 - gap - h).rounded(),
                        width: ceil(w), height: bigSize + gap + h))
        disc.frame = NSRect(x: (ceil(w) - bigSize) / 2, y: gap + h, width: bigSize, height: bigSize)
        caption.frame = NSRect(x: ((ceil(w) - capW) / 2).rounded(), y: 0, width: ceil(capW), height: h)
        captionTitle.setFrameOrigin(NSPoint(x: 14, y: (h - captionTitle.frame.height) / 2))
        captionText.setFrameOrigin(NSPoint(x: captionTitle.frame.maxX + 6, y: (h - captionText.frame.height) / 2))
    }

    /// Where the text starts, from the open island's left edge.
    var textX: CGFloat { Island.shoulder + 16 + discSlot + 14 }

    /// The open island is one fixed width, so nothing in it ever shifts; long text truncates.
    /// With a notch, the disc sits beside the camera housing, so it's at least that wide.
    func islandWidth() -> CGFloat {
        let minWidth = hasNotch ? notch.width + 2 * (Island.shoulder + 16 + discSlot + 12) : 0
        return ceil(min(max(420, minWidth), screen.width - 40))
    }

    /// Room on the right for the hide button, kept even when it's not showing.
    func textColumn(_ width: CGFloat) -> CGFloat { width - textX - 20 - Island.shoulder - 26 }

    /// Height of the text block for an island `width` wide.
    func textHeight(_ width: CGFloat) -> CGFloat {
        var h = titleLabel.intrinsicContentSize.height
        if !artistLabel.stringValue.isEmpty {
            h += 1 + artistLabel.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: textColumn(width), height: 200)).height
        }
        if !statusLabel.isHidden { h += 3 + statusLabel.intrinsicContentSize.height }
        return h
    }

    /// The band under the notch line that holds the text.
    func band(_ width: CGFloat) -> CGFloat { max(64, textHeight(width) + 18) }
    func topSection(_ width: CGFloat) -> CGFloat { topInset + band(width) }
    /// The disc's row: the notch line plus a fixed band. Text that wraps (a long error) grows
    /// the island downward without moving the disc.
    var discRow: CGFloat { topInset + 64 }
    var actionsHeight: CGFloat { actions == nil ? 0 : 40 }

    func islandTarget() -> NSRect { tucked ? compactTarget() : openTarget() }

    /// The open island: centred on the notch, hanging from the top of the screen.
    func openTarget() -> NSRect {
        let w = islandWidth()
        let h = topSection(w) + actionsHeight + (picker == nil ? 0 : PlaylistPicker.height + 6)
        return NSRect(x: notch.midX - w / 2, y: screen.maxY - h, width: w, height: h)
    }

    /// Hidden: the notch with a small ear on each side, the record in the left one and the
    /// percentage in the right. It drops a few points under the pointer.
    var ear: CGFloat { max(36, topInset + 6) }
    var compactHeight: CGFloat { max(24, topInset) }
    func compactTarget() -> NSRect {
        let w = notch.width + 2 * (Island.shoulder + ear)
        let h = compactHeight + (hoverIsland || hoverDisc ? 3 : 0)
        return NSRect(x: (notch.midX - w / 2).rounded(), y: screen.maxY - h, width: ceil(w), height: h)
    }
    func compactFrame() -> NSRect {
        let c = compactTarget()
        return NSRect(x: c.minX, y: floor(screen.maxY - compactHeight - 3), width: c.width,
                      height: screen.maxY - floor(screen.maxY - compactHeight - 3))
    }

    /// Where the disc lives: beside the camera housing, in whole points. Once it's there it
    /// doesn't move again (unless it's hidden).
    func discSpot() -> NSRect { tucked ? miniSpot() : openSpot() }
    func openSpot() -> NSRect {
        NSRect(x: (notch.midX - islandWidth() / 2 + Island.shoulder + 16 + (discSlot - discSize) / 2).rounded(),
               y: (screen.maxY - discRow / 2 - discSize / 2).rounded(), width: discSize, height: discSize)
    }
    /// The record, small, in the left ear: the "icon" the island minimizes into.
    func miniSpot() -> NSRect {
        let s = (compactHeight - 9).rounded(), c = compactTarget()
        return NSRect(x: (c.minX + Island.shoulder + (ear - s) / 2 + 2).rounded(),
                      y: (screen.maxY - compactHeight / 2 - s / 2).rounded(), width: s, height: s)
    }

    /// The island at opening progress `p`. It reaches out toward the disc first, the far side
    /// follows, and it drops to its full height, all on one smooth curve.
    func islandRect(_ p: Double) -> NSRect {
        let open = shape
        let l = CGFloat(smooth(p / 0.7)), r = CGFloat(smooth((p - 0.12) / 0.7)), v = CGFloat(smooth((p - 0.04) / 0.9))
        let x0 = notch.minX + (open.minX - notch.minX) * l
        let x1 = notch.maxX + (open.maxX - notch.maxX) * r
        let h = notch.height + (open.height - notch.height) * v
        return NSRect(x: x0, y: screen.maxY - h, width: x1 - x0, height: h)
    }

    /// Frames are set in whole points, so the window server never rounds them and drags
    /// what's inside by a pixel.
    func setFrame(_ f: NSRect) {
        guard f != panel.frame else { return }
        settingFrame = true
        panel.setFrame(f, display: true)
        settingFrame = false
        if panel.hasShadow { panel.invalidateShadow() }
    }

    /// The island opens straight out of the notch, with no flight before it (started without
    /// LISTEN, or under reduced motion).
    func open() {
        phase = .docked
        disc.clickable = outcome == .none
        let to = islandTarget()
        shape = to
        island.isHidden = false
        if reduceMotion {
            openStart = nil
        } else {
            openStart = now
        }
        stepIsland(now, 0)
        land()
    }

    func stepIsland(_ t: Double, _ dt: Double) {
        hideAlpha = approach(hideAlpha, canHide && tuckStart == nil ? 1 : 0, rate: 10, dt: dt)
        hideButton.enabled = canHide
        stopHint = approach(stopHint, hoverDisc && canStop ? 1 : 0, rate: 10, dt: dt)
        if let s = tuckStart, closeStart == nil {
            let g = clamp01((t - s) / 0.62)
            if g < 1 { layoutTuck(tucked ? g : 1 - g, t); return }
            landTuck()
        } else if tuckStart != nil {
            landTuck()  // closing mid-genie: skip to where it was going
        }
        // Only the height ever changes once open (the picker, a wrapped error).
        let to = islandTarget()
        let r = reduceMotion ? 1 : CGFloat(1 - exp(-14 * dt))
        shape = NSRect(x: to.minX, y: to.minY, width: to.width, height: shape.height + (to.height - shape.height) * r)
        if abs(shape.height - to.height) < 0.5 { shape = to }

        var p = 1.0, discScale = 1.0
        if let s = openStart {
            p = clamp01((t - s) / 0.85)
            discScale = smooth(p / 0.6)
        }
        if let c = closeStart {
            let k = t - c
            p = min(p, clamp01(1 - (k - 0.12) / 0.5))
            discScale = min(discScale, smooth((p - 0.35) / 0.45))
            if k > 0.72 { finishClosing(); return }
        }
        disc.ring = 0.45 * stopHint
        layoutIsland(p, discScale, t)
    }

    // MARK: Hiding

    /// Pours the island into the notch; the record shrinks into the left ear and keeps going.
    func hide() {
        guard canHide, tuckStart == nil else { return }
        let image = snapshot()
        tucked = true
        hoverIsland = false
        island.clickable = true
        disc.clickable = true
        startTuck(image)
        announce("Hidden in the notch. Click it to bring it back.")
    }

    /// Brings it back out of the notch, the genie played backwards.
    func restore() {
        guard tucked, tuckStart == nil, !closing else { return }
        tucked = false
        island.clickable = outcome == .owned || outcome == .already
        disc.clickable = outcome == .none || island.clickable
        hoverIsland = false
        startTuck(snapshot())
    }

    func startTuck(_ image: CGImage?) {
        shape = islandTarget()
        guard let image, !reduceMotion else { landTuck(); return }
        genie.load(image)
        tuckStart = now
        layoutTuck(tucked ? 0 : 1, now)
    }

    /// The genie is done: the steady state takes over, and anything that waited happens.
    func landTuck() {
        tuckStart = nil
        genie.isHidden = true
        shape = islandTarget()
        let lines = heldLines
        heldLines = []
        for line in lines { handle(line) }
        if !tucked { land() }
    }

    /// One genie frame: `g` 0 open … 1 hidden. The window stays the open island's size the
    /// whole time; the compact island waits underneath and the picture pours into its ear.
    func layoutTuck(_ g: Double, _ t: Double) {
        let open = openTarget(), mini = miniSpot(), big = openSpot()
        let f = NSRect(x: floor(open.minX), y: floor(open.minY), width: ceil(open.maxX) - floor(open.minX),
                       height: screen.maxY - floor(open.minY))
        setFrame(f)
        panel.hasShadow = false
        let compact = compactTarget()
        island.frame = compact.offsetBy(dx: -f.minX, dy: -f.minY)
        for v in [titleLabel, artistLabel, statusLabel, hideButton] as [NSView] { v.alphaValue = 0 }
        island.setGlow(center: .zero, radius: 1, alpha: 0)
        compactLabel.alphaValue = CGFloat(smooth((g - 0.7) / 0.3))
        placeCompactLabel()

        // The record leads: it settles into the ear first, then the island pours in after it.
        let d = CGFloat(smooth(g / 0.55))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * d }
        let s = mix(big.width, mini.width)
        let c = NSPoint(x: mix(big.midX, mini.midX), y: mix(big.midY, mini.midY))
        disc.frame = NSRect(x: c.x - s / 2 - f.minX, y: c.y - s / 2 - f.minY, width: s, height: s)
        disc.isHidden = false

        genie.isHidden = false
        genie.frame = NSRect(origin: .zero, size: f.size)
        genie.source = open.offsetBy(dx: -f.minX, dy: -f.minY)
        let earRect = NSRect(x: compact.minX + Island.shoulder, y: screen.maxY - compactHeight, width: ear, height: compactHeight)
        genie.target = earRect.offsetBy(dx: -f.minX, dy: -f.minY)
        genie.progress = smooth((g - 0.08) / 0.92)
    }

    func placeCompactLabel() {
        let c = island.bounds, h = compactLabel.intrinsicContentSize.height
        compactLabel.frame = NSRect(x: c.width - Island.shoulder - ear - 2, y: c.height - compactHeight / 2 - h / 2,
                                    width: ear, height: h)
    }

    /// A picture of the open island as it is now (or would be, opened): its outline, the glow
    /// behind the record and the text, at the screen's resolution. The record is left out:
    /// it moves on its own.
    func snapshot() -> CGImage? {
        let open = openTarget()
        let scale = panel.backingScaleFactor
        guard let ctx = CGContext(data: nil, width: Int(ceil(open.width * scale)), height: Int(ceil(open.height * scale)),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.addPath(Island.path(open.size))
        ctx.clip()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: open.size))
        let spot = openSpot()
        let center = CGPoint(x: spot.midX - open.minX, y: spot.midY - open.minY)
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [Ink.plum.withAlphaComponent(0.75).cgColor, Ink.plum.withAlphaComponent(0).cgColor] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center,
                               endRadius: discSize * 1.3, options: [])
        let frames = contentFrames(open)
        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        // Not the hide button: it's on its way out (or not back yet).
        for (view, frame) in frames where view !== hideButton && frame.width > 0 && frame.height > 0 {
            view.frame = frame
            let alpha = view.alphaValue
            view.alphaValue = 1  // hidden while tucked; the picture needs it
            defer { view.alphaValue = alpha }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsctx
            rep.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        return ctx.makeImage()
    }

    /// Where the text and the hide button sit in an open island, in its own coordinates.
    func contentFrames(_ open: NSRect) -> [(NSView, NSRect)] {
        let h = open.height, col = textColumn(open.width), bandH = band(open.width)
        var y = h - topInset - (bandH - textHeight(open.width)) / 2
        var out: [(NSView, NSRect)] = []
        func put(_ l: NSTextField, _ lh: CGFloat, gap: CGFloat) {
            y -= gap + lh
            out.append((l, NSRect(x: textX, y: y, width: col, height: lh)))
        }
        put(titleLabel, titleLabel.intrinsicContentSize.height, gap: 0)
        if !artistLabel.stringValue.isEmpty {
            put(artistLabel, artistLabel.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: col, height: 200)).height, gap: 1)
        }
        if !statusLabel.isHidden { put(statusLabel, statusLabel.intrinsicContentSize.height, gap: 3) }
        let b: CGFloat = 22
        out.append((hideButton, NSRect(x: open.width - Island.shoulder - 16 - b, y: (h - discRow / 2 - b / 2).rounded(),
                                       width: b, height: b)))
        return out
    }

    /// One window holds the island and the disc. Its frame is the open island, in whole
    /// points, so the disc's place inside it is exact and constant.
    func layoutIsland(_ p: Double, _ discScale: Double, _ t: Double) {
        let isl = islandRect(p), open = shape
        let bottom = floor(screen.maxY - max(open.height, isl.height))
        let f = tucked ? compactFrame()
            : NSRect(x: floor(open.minX), y: bottom, width: ceil(open.maxX) - floor(open.minX), height: screen.maxY - bottom)
        setFrame(f)
        island.frame = isl.offsetBy(dx: -f.minX, dy: -f.minY)
        let spot = discSpot(), s = spot.width * CGFloat(discScale)
        disc.frame = NSRect(x: spot.midX - s / 2 - f.minX, y: spot.midY - s / 2 - f.minY, width: s, height: s)
        disc.isHidden = discScale < 0.01
        panel.hasShadow = p > 0.97 && closeStart == nil && !tucked

        if tucked {
            for v in [titleLabel, artistLabel, statusLabel, hideButton] as [NSView] { v.alphaValue = 0 }
            compactLabel.alphaValue = closeStart == nil ? 1 : 1 - CGFloat(smooth((t - closeStart!) / 0.15))
            placeCompactLabel()
            island.setGlow(center: .zero, radius: 1, alpha: 0)
            return
        }
        compactLabel.alphaValue = 0

        // Content sits where it belongs in the open island and fades in once the island is
        // there, one line after another, so it never slides.
        let h = island.bounds.height, left = open.minX - isl.minX, top = topSection(open.width)
        for (v, r) in contentFrames(open) { v.frame = r.offsetBy(dx: left, dy: h - open.height) }
        if let row = actions {
            let sz = row.fittingSize
            row.frame = NSRect(x: left + open.width - Island.shoulder - 14 - sz.width, y: h - top - 34, width: sz.width, height: 28)
        }
        picker?.frame = NSRect(x: left + Island.shoulder + 4, y: h - top - actionsHeight - 4 - PlaylistPicker.height,
                               width: open.width - 2 * Island.shoulder - 8, height: PlaylistPicker.height)
        let content: [NSView?] = [titleLabel, artistLabel, statusLabel, actions]
        for (i, v) in content.enumerated() { v?.alphaValue = reveal(i, t) }
        hideButton.alphaValue = min(reveal(1, t), CGFloat(hideAlpha))
        picker?.alphaValue = min(reveal(3, t), CGFloat(smooth((t - pickerOpened) / 0.3)))
        let center = NSPoint(x: disc.frame.midX - island.frame.minX, y: disc.frame.midY - island.frame.minY)
        island.setGlow(center: center, radius: discSize * 1.3, alpha: Float(smooth((p - 0.3) / 0.7)))
    }

    /// How far line `i` has faded in: after the island is mostly open, 80ms apart; and out
    /// first when it closes.
    func reveal(_ i: Int, _ t: Double) -> CGFloat {
        var a = 1.0
        if let s = openStart { a = smooth((t - s - 0.5 - 0.08 * Double(i)) / 0.4) }
        if let c = closeStart { a = min(a, 1 - smooth((t - c) / 0.15)) }
        return CGFloat(a)
    }

    // MARK: The flight

    /// Flies the cloud from mid-screen into the notch's left ear, shrinking as it goes, its
    /// colours condensing to ink. No overshoot: it lands, and the island pours out (pourOut).
    func travel() {
        disc.clickable = false
        captionFrom = caption.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; caption.animator().alphaValue = 0 }
        if reduceMotion {
            caption.isHidden = true
            open()
            return
        }
        phase = .traveling
        travelFrom = disc.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        travelStart = now
    }

    func travelStep() {
        let duration = 0.9
        let t = now - travelStart
        let to = miniSpot()
        guard t < duration else {
            caption.isHidden = true
            pourOut()
            return
        }
        let q = CGFloat(smooth(t / duration))
        // A gentle arc: up first, then into the notch's left ear.
        let a = NSPoint(x: travelFrom.midX, y: travelFrom.midY), e = NSPoint(x: to.midX, y: to.midY)
        let ctrl = NSPoint(x: a.x + (e.x - a.x) * 0.25, y: a.y + (e.y - a.y) * 0.85)
        let x = (1 - q) * (1 - q) * a.x + 2 * (1 - q) * q * ctrl.x + q * q * e.x
        let y = (1 - q) * (1 - q) * a.y + 2 * (1 - q) * q * ctrl.y + q * q * e.y
        let s = travelFrom.width + (to.width - travelFrom.width) * q
        let d = NSRect(x: x - s / 2, y: y - s / 2, width: s, height: s)
        // Over the last stretch the notch grows its ears, the hidden island, for the record to
        // land in; from there it opens the way it does when you bring it back.
        let g = CGFloat(smooth((t / duration - 0.55) / 0.45))
        let compact = compactTarget()
        let earsH = notch.height + (compact.height - notch.height) * g
        let ears = NSRect(x: notch.minX + (compact.minX - notch.minX) * g, y: screen.maxY - earsH,
                          width: notch.width + (compact.width - notch.width) * g, height: earsH)
        // The caption fades where it was for its first moment.
        var area = t < 0.2 ? d.union(captionFrom) : d
        if g > 0 { area = area.union(ears) }
        let f = NSRect(x: floor(area.minX), y: floor(area.minY),
                       width: ceil(area.maxX) - floor(area.minX), height: ceil(area.maxY) - floor(area.minY))
        setFrame(f)
        disc.frame = d.offsetBy(dx: -f.minX, dy: -f.minY)
        caption.frame = captionFrom.offsetBy(dx: -f.minX, dy: -f.minY)
        island.isHidden = g <= 0
        if g > 0 {
            island.frame = ears.offsetBy(dx: -f.minX, dy: -f.minY)
            for v in [titleLabel, artistLabel, statusLabel, hideButton] as [NSView] { v.alphaValue = 0 }
            island.setGlow(center: .zero, radius: 1, alpha: 0)
            compactLabel.alphaValue = g
            placeCompactLabel()
        }
    }

    /// The record has landed in the notch's ear: the island pours out of it, the same genie
    /// as bringing it back after hiding.
    func pourOut() {
        phase = .docked
        tucked = false
        disc.clickable = outcome == .none
        island.isHidden = false
        openStart = nil
        startTuck(snapshot())
    }

    /// The island is opening: anything that waited for it happens.
    func land() {
        if let path = pendingPick { pendingPick = nil; showPicker(path) }
        if closeWhenDocked { closeWhenDocked = false; requestClose() }
    }

    // MARK: Playlist picker

    /// Opens the playlist picker inside the island, which grows down to hold it. It doesn't
    /// take the keyboard: the first click on it does, so nothing you type elsewhere ends up in it.
    func showPicker(_ path: String) {
        guard picker == nil else { return }
        func lines(_ p: String) -> [String] {
            ((try? String(contentsOfFile: p, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        let recent = Int(lines(path + ".recent").first ?? "") ?? 0
        let p = PlaylistPicker(names: lines(path), recent: recent, last: lines(path + ".last"))
        p.onDone = { [weak self] chosen in self?.finishPick(chosen, answerTo: path + ".answer") }
        picker = p
        pickerOpened = now
        island.addSubview(p)
        p.alphaValue = 0
    }

    /// Writes the choice for HearItOwnIt.scpt, then folds the picker away; the progress
    /// keeps going.
    func finishPick(_ chosen: [String], answerTo answer: String) {
        guard let p = picker else { return }
        let text = chosen.map { $0 + "\n" }.joined()
        try? text.write(toFile: answer + ".tmp", atomically: false, encoding: .utf8)
        rename(answer + ".tmp", answer)
        picker = nil
        p.removeFromSuperview()
        // Hand the keyboard back to whatever you were using.
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        if closeAfterPick { closeAfterPick = false; requestClose() }
    }

    // MARK: Closing

    /// The input ended (or it's done): close once nothing on screen still needs you.
    func requestClose() {
        if phase == .traveling { closeWhenDocked = true; return }  // arrive first
        if picker != nil { closeAfterPick = true; return }         // wait for the playlist choice
        if holdUntil != nil { return }                             // a result closes on its own
        fadeOut()
    }

    /// The Shortcut was stopped: close right away, even mid-flight. A result already on
    /// screen stays for its moment.
    func abandon() {
        guard outcome == .none else { return }
        picker = nil
        closeAfterPick = false
        closeWhenDocked = false
        fadeOut()
    }

    /// Open, the island folds back into the notch; anywhere else it fades.
    func fadeOut() {
        guard !closing else { return }
        closing = true
        if phase == .docked && !reduceMotion {
            collapsing = true
            closeStart = now
            return
        }
        finishClosing()
    }

    func finishClosing() {
        collapsing = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; self.panel.animator().alphaValue = 0 },
                                             completionHandler: {
            if let path = watchPath {
                for file in [path, path + ".cover.jpg"] { try? FileManager.default.removeItem(atPath: file) }
            }
            NSApp.terminate(nil)
        })
    }
}

let args = CommandLine.arguments
let watchPath: String? = args.firstIndex(of: "--watch").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
let ownerPid: pid_t? = args.firstIndex(of: "--while").flatMap { $0 + 1 < args.count ? pid_t(args[$0 + 1]) : nil }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon, never steals focus
let delegate = HUD()
app.delegate = delegate
app.run()
