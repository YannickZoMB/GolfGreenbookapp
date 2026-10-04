import simd
import SwiftUI

/// Draufsicht eines Grüns: Höhenfarben, Höhenlinien, Gefälle-Pfeile, Kante und Maßstab.
struct GreenMapView: View {
    let model: GreenModel
    let layers: GreenbookLayers

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        var minP = model.outline[0], maxP = model.outline[0]
        for p in model.outline {
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }
        let span = maxP - minP
        let pad = max(span.x, span.y) * 0.04
        minP -= SIMD2(pad, pad)
        maxP += SIMD2(pad, pad)
        let paddedSpan = maxP - minP
        // Unten Platz für den Maßstab lassen.
        let drawHeight = max(size.height - 28, 10)
        let scale = CGFloat(min(Float(size.width) / paddedSpan.x, Float(drawHeight) / paddedSpan.y))
        let offset = CGPoint(
            x: (size.width - CGFloat(paddedSpan.x) * scale) / 2,
            y: (drawHeight - CGFloat(paddedSpan.y) * scale) / 2
        )
        func toView(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: offset.x + CGFloat(p.x - minP.x) * scale, y: offset.y + CGFloat(p.y - minP.y) * scale)
        }

        var outline = Path()
        outline.addLines(model.outline.map(toView))
        outline.closeSubpath()

        let imageOrigin = toView(model.origin)
        let imageRect = CGRect(
            x: imageOrigin.x,
            y: imageOrigin.y,
            width: CGFloat(Float(model.cols) * model.cellSize) * scale,
            height: CGFloat(Float(model.rows) * model.cellSize) * scale
        )

        context.drawLayer { layer in
            layer.clip(to: outline)
            layer.draw(Image(decorative: layers.image, scale: 1), in: imageRect)

            if !layers.contours.isEmpty {
                var minor = Path(), major = Path()
                for segment in layers.contours {
                    if segment.major {
                        major.move(to: toView(segment.a))
                        major.addLine(to: toView(segment.b))
                    } else {
                        minor.move(to: toView(segment.a))
                        minor.addLine(to: toView(segment.b))
                    }
                }
                layer.stroke(minor, with: .color(.black.opacity(0.35)), lineWidth: 0.8)
                layer.stroke(major, with: .color(.black.opacity(0.6)), lineWidth: 1.6)
            }
        }
        context.stroke(outline, with: .color(.black.opacity(0.85)), lineWidth: 2.5)

        drawArrows(in: &context, scale: scale, toView: toView)
        drawScaleBar(in: &context, size: size, scale: scale, span: paddedSpan.x)
    }

    private func drawArrows(in context: inout GraphicsContext, scale: CGFloat, toView: (SIMD2<Float>) -> CGPoint) {
        let style = layers.style
        let spacing = CGFloat(style.arrowSpacing) * scale
        for arrow in layers.arrows {
            let strength: CGFloat
            switch style.arrowStyle {
            case .direction: strength = 1
            // Ab 4 % Gefälle volle Länge.
            case .strength: strength = CGFloat(min(max(arrow.percent / 4, 0.25), 1))
            }
            let length = spacing * 0.75 * strength
            let center = toView(arrow.position)
            let dir = CGPoint(x: CGFloat(arrow.downhill.x), y: CGFloat(arrow.downhill.y))
            let tail = CGPoint(x: center.x - dir.x * length / 2, y: center.y - dir.y * length / 2)
            let tip = CGPoint(x: center.x + dir.x * length / 2, y: center.y + dir.y * length / 2)
            let head = min(max(length * 0.35, 4), 12)
            let normal = CGPoint(x: -dir.y, y: dir.x)
            let base = CGPoint(x: tip.x - dir.x * head, y: tip.y - dir.y * head)

            var shaft = Path()
            shaft.move(to: tail)
            shaft.addLine(to: base)
            var tipShape = Path()
            tipShape.move(to: tip)
            tipShape.addLine(to: CGPoint(x: base.x + normal.x * head * 0.5, y: base.y + normal.y * head * 0.5))
            tipShape.addLine(to: CGPoint(x: base.x - normal.x * head * 0.5, y: base.y - normal.y * head * 0.5))
            tipShape.closeSubpath()

            let width = style.arrowStyle == .strength ? 1 + 1.5 * strength : 1.6
            context.stroke(shaft, with: .color(.black.opacity(0.8)), lineWidth: width)
            context.fill(tipShape, with: .color(.black.opacity(0.8)))

            if style.showPercent {
                context.draw(
                    Text(String(format: "%.1f", arrow.percent)).font(.system(size: 9, weight: .semibold)).foregroundColor(.black),
                    at: CGPoint(x: tail.x - dir.x * 7, y: tail.y - dir.y * 7)
                )
            }
        }
    }

    private func drawScaleBar(in context: inout GraphicsContext, size: CGSize, scale: CGFloat, span: Float) {
        // Größte „runde“ Länge, die höchstens ein Drittel der Breite einnimmt.
        let candidates: [Float] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 20]
        let meters = candidates.last { $0 <= span / 3 } ?? candidates[0]
        let barLength = CGFloat(meters) * scale
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
