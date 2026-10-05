import simd
import SwiftUI

/// Draufsicht eines Grüns: Höhenfarben, Höhenlinien, Gefälle-Pfeile, Kante und Maßstab.
struct GreenMapView: View {
    let model: GreenModel
    let layers: GreenbookLayers
    /// Drehung des Grüns in Grad (im Uhrzeigersinn), damit es richtig ausgerichtet ist.
    var rotation: Double = 0

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
    }

    /// Umrechnung Weltkoordinaten (Meter) → Bildpunkte, inklusive Drehung um die Mitte des Grüns.
    private func worldToView(size: CGSize, drawHeight: CGFloat) -> (transform: CGAffineTransform, scale: CGFloat, span: CGFloat) {
        var minP = model.outline[0], maxP = model.outline[0]
        for p in model.outline {
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }
        let center = (minP + maxP) / 2
        let angle = rotation * .pi / 180
        let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
        func rotated(_ p: SIMD2<Float>) -> CGPoint {
            let x = CGFloat(p.x - center.x), y = CGFloat(p.y - center.y)
            return CGPoint(x: x * cosA - y * sinA, y: x * sinA + y * cosA)
        }

        var rMin = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
        var rMax = CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
        for p in model.outline {
            let r = rotated(p)
            rMin = CGPoint(x: min(rMin.x, r.x), y: min(rMin.y, r.y))
            rMax = CGPoint(x: max(rMax.x, r.x), y: max(rMax.y, r.y))
        }
        let pad = max(rMax.x - rMin.x, rMax.y - rMin.y) * 0.04
        rMin = CGPoint(x: rMin.x - pad, y: rMin.y - pad)
        rMax = CGPoint(x: rMax.x + pad, y: rMax.y + pad)
        let spanX = rMax.x - rMin.x, spanY = rMax.y - rMin.y
        let scale = min(size.width / spanX, drawHeight / spanY)
        let offset = CGPoint(x: (size.width - spanX * scale) / 2, y: (drawHeight - spanY * scale) / 2)

        // v = offset + scale · (R · (p − center) − rMin)
        let a = scale * cosA, b = scale * sinA
        let cx = CGFloat(center.x), cz = CGFloat(center.y)
        let tx = offset.x - scale * rMin.x - (a * cx - b * cz)
        let ty = offset.y - scale * rMin.y - (b * cx + a * cz)
        return (CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty), scale, spanX)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        // Unten Platz für den Maßstab lassen.
        let drawHeight = max(size.height - 28, 10)
        let (transform, scale, span) = worldToView(size: size, drawHeight: drawHeight)

        var worldOutline = Path()
        worldOutline.addLines(model.outline.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
        worldOutline.closeSubpath()
        let outline = worldOutline.applying(transform)

        let imageRect = CGRect(
            x: CGFloat(model.origin.x),
            y: CGFloat(model.origin.y),
            width: CGFloat(Float(model.cols) * model.cellSize),
            height: CGFloat(Float(model.rows) * model.cellSize)
        )
        context.drawLayer { layer in
            layer.clip(to: outline)
            layer.concatenate(transform)
            layer.draw(Image(decorative: layers.image, scale: 1), in: imageRect)
        }
        context.drawLayer { layer in
            layer.clip(to: outline)
            layer.stroke(layers.minorContours.applying(transform), with: .color(.black.opacity(0.35)), lineWidth: 0.8)
            layer.stroke(layers.majorContours.applying(transform), with: .color(.black.opacity(0.6)), lineWidth: 1.6)
        }
        context.stroke(outline, with: .color(.black.opacity(0.85)), lineWidth: 2.5)

        drawArrows(in: &context, transform: transform, scale: scale)
        drawScaleBar(in: &context, size: size, scale: scale, span: span)
    }

    private func drawArrows(in context: inout GraphicsContext, transform: CGAffineTransform, scale: CGFloat) {
        let style = layers.style
        let spacing = CGFloat(style.arrowSpacing) * scale
        // Alle Pfeile in zwei Pfade sammeln und mit einem einzigen Aufruf zeichnen.
        var shafts = Path(), heads = Path()
        var labels: [(String, CGPoint)] = []
        for arrow in layers.arrows {
            let strength: CGFloat
            switch style.arrowStyle {
            case .direction: strength = 1
            // Ab 4 % Gefälle volle Länge.
            case .strength: strength = CGFloat(min(max(arrow.percent / 4, 0.25), 1))
            }
            let length = spacing * 0.75 * strength
            let center = CGPoint(x: CGFloat(arrow.position.x), y: CGFloat(arrow.position.y)).applying(transform)
            // Richtung mitdrehen (nur der Drehanteil der Umrechnung, auf Länge 1 gebracht).
            let raw = CGPoint(
                x: transform.a * CGFloat(arrow.downhill.x) + transform.c * CGFloat(arrow.downhill.y),
                y: transform.b * CGFloat(arrow.downhill.x) + transform.d * CGFloat(arrow.downhill.y)
            )
            let norm = max(hypot(raw.x, raw.y), 0.0001)
            let dir = CGPoint(x: raw.x / norm, y: raw.y / norm)
            let tail = CGPoint(x: center.x - dir.x * length / 2, y: center.y - dir.y * length / 2)
            let tip = CGPoint(x: center.x + dir.x * length / 2, y: center.y + dir.y * length / 2)
            let head = min(max(length * 0.35, 4), 12)
            let normal = CGPoint(x: -dir.y, y: dir.x)
            let base = CGPoint(x: tip.x - dir.x * head, y: tip.y - dir.y * head)

            shafts.move(to: tail)
            shafts.addLine(to: base)
            heads.move(to: tip)
            heads.addLine(to: CGPoint(x: base.x + normal.x * head * 0.5, y: base.y + normal.y * head * 0.5))
            heads.addLine(to: CGPoint(x: base.x - normal.x * head * 0.5, y: base.y - normal.y * head * 0.5))
            heads.closeSubpath()

            if style.showPercent {
                labels.append((String(format: "%.1f", arrow.percent), CGPoint(x: tail.x - dir.x * 7, y: tail.y - dir.y * 7)))
            }
        }
        let width: CGFloat = style.arrowStyle == .strength ? 1.8 : 1.6
        context.stroke(shafts, with: .color(.black.opacity(0.8)), lineWidth: width)
        context.fill(heads, with: .color(.black.opacity(0.8)))
        for (text, point) in labels {
            context.draw(Text(text).font(.system(size: 9, weight: .semibold)).foregroundColor(.black), at: point)
        }
    }

    private func drawScaleBar(in context: inout GraphicsContext, size: CGSize, scale: CGFloat, span: CGFloat) {
        // Größte „runde“ Länge, die höchstens ein Drittel der Breite einnimmt.
        let candidates: [CGFloat] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 20]
        let meters = candidates.last { $0 <= span / 3 } ?? candidates[0]
        let barLength = meters * scale
        let y = size.height - 8
        var bar = Path()
        bar.move(to: CGPoint(x: 8, y: y))
        bar.addLine(to: CGPoint(x: 8 + barLength, y: y))
        context.stroke(bar, with: .color(.primary), lineWidth: 3)
        let label = meters < 1 ? "\(Int(meters * 100)) cm" : "\(Int(meters)) m"
        context.draw(Text(label).font(.caption.bold()), at: CGPoint(x: 8 + barLength / 2, y: y - 11))
    }
}

/// Farbleiste mit „tief“ und „hoch“ und dem Höhenunterschied.
struct HeightLegend: View {
    let model: GreenModel
    let coloring: HeightColoring

    var body: some View {
        HStack(spacing: 8) {
            Text("tief").font(.caption)
            LinearGradient(
                stops: [0.0, 0.5, 1.0].map { (t: Double) -> Gradient.Stop in
                    Gradient.Stop(color: coloring.swiftUIColor(Float(t)), location: CGFloat(t))
                },
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 12)
            .clipShape(Capsule())
            Text("hoch").font(.caption)
            Text(String(format: "Δ %.1f cm", (model.highHeight - model.lowHeight) * 100))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
