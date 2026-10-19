// Floating progress window for Hear it → Own it and ytmusic.sh.
// Reads commands one per line:
//   LISTEN <text>                              (big orb mid-screen, no ring or text)
//   TITLE <song name>
//   STATUS <text>                              (ring spins, no percentage)
//   PROG <done> <total> <estimate> <speed> <eta>  (ring fills; numbers, or NA)
//   DONE <text>                                (ring closes the circle, closes shortly after)
//   PICK <file>                                (playlist picker under the progress: <file>
//                                               lists playlist names, one per line; the
//                                               choice goes to <file>.answer, one name per
//                                               line, empty = skipped)
//   CLOSE                                      (fades out now)
// Usage:
//   ytprogress              reads stdin; the window closes when stdin ends.
//   ytprogress --watch F    reads lines appended to file F, so several scripts can
//                           take turns writing to one window. Closes on DONE or CLOSE,
//                           if F is deleted, or after a minute with no new lines, and
//                           deletes F when it closes.
//   --while PID             also fades out as soon as process PID ends (the Shortcut's
//                           runner, so stopping the Shortcut removes the window).
// Built by build_hearit_shortcut.py. By hand (universal, macOS 12+, so it also runs on Intel Macs):
//   swiftc -O -target arm64-apple-macos12 ytprogress.swift -o /tmp/ytp-arm64
//   swiftc -O -target x86_64-apple-macos12 ytprogress.swift -o /tmp/ytp-x86_64
//   lipo -create /tmp/ytp-arm64 /tmp/ytp-x86_64 -o ytprogress && codesign -fs - ytprogress
import AppKit

// The orb is a Swift port of a state from thinking-orbs by Jakub Antalik
// (https://github.com/Jakubantalik/thinking-orbs, src/engine), using its tuned
// 64px preset for "working" (orbits).
//
//   MIT License. Copyright (c) 2026 Jakub Antalik
//   Permission is hereby granted, free of charge, to any person obtaining a copy
//   of this software and associated documentation files (the "Software"), to deal
//   in the Software without restriction, including without limitation the rights
//   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//   copies of the Software, and to permit persons to whom the Software is
//   furnished to do so, subject to the following conditions: The above copyright
//   notice and this permission notice shall be included in all copies or
//   substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS",
//   WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.

/// One dot of an orb frame. `white` is ink on paper (0 = darkest); we draw on a
/// dark substrate, so it's mirrored and near dots read bright.
struct Dot { var x, y, z, r, white, a: Double }

enum OrbEngine {
    static func hashD(_ a: Double, _ b: Double) -> Double {
        let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return h - floor(h)
    }

    static func radiusScale(_ size: Double) -> Double { pow(size / 300, 0.6) }

    /// Spin + tilt + orthographic projection.
    static func proj(yaw: Double, tilt: Double, cx: Double, cy: Double, scale: Double)
        -> (Double, Double, Double) -> (Double, Double, Double) {
        let st = sin(tilt), ct = cos(tilt), sy = sin(yaw), cyw = cos(yaw)
        return { x, y, z in
            let x1 = x * cyw + z * sy
            let z1 = -x * sy + z * cyw
            let y1 = y * ct - z1 * st
            let z2 = y * st + z1 * ct
            return (cx + x1 * scale, cy - y1 * scale, z2)
        }
    }

    /// Drop invisible dots, clamp radii, z-sort far to near.
    static func finalize(_ dots: [Dot], rMin: Double = 0.3) -> [Dot] {
        dots.filter { $0.a >= 0.02 }
            .map { var d = $0; d.r = max(rMin, d.r); return d }
            .sorted { $0.z < $1.z }
    }

