import AppKit

/// The web app's anchor, drawn rather than shipped as an asset.
///
/// It is lucide's `anchor`, the same icon `org-switcher.tsx` and the landing
/// page use, transcribed from its own path data (lucide-react 1.31.0):
///
///     M12 6v16
///     m19 13 2-1a9 9 0 0 1-18 0l2 1
///     M9 11h6
///     circle cx=12 cy=4 r=2
///
/// Drawn, because there is no anchor in SF Symbols and a PNG in the bundle
/// would need three sizes, two appearances, and would still be a second
/// place the brand's icon lives. This is one function that draws the same
/// shape at any size, and as a **template image** it takes the menu bar's
/// own colour — light mode, dark mode, and the highlighted state while the
/// menu is open — for free.
enum AnchorIcon {
    /// Lucide's canvas is 24×24 with a 2pt stroke; everything below is in
    /// those units and scaled at the end, so the numbers match the SVG and
    /// can be checked against it.
    private static let viewBox: CGFloat = 24

    static func image(
        size: CGFloat = 18, colour: NSColor? = nil, badge: Int = 0, timing: Bool = false
    ) -> NSImage {
        // The badge sits *on* the anchor's top-right corner, the way every
        // other badged icon up there does it.
        //
        // It had a strip of its own to the left for one version, on the
        // argument that a disc small enough to fit inside 18 points is a
        // smudge. In the menu bar it read as a separate glyph that happened
        // to be next to the anchor rather than as a count belonging to it,
        // and it pushed everything to its left along by thirteen points the
        // moment anything arrived. Overlapping costs a corner of the icon,
        // which is the corner with the least drawing in it — and 9 unread
        // is legible at 18 points, which is the thing that had to be looked
        // at rather than reasoned about.
        //
        // **The badge is drawn outside the anchor's own square**, which is
        // where the room to make it readable comes from. The first version
        // of this kept the image 18×18 and fitted the badge inside it; at
        // the size that leaves, the digit is a speck. The menu bar is 22
        // points thick (`NSStatusBar.system.thickness`) and an 18-point icon
        // leaves four of them unused, so the canvas takes them: the anchor
        // stays 18 and the badge overhangs it, up and to the right.
        //
        // The canvas is the same whether or not a number is showing, so the
        // anchor never moves when one arrives — and only "9+" is wider than
        // that, because the pill grows rightwards. Its left edge stays where
        // a one-digit pill's is, which is what keeps it clear of the ring at
        // the top of the anchor whatever it says.
        let canvas = canvasSize(for: badge, size: size)
        let image = NSImage(size: canvas, flipped: true) { _ in
            NSGraphicsContext.saveGraphicsState()
            let scale = size / viewBox
            let transform = NSAffineTransform()
            // Vertically centred in the canvas, and pushed right by the room
            // the timer pip needs off the bottom-left corner — reserved
            // whether or not a timer is running, exactly as the badge's room
            // on the other side is, so the anchor never moves.
            transform.translateX(by: timerOverhang(for: size), yBy: (canvas.height - size) / 2)
            transform.scale(by: scale)
            transform.concat()

            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            // M12 6v16 — the shank.
            path.move(to: NSPoint(x: 12, y: 6))
            path.line(to: NSPoint(x: 12, y: 22))

            // M9 11h6 — the stock, across it.
            path.move(to: NSPoint(x: 9, y: 11))
            path.line(to: NSPoint(x: 15, y: 11))

            // m19 13 2-1 a9 9 0 0 1 -18 0 l2 1 — the arms.
            //
            // The arc is the one part that isn't a literal transcription: SVG
            // states arcs by endpoint and flags, AppKit by centre and angles.
            // Same curve either way — centre (12,12), radius 9, from 0° round
            // to 180°, passing under the icon where the flukes are.
            //
            // `clockwise: false` even though SVG's sweep flag is 1, which
            // means clockwise. Both are right: this context is flipped
            // (y-down), and NSBezierPath reads its flag in the *current*
            // coordinate system, so the sense inverts. Getting it the other
            // way round drew a tidy, entirely wrong ∩ over the top of the
            // icon, which is why this was rendered and looked at rather
            // than reasoned about.
            path.move(to: NSPoint(x: 19, y: 13))
            path.line(to: NSPoint(x: 21, y: 12))
            path.appendArc(
                withCenter: NSPoint(x: 12, y: 12), radius: 9,
                startAngle: 0, endAngle: 180, clockwise: false
            )
            path.line(to: NSPoint(x: 5, y: 13))

            (colour ?? .black).setStroke()
            path.stroke()

            // circle cx=12 cy=4 r=2 — the ring, stroked not filled.
            let ring = NSBezierPath(ovalIn: NSRect(x: 10, y: 2, width: 4, height: 4))
            ring.lineWidth = 2
            (colour ?? .black).setStroke()
            ring.stroke()

            // After the anchor, and in points rather than lucide's 24 units:
            // the badge is drawn over what is already there, and part of
            // what it draws is the removal of it.
            NSGraphicsContext.restoreGraphicsState()
            if badge > 0 {
                drawBadge(badge, colour: colour ?? .black, size: size, canvas: canvas)
            }
            if timing {
                drawTimer(colour: colour ?? .black, size: size, canvas: canvas)
            }

            return true
        }
        // A template image is recoloured by AppKit to suit wherever it is
        // drawn; an explicitly coloured one must not be, or the colour is
        // thrown away. That is the whole difference between the ordinary
        // icon and the alert one below.
        image.isTemplate = colour == nil
        image.accessibilityDescription = "ayeaye"
        return image
    }

