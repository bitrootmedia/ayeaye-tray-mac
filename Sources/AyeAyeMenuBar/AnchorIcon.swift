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

    static func image(size: CGFloat = 18, colour: NSColor? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let scale = size / viewBox
            let transform = NSAffineTransform()
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

    /// The same anchor, in red, for when something critical is waiting.
    ///
    /// Deliberately the same shape rather than a bell or a warning triangle:
    /// the icon is how this app is recognised in a crowded menu bar, and
    /// swapping it for a different symbol means looking for a thing that
    /// isn't there. Colour says "look at me" without changing what you are
    /// looking for — and the count beside it says how much.
    static func alert(size: CGFloat = 18) -> NSImage {
        image(size: size, colour: .systemRed)
    }
}