    // "working" @64: base profile unchanged
    static let orbitsSpeed = 1.885
    static func orbits(size: Double, t: Double) -> [Dot] {
        let orbitN = 12, ghostN = 40, particles = 3
        let ghostR = 0.9, ghostA = 0.5, partR = 1.2, partRDepth = 1.6
        let R = size / 2 * 0.82
        let pt = proj(yaw: t * 0.12, tilt: 0.3, cx: size / 2, cy: size / 2, scale: 1)
        let rs = radiusScale(size)
        var dots: [Dot] = []
        for orb in 0..<orbitN {
            let o = Double(orb)
            let h1 = hashD(o, 1.7), h2 = hashD(o, 5.2), h3 = hashD(o, 8.9)
            let ro = R * (0.45 + 0.52 * h1)
            let th = h1 * 2 * .pi
            let phi = acos(2 * h2 - 1)
            let nx = sin(phi) * cos(th), ny = cos(phi), nz = sin(phi) * sin(th)
            let ul = max(1e-6, (ny * ny + nx * nx).squareRoot())
            let ux = -ny / ul, uy = nx / ul, uz = 0.0
            let vx = ny * uz - nz * uy, vy = nz * ux - nx * uz, vz = nx * uy - ny * ux
            let speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)
            func point(_ a: Double) -> (Double, Double, Double) {
                pt((ux * cos(a) + vx * sin(a)) * ro, (uy * cos(a) + vy * sin(a)) * ro, (uz * cos(a) + vz * sin(a)) * ro)
            }
            for k in 0..<ghostN {  // ghost path
                let (px, py, z) = point(Double(k) / Double(ghostN) * 2 * .pi)
                let depth = (z / ro + 1) / 2
                dots.append(Dot(x: px, y: py, z: z, r: ghostR * rs, white: 0.72, a: ghostA * (0.4 + 0.6 * depth)))
            }
            for m in 0..<particles {  // the particles doing the work
                let (px, py, z) = point(t * speed + Double(m) / Double(particles) * 2 * .pi + h2 * 6)
                let depth = (z / ro + 1) / 2
                dots.append(Dot(x: px, y: py, z: z, r: (partR + partRDepth * depth) * rs, white: 0.3 - 0.22 * depth, a: 1))
            }
        }
        return finalize(dots)
    }
}

/// Dotted orb with a progress ring around it. The ring either spins (indeterminate)
/// or fills clockwise from the top, reaching a full circle at 100%. The orb itself
/// is the same throughout; only the ring and its speed change.
final class Orb: NSView {
    enum Mood { case listening, searching, working, done }

    var mood = Mood.searching
    var fraction: Double = 0          // target; the drawn ring eases toward it
    var ringAlpha: CGFloat = 1 { didSet { needsDisplay = true } }  // 0 while listening, fades in during the flight
    var indeterminate = true { didSet { if !indeterminate && oldValue { shown = 0 } } }
    static let size: CGFloat = 52
    static let sphereSize = 42.0      // orb drawn inside the ring
    private let ringWidth: CGFloat = 3
    private var time: Double = 0
    private var pace: Double = 1      // eases toward the mood's speed so changes aren't jumpy
    private var shown: Double = 0     // ring fraction currently drawn
    private var timer: Timer?

    override var intrinsicContentSize: NSSize { NSSize(width: Orb.size, height: Orb.size) }

    override func viewDidMoveToWindow() {
        guard window != nil, timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        pace += ((mood == .done ? 0.3 : 1) - pace) * 0.05
        time += pace / 60
        shown += (fraction - shown) * 0.15
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Drawn at the 52pt design size and scaled, so the big listening orb looks
        // exactly like the small one, just larger.
        let k = min(bounds.width, bounds.height) / Orb.size
        ctx.scaleBy(x: k, y: k)
        let c = NSPoint(x: Orb.size / 2, y: Orb.size / 2)
        let ringR = Orb.size / 2 - ringWidth / 2

        // Ring track, then the progress arc on top. While listening it's just the orb.
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: ringR, startAngle: 0, endAngle: 360)
        track.lineWidth = ringWidth
        NSColor.white.withAlphaComponent(0.22 * ringAlpha).setStroke()
        track.stroke()

        let arc = NSBezierPath()
        arc.lineWidth = ringWidth
        arc.lineCapStyle = .round
        if indeterminate {
            let start = 90 - (time * 200).truncatingRemainder(dividingBy: 360)
            arc.appendArc(withCenter: c, radius: ringR, startAngle: start, endAngle: start - 80, clockwise: true)
        } else if shown > 0.999 {
            arc.appendArc(withCenter: c, radius: ringR, startAngle: 0, endAngle: 360)
        } else if shown > 0.005 {
            arc.appendArc(withCenter: c, radius: ringR, startAngle: 90, endAngle: 90 - 360 * shown, clockwise: true)
        }
        NSColor.systemPink.withAlphaComponent(ringAlpha).setStroke()
        arc.stroke()