    /// The unread count, on the anchor's top-right corner.
    ///
    /// **Three layers, two of them made of nothing.** A gap is cleared out of
    /// the anchor first, then the pill is filled into it, then the digits are
    /// cleared back out of the pill. So the badge is a hole, a shape, and a
    /// hole — no colour anywhere.
    ///
    /// That is what keeps the ordinary icon a *template* image: a template is
    /// a shape, and AppKit fills whatever is opaque with the menu bar's own
    /// colour — so the badge follows light mode, dark mode and the inverted
    /// state while a menu is open, for free, exactly as the anchor already
    /// does. A red disc with white digits would be a second image to keep in
    /// step with every appearance, and would spend the one colour this app
    /// has already given a meaning: red is critical.
    ///
    /// **The cleared gap is what makes it legible.** Without it the pill
    /// merges into the anchor's arm and ring, since in a template image both
    /// are the same single colour — it is the same trick every other badged
    /// icon up there uses, and the reason a badge reads as being *on top of*
    /// something rather than welded to it.
    ///
    /// **Past nine it says 9+.** Three digits in a menu bar is a number
    /// nobody reads as a number, and the difference between eleven unread and
    /// forty is not a difference you act on differently.
    private static func badgeSize(for count: Int, size: CGFloat) -> NSSize {
        // Getting on for two thirds of the anchor. It only fits because
        // most of it hangs off the corner — see `canvasSize`.
        let height = size * 0.58
        return NSSize(width: count > 9 ? height * 1.4 : height, height: height)
    }

    /// The whole image: the anchor's square, plus the room the badge needs
    /// past its top-right corner.
    ///
    /// Constant for every count of one digit, so the anchor sits in exactly
    /// the same place whether or not anything is unread. The height is the
    /// menu bar's own 22 points at the default size, which is what there is
    /// to spend.
    private static func canvasSize(for count: Int, size: CGFloat) -> NSSize {
        let pill = badgeSize(for: count, size: size)
        let overhang = pill.width - pill.height
        return NSSize(
            width: timerOverhang(for: size) + size * 1.22 + overhang, height: size * 7 / 6)
    }

    /// How far the timer pip hangs off the anchor's bottom-left corner.
    ///
    /// **Reserved always, like the badge's room on the other side**, because
    /// an icon that grew when a timer started would shove everything to its
    /// left along by six points several times a day.
    ///
    /// It is this much and not less because of what is *in* the bottom-left
    /// corner: the flukes' arc sweeps diagonally right through it — the
    /// corner looks empty and isn't — so a pip sitting inside the square cuts
    /// the arc in two and leaves the left arm as a crumb floating next to a
    /// clock. There is no position inside the square that avoids it: the
    /// arm's tip is at the *middle* of the left edge, which is where the
    /// badge's mirror image would have to go. Hanging the pip off the corner
    /// instead puts it diagonally clear of the arc's outer edge with about a
    /// third of a point to spare — checked by rendering it at 2× and looking,
    /// which is also how the version that cut the arc was found.
    private static func timerOverhang(for size: CGFloat) -> CGFloat { size / 3 }

    private static func drawBadge(
        _ count: Int, colour: NSColor, size: CGFloat, canvas: NSSize
    ) {
        let text = count > 9 ? "9+" : "\(count)"
        let pill = badgeSize(for: count, size: size)
        // Flush into the canvas's top-right corner. The context is flipped,
        // so y=0 is the top. Because the canvas grew with the pill, the left
        // edge lands in the same place whether it says 1 or 9+ — just clear
        // of the anchor's ring, overlapping only the tip of one arm.
        let rect = NSRect(
            x: canvas.width - pill.width, y: 0, width: pill.width, height: pill.height)
        let radius = pill.height / 2
        let context = NSGraphicsContext.current

        // The gap. A stroke around the pill's own outline rather than a
        // larger filled shape, so the cleared band is the same width the
        // whole way round however wide the pill is.
        context?.compositingOperation = .clear
        let halo = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        halo.lineWidth = max(1, size / 12)
        halo.stroke()
        halo.fill()

        context?.compositingOperation = .sourceOver
        colour.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        // The digits, cut back out. `.clear` rather than a light fill for the
        // same reason the rest of it is: whatever shows through is right in
        // every appearance, and no colour chosen here could be.
        context?.compositingOperation = .clear
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: pill.height * 0.78, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let drawn = NSAttributedString(string: text, attributes: attributes)
        let bounds = drawn.size()
        // The context is flipped, so `draw(at:)` takes the text's top-left —
        // centring is the same arithmetic either way.
        drawn.draw(at: NSPoint(
            x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2))
        context?.compositingOperation = .sourceOver
    }

