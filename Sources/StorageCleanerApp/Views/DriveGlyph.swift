import SwiftUI

/// A monochrome, outline rendition of the app icon — a hard disk with motion
/// arcs — so the start screen and the menu bar share the same visual identity
/// as the Dock icon. Drawn with strokes in the current foreground style, so it
/// tints on the start screen and adapts to the light/dark menu bar on its own.
struct DriveGlyph: View {
    /// Base stroke width, expressed in the glyph's 100×100 design space.
    var lineWidth: CGFloat = 6

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            let shade = GraphicsContext.Shading.foreground
            let lw = lineWidth * s

            // Disk body: a portrait rounded card.
            let card = Path(roundedRect: CGRect(x: 18 * s, y: 10 * s, width: 46 * s, height: 80 * s),
                            cornerRadius: 9 * s)
            ctx.stroke(card, with: shade, style: StrokeStyle(lineWidth: lw, lineJoin: .round))

            // Spinning platter.
            let platter = Path(ellipseIn: CGRect(x: 21 * s, y: 20 * s, width: 40 * s, height: 40 * s))
            ctx.stroke(platter, with: shade, lineWidth: lw)

            // Center hub.
            let hub = Path(ellipseIn: CGRect(x: 38 * s, y: 37 * s, width: 6 * s, height: 6 * s))
            ctx.fill(hub, with: shade)

            // Read arm reaching from the lower-left toward the hub.
            var arm = Path()
            arm.move(to: p(25, 80))
            arm.addLine(to: p(41, 45))
            ctx.stroke(arm, with: shade, style: StrokeStyle(lineWidth: lw, lineCap: .round))

            // Motion arcs sweeping off the right side.
            for r in [33.0, 40.0, 47.0] as [CGFloat] {
                var arc = Path()
                arc.addArc(center: p(41, 40), radius: r * s,
                           startAngle: .degrees(-42), endAngle: .degrees(42), clockwise: false)
                ctx.stroke(arc, with: shade, style: StrokeStyle(lineWidth: lw * 0.85, lineCap: .round))
            }
        }
    }
}