        // Orb. The engine works in canvas coordinates (y down), so flip y here.
        let s = Orb.sphereSize
        let ox = Double(c.x) - s / 2, oy = Double(c.y) + s / 2
        for d in OrbEngine.orbits(size: s, t: time * OrbEngine.orbitsSpeed) {
            // Mirrored ink, lifted so the darkest dots still show with no dark backdrop.
            let g = 0.4 + 0.6 * (1 - min(1, max(0, d.white)))
            ctx.setFillColor(gray: g, alpha: d.a)
            ctx.fillEllipse(in: CGRect(x: ox + d.x - d.r, y: oy - d.y - d.r, width: d.r * 2, height: d.r * 2))
        }
    }
}

/// Borderless panels can't take keyboard focus by default; the picker's search field needs it.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One row of the playlist picker. A click toggles it.
final class PlaylistRow: NSView {
    let name: String
    var selected = false { didSet { update() } }
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let check = NSTextField(labelWithString: "✓")
    private var hovering = false { didSet { update() } }

    init(name: String, title: String? = nil) {
        self.name = name
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.stringValue = title ?? name
        label.font = .systemFont(ofSize: 13)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        check.font = .systemFont(ofSize: 13, weight: .bold)
        check.textColor = .systemPink
        for v in [label, check] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -6),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func update() {
        check.isHidden = !selected
        let fill = selected ? NSColor.systemPink.withAlphaComponent(0.22)
                 : hovering ? NSColor.white.withAlphaComponent(0.08) : .clear
        layer?.backgroundColor = fill.cgColor
    }
}

/// Playlist picker that hangs under the progress row: a search field (which also
/// names new playlists), the playlists with recently used first, and Skip / Add.
/// Click rows to pick any number. Return adds (or creates what you typed), Esc skips.
final class PlaylistPicker: NSVisualEffectView, NSTextFieldDelegate {
    static let height: CGFloat = 266
    var onDone: (([String]) -> Void)?
    let search = NSTextField()
    private let stack = NSStackView()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private var rows: [PlaylistRow] = []
    private let newRow = PlaylistRow(name: "")
    private var chosen: [String] = []   // in the order they were picked

    init(names: [String]) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        search.placeholderString = "Search, or name a new playlist"
        search.font = .systemFont(ofSize: 13)
        search.focusRingType = .none
        search.bezelStyle = .roundedBezel
        search.delegate = self

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        newRow.onClick = { [weak self] in self?.createFromSearch() }
        stack.addArrangedSubview(newRow)
        for name in names {
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

        let skip = NSButton(title: "Skip", target: self, action: #selector(skip))
        skip.keyEquivalent = "\u{1b}"
        addButton.target = self
        addButton.action = #selector(add)
        addButton.keyEquivalent = "\r"

        for v in [search, scroll, skip, addButton, doc, stack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        for v in [search, scroll, skip, addButton] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),

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
        let exists = rows.contains { $0.name.caseInsensitiveCompare(q) == .orderedSame }
        newRow.isHidden = q.isEmpty || exists
        if !newRow.isHidden {
            newRow.subviews.compactMap { $0 as? NSTextField }.first?.stringValue = "+ New playlist “\(q)”"
        }
        updateAdd()
    }

    private func updateAdd() {
        addButton.title = chosen.count > 1 ? "Add to \(chosen.count)" : "Add"
        addButton.isEnabled = !chosen.isEmpty || !newRow.isHidden
    }

    func controlTextDidChange(_ note: Notification) { filter() }

    /// Return in the search field: pick the playlist you typed (or the top match),
    /// else create it as a new one; with nothing typed, add.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            let q = search.stringValue.trimmingCharacters(in: .whitespaces)
            let visible = rows.filter { !$0.isHidden }
            let match = rows.first { $0.name.caseInsensitiveCompare(q) == .orderedSame }
                ?? visible.first
            if q.isEmpty { add() }
            else if let row = match { toggle(row); search.stringValue = ""; filter() }
            else { createFromSearch() }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) { skip(); return true }
        return false
    }

    @objc func add() {
        if !newRow.isHidden { createFromSearch() }
        onDone?(chosen)
    }
    @objc func skip() { onDone?([]) }
}