    /// The running timer, on the anchor's bottom-left corner.
    ///
    /// **The opposite corner from the badge, and a shape rather than a
    /// number.** The two say different kinds of thing: the badge is a count
    /// that goes up and down and is read, and this is a light that is either
    /// on or off and is only glanced at. Putting them in the same corner
    /// would make one of them move when the other appeared; putting a
    /// duration here instead would put a number that changes every minute in
    /// the place on screen with the least room to read one — and the elapsed
    /// time is in the popover, where it can be a sentence.
    ///
    /// Same three layers as the badge, and for the same reason: a gap is
    /// cleared out of the anchor, the disc is filled into it, then the hands
    /// are cleared back out of the disc. No colour anywhere, so the ordinary
    /// icon stays a **template image** and this follows light mode, dark
    /// mode and the inverted state while a menu is open for free — and on the
    /// red alert icon it comes out red with the rest of it.
    ///
    /// **It hangs off the corner rather than sitting in it**, and the reason
    /// is the one thing about this icon that has to be looked at rather than
    /// reasoned about: the bottom-left corner is not empty. The flukes' arc
    /// sweeps diagonally through it — at a quarter of the way across it is
    /// already three quarters of the way down — so a pip *inside* the square
    /// cuts the arc in half and leaves the left arm's hook stranded beside
    /// the clock as a crumb. That version was drawn, rendered at 2× and
    /// thrown away. See `timerOverhang` for the geometry and for why moving
    /// it about inside the square cannot fix it.
    private static func drawTimer(colour: NSColor, size: CGFloat, canvas: NSSize) {
        // Smaller than the badge, which has to hold a legible digit. This
        // only has to be identifiable as a clock — and it was taken down from
        // 0.46 when the pair were looked at together: bigger than this and it
        // stops being a mark on the anchor and starts being the icon.
        let diameter = size * 0.42
        // Flush with the anchor's *bottom* — the canvas's own bottom is a
        // point and a half lower, and the corner this belongs in is the
        // icon's — and flush with the canvas's left, which is `timerOverhang`
        // to the left of the anchor's.
        let bottom = (canvas.height + size) / 2
        let rect = NSRect(x: 0, y: bottom - diameter, width: diameter, height: diameter)
        let context = NSGraphicsContext.current

        // The gap. Stroked and filled like the badge's, so the cleared band
        // is the same width the whole way round.
        context?.compositingOperation = .clear
        let halo = NSBezierPath(ovalIn: rect)
        // Thinner than the badge's, which can afford `size / 12` because it
        // is meant to bite into the ring and the right arm. This one is
        // clearing empty canvas on three sides and has about a third of a
        // point of daylight between it and the arc on the fourth.
        halo.lineWidth = max(0.5, size / 14)
        halo.stroke()
        halo.fill()

        context?.compositingOperation = .sourceOver
        colour.setFill()
        NSBezierPath(ovalIn: rect).fill()

        // The hands, cut back out: one up, one to the right, the way every
        // clock glyph at this size draws them — ten past twelve would be
        // prettier and is indistinguishable from a smudge at seven points.
        // The context is flipped, so "up" is negative y.
        context?.compositingOperation = .clear
        let hands = NSBezierPath()
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        hands.move(to: NSPoint(x: centre.x, y: centre.y - diameter * 0.30))
        hands.line(to: centre)
        hands.line(to: NSPoint(x: centre.x + diameter * 0.23, y: centre.y))
        hands.lineWidth = max(1, diameter * 0.16)
        hands.lineCapStyle = .round
        hands.lineJoinStyle = .round
        hands.stroke()
        context?.compositingOperation = .sourceOver
    }

    /// The same anchor, in red, for when something critical is waiting.
    ///
    /// Deliberately the same shape rather than a bell or a warning triangle:
    /// the icon is how this app is recognised in a crowded menu bar, and
    /// swapping it for a different symbol means looking for a thing that
    /// isn't there. Colour says "look at me" without changing what you are
    /// looking for — and the count beside it says how much.
    static func alert(size: CGFloat = 18, badge: Int = 0, timing: Bool = false) -> NSImage {
        image(size: size, colour: .systemRed, badge: badge, timing: timing)
    }
}