final class HUD: NSObject, NSApplicationDelegate {
    let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 72),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
    let titleLabel = NSTextField(labelWithString: "YouTube → Music")
    let detailLabel = NSTextField(labelWithString: "Starting…")
    let percentLabel = NSTextField(labelWithString: "")
    let orb = Orb()
    let bytes = ByteCountFormatter()
    let rightMargin: CGFloat = 40
    let topMargin: CGFloat = 16
    let percentWidth: CGFloat = 46
    var percentWidthConstraint: NSLayoutConstraint!
    var finished = false

    // While listening the orb sits big in the middle of the screen with no text. On
    // the first other command it travels to its spot in the top-right corner, and the
    // text fades in beside it.
    enum Phase { case listening, traveling, docked }
    var phase = Phase.docked
    let bigSize: CGFloat = 220
    let height: CGFloat = 72        // docked window height
    let orbInset: CGFloat = 16      // orb's left edge inside the window
    let minTextArea: CGFloat = 30   // room right of the orb even while listening
    var screen = NSRect.zero        // visible frame of the screen we're on
    var travelStart = Date()
    var travelFrom = NSRect.zero    // orb rect (screen coords) when the trip began
    var travelTimer: Timer?
    var closeWhenDocked = false

    // Playlist picker (PICK). The window stays open until it's answered.
    var picker: PlaylistPicker?
    var pendingPick: String?        // PICK that arrived mid-flight; shown on landing
    var closeAfterPick = false
    var pickerSpace: CGFloat { picker == nil ? 0 : PlaylistPicker.height + 10 }

    func applicationDidFinishLaunching(_ note: Notification) {
        bytes.countStyle = .file

        // No background or border: just the orb and text floating over whatever is behind.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false

        let root = NSView(frame: panel.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        panel.contentView = root

        // White text with a soft dark halo stays readable on light and dark backgrounds.
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.lineBreakMode = .byTruncatingTail
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        percentLabel.textColor = .white
        // Long text must never widen the window on its own (it would grow off the
        // right edge). fitWidth() sizes the window instead, growing it to the left.
        for label in [titleLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for v in [orb, titleLabel, detailLabel, percentLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.wantsLayer = true
            v.shadow = halo()
            root.addSubview(v)
        }
        // The orb is placed by hand (place()), since it moves and resizes while traveling.
        orb.translatesAutoresizingMaskIntoConstraints = true
        orb.autoresizingMask = [.minYMargin]  // stays at the top when the picker opens below

        percentWidthConstraint = percentLabel.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            percentLabel.leadingAnchor.constraint(equalTo: orb.trailingAnchor, constant: 10),
            percentLabel.centerYAnchor.constraint(equalTo: orb.centerYAnchor),
            percentWidthConstraint,

            titleLabel.leadingAnchor.constraint(equalTo: percentLabel.trailingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            titleLabel.bottomAnchor.constraint(equalTo: root.topAnchor, constant: height / 2 - 1),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: height / 2 + 2),
        ])

        screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Opened by hearit_listen.sh (the file starts with LISTEN): big orb, mid-screen.
        if let path = watchPath, (try? String(contentsOfFile: path, encoding: .utf8))?.hasPrefix("LISTEN") == true {
            phase = .listening
            orb.ringAlpha = 0
            for label in [titleLabel, detailLabel, percentLabel] { label.alphaValue = 0 }
            place(orbRect: NSRect(x: screen.midX - bigSize / 2, y: screen.midY - bigSize / 2, width: bigSize, height: bigSize),
                  textArea: minTextArea)
        } else {
            place(orbRect: dockedOrbRect(), textArea: panelWidth() - orbInset - Orb.size)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }

        if let pid = ownerPid {
            let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] timer in
                guard kill(pid, 0) != 0 && errno == ESRCH else { return }
                timer.invalidate()
                self?.abandon()
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
            DispatchQueue.main.async { self?.close() }
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

    func halo() -> NSShadow {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.6)
        s.shadowBlurRadius = 4
        s.shadowOffset = .zero
        return s
    }

    func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return }
        let rest = parts.count > 1 ? parts[1] : ""
        // Listening is over (a CLOSE just fades out where it is).
        if phase == .listening && cmd != "LISTEN" && cmd != "CLOSE" { travel() }
        switch cmd {
        case "LISTEN":
            titleLabel.stringValue = "Listening…"
            fitWidth()
            orb.mood = .listening
            orb.indeterminate = true
            detailLabel.stringValue = rest
            setPercent("")
        case "PICK":
            if phase == .docked { showPicker(rest) } else { pendingPick = rest }
        case "CLOSE":
            close()
        case "TITLE":
            titleLabel.stringValue = rest
            fitWidth()
        case "STATUS":
            orb.mood = .searching
            orb.indeterminate = true
            detailLabel.stringValue = rest
            setPercent("")
        case "PROG":
            let f = rest.split(separator: " ").map { Double($0) }
            guard f.count >= 5, let done = f[0] else { return }
            guard let total = f[1] ?? f[2], total > 0 else { return }
            orb.mood = .working
            orb.indeterminate = false
            let frac = min(done / total, 1)
            orb.fraction = frac
            setPercent("\(Int(frac * 100))%")
            var text = "\(bytes.string(fromByteCount: Int64(done))) of \(bytes.string(fromByteCount: Int64(total)))"
            if let speed = f[3], speed > 0 { text += " · \(bytes.string(fromByteCount: Int64(speed)))/s" }
            if let eta = f[4], eta > 0 { text += " · \(Int(eta))s left" }
            detailLabel.stringValue = text
        case "DONE":
            finished = true
            orb.mood = .done
            orb.indeterminate = false
            orb.fraction = 1
            setPercent("✓")
            detailLabel.stringValue = rest
            close()  // don't wait for the pipe to close; any stray process holding it would keep the window up
        default:
            break
        }
    }

    /// Shows the percentage beside the orb, or collapses that slot when there's none.
    func setPercent(_ text: String) {
        percentLabel.stringValue = text
        percentWidthConstraint.constant = text.isEmpty ? 0 : percentWidth
    }

    /// Docked window width: wide enough for the title, cut off with "…" past maxWidth.
    func panelWidth() -> CGFloat {
        let minWidth: CGFloat = 320, maxWidth: CGFloat = 600
        let chrome: CGFloat = 16 + Orb.size + 10 + percentWidth + 4 + 16  // left inset + orb + gap + percent + gap + right inset
        let limit = min(maxWidth, screen.width - 2 * rightMargin)
        return min(max(minWidth, ceil(titleLabel.intrinsicContentSize.width + chrome)), limit)
    }

    /// Where the orb sits when docked: top-right corner, under the menu bar, like a
    /// system notification. Raise rightMargin to move it left.
    func dockedOrbRect() -> NSRect {
        let width = panelWidth()
        // Clamp, so a narrow screen or an odd size can never push it off-screen.
        let x = min(max(screen.minX, screen.maxX - width - rightMargin), screen.maxX - width)
        let y = min(screen.maxY - height - topMargin, screen.maxY - height)
        return NSRect(x: x + orbInset, y: y + (height - Orb.size) / 2, width: Orb.size, height: Orb.size)
    }

    /// Sizes the window around an orb at `orbRect` (screen coordinates), with
    /// `textArea` points to its right for the text.
    func place(orbRect o: NSRect, textArea: CGFloat) {
        let pad = (height - Orb.size) / 2
        panel.setFrame(NSRect(x: o.minX - orbInset, y: o.minY - pad,
                              width: orbInset + o.width + textArea, height: o.height + 2 * pad), display: true)
        orb.frame = NSRect(x: orbInset, y: pad, width: o.width, height: o.height)
    }

    /// Flies the orb from mid-screen to its docked spot: along a curve, shrinking as
    /// it goes, driven by a slightly underdamped spring so it speeds up, glides in and
    /// settles with a small overshoot.
    func travel() {
        phase = .traveling
        travelFrom = orb.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        travelStart = Date()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.travelStep() }
        RunLoop.main.add(t, forMode: .common)
        travelTimer = t
    }

    func travelStep() {
        let duration = 1.9
        let t = Date().timeIntervalSince(travelStart)
        let to = dockedOrbRect()  // follows the title if it changes mid-flight
        let textArea = panelWidth() - orbInset - Orb.size
        guard t < duration else {
            travelTimer?.invalidate()
            travelTimer = nil
            phase = .docked
            orb.ringAlpha = 1
            place(orbRect: to, textArea: textArea)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                for label in [titleLabel, detailLabel, percentLabel] { label.animator().alphaValue = 1 }
            }
            if let path = pendingPick { pendingPick = nil; showPicker(path) }
            if closeWhenDocked { close() }
            return
        }
        // Spring from 0 to 1, starting at rest (damping 0.78, ~1.4s period).
        let w = 2 * Double.pi / 1.4, zeta = 0.78
        let wd = w * (1 - zeta * zeta).squareRoot()
        let p = 1 - exp(-zeta * w * t) * (cos(wd * t) + zeta * w / wd * sin(wd * t))
        // Curved path: rises first, then glides sideways into the corner.
        let a = NSPoint(x: travelFrom.midX, y: travelFrom.midY), b = NSPoint(x: to.midX, y: to.midY)
        let ctrl = NSPoint(x: a.x + (b.x - a.x) * 0.2, y: a.y + (b.y - a.y) * 0.95)
        let q = CGFloat(p)
        let x = (1 - q) * (1 - q) * a.x + 2 * (1 - q) * q * ctrl.x + q * q * b.x
        let y = (1 - q) * (1 - q) * a.y + 2 * (1 - q) * q * ctrl.y + q * q * b.y
        let size = max(Orb.size * 0.9, travelFrom.width + (Orb.size - travelFrom.width) * q)
        let area = minTextArea + (textArea - minTextArea) * min(1, max(0, q))
        place(orbRect: NSRect(x: x - size / 2, y: y - size / 2, width: size, height: size), textArea: area)
        // The ring fades in over the first stretch of the flight.
        orb.ringAlpha = min(1, max(0, CGFloat(t / (duration * 0.6))))
    }

    /// Opens the playlist picker under the progress row, growing the window downward.
    func showPicker(_ path: String) {
        guard picker == nil else { return }
        let names = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let p = PlaylistPicker(names: names)
        p.onDone = { [weak self] chosen in self?.finishPick(chosen, answerTo: path + ".answer") }
        picker = p
        var frame = panel.frame
        frame.origin.y -= pickerSpace
        frame.size.height += pickerSpace
        panel.setFrame(frame, display: true, animate: true)
        p.frame = NSRect(x: orbInset, y: 0, width: frame.width - 2 * orbInset, height: PlaylistPicker.height)
        p.autoresizingMask = [.width, .maxYMargin]
        p.alphaValue = 0
        panel.contentView?.addSubview(p)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
        panel.makeKey()  // so you can type and press Return straight away
        panel.makeFirstResponder(p.search)
    }

    /// Writes the choice for HearItOwnIt.scpt, then folds the picker away; the
    /// progress keeps going.
    func finishPick(_ chosen: [String], answerTo answer: String) {
        guard let p = picker else { return }
        let text = chosen.map { $0 + "\n" }.joined()
        try? text.write(toFile: answer + ".tmp", atomically: false, encoding: .utf8)
        rename(answer + ".tmp", answer)
        let space = pickerSpace
        picker = nil
        // Hand the keyboard back to whatever you were using.
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 }, completionHandler: {
            p.removeFromSuperview()
            var frame = self.panel.frame
            frame.origin.y += space
            frame.size.height -= space
            self.panel.setFrame(frame, display: true, animate: true)
            if self.closeAfterPick { self.closeAfterPick = false; self.close() }
        })
    }

    /// Widens the window to fit the title, keeping its right edge where it is so it
    /// grows to the left.
    func fitWidth() {
        guard phase == .docked else { return }  // listening/traveling size themselves
        let width = panelWidth()
        let screen = self.screen
        var frame = panel.frame
        guard abs(frame.width - width) > 0.5 else { return }
        frame.origin.x = max(screen.minX, frame.maxX - width)
        frame.size.width = width
        panel.setFrame(frame, display: true, animate: panel.alphaValue > 0)
    }

    var closing = false

    /// The Shortcut was stopped: fade out right away, even mid-flight. After DONE the
    /// window is already on its way out, so that's left to finish.
    func abandon() {
        guard !finished || picker != nil else { return }
        picker = nil
        closeAfterPick = false
        travelTimer?.invalidate()
        travelTimer = nil
        phase = .docked
        closeWhenDocked = false
        close()
    }

    func close() {
        if phase == .traveling { closeWhenDocked = true; return }  // land first, then close
        if picker != nil { closeAfterPick = true; return }         // wait for the playlist choice
        guard !closing else { return }  // DONE and end-of-input can both ask to close
        closing = true
        let delay = finished ? 0.8 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self.panel.animator().alphaValue = 0 },
                                                 completionHandler: {
                if let path = watchPath { try? FileManager.default.removeItem(atPath: path) }
                NSApp.terminate(nil)
            })
        }
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
