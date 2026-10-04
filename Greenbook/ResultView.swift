import simd
import SwiftUI
import UIKit

struct ResultView: View {
    let capture: ScanCapture
    let onDone: () -> Void

    @State private var model: GreenModel?
    @State private var failed = false
    @State private var exportFiles: [URL] = []

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else if failed {
                    ContentUnavailableView(
                        "Auswertung nicht möglich",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Innerhalb der Kante wurden keine Messpunkte gefunden. Scanne die Innenfläche und setze mindestens drei Kantenpunkte.")
                    )
                } else {
                    ProgressView("Grün wird ausgewertet …")
                }
            }
            .navigationTitle("Ergebnis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Neuer Scan", action: onDone)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !exportFiles.isEmpty {
                        ShareLink(items: exportFiles) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .task {
            let capture = self.capture
            let built = await Task.detached(priority: .userInitiated) {
                GreenModel.build(from: capture)
            }.value
            if let built {
                model = built
                exportFiles = makeExportFiles(built)
            } else {
                failed = true
            }
        }
    }

    private func content(_ model: GreenModel) -> some View {
        VStack(spacing: 16) {
            GreenMapView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                stat("Fläche", String(format: "%.0f m²", model.area))
                stat("Höhenunterschied", String(format: "%.1f cm", (model.highHeight - model.lowHeight) * 100))
                stat("Gemessen", String(format: "%.0f %%", model.measuredFraction * 100))
            }
            .padding(.horizontal)
        }
        .padding(.bottom)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.bold().monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Schreibt Bild und Rohdaten in temporäre Dateien zum Teilen.
    private func makeExportFiles(_ model: GreenModel) -> [URL] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let stamp = formatter.string(from: Date())
        let dir = FileManager.default.temporaryDirectory
        var urls: [URL] = []

        let renderer = ImageRenderer(content:
            GreenMapView(model: model)
                .frame(width: 1000, height: 1250)
                .padding(40)
                .background(Color.white)
                .environment(\.colorScheme, .light)
        )
        renderer.scale = 2
        if let png = renderer.uiImage?.pngData() {
            let url = dir.appendingPathComponent("Gruen-\(stamp).png")
            if (try? png.write(to: url)) != nil { urls.append(url) }
        }

        let raw = dir.appendingPathComponent("Gruen-\(stamp)-messwerte.csv")
        if (try? GreenModel.rawCSV(from: capture).write(to: raw, atomically: true, encoding: .utf8)) != nil { urls.append(raw) }
        let edge = dir.appendingPathComponent("Gruen-\(stamp)-kante.csv")
        if (try? GreenModel.edgeCSV(from: capture).write(to: edge, atomically: true, encoding: .utf8)) != nil { urls.append(edge) }
        return urls
    }
}

/// Draufsicht des Grüns: Höhenfarben, geschwungene Kante, Kantenpunkte, Maßstab und Legende.
struct GreenMapView: View {
    let model: GreenModel

    var body: some View {
        VStack(spacing: 12) {
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            legend
        }
        .padding()
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        var minP = model.outline[0], maxP = model.outline[0]
        for p in model.outline {
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }
        let pad: Float = 0.5
        minP -= SIMD2(pad, pad)
        maxP += SIMD2(pad, pad)
        let span = maxP - minP
        let scale = CGFloat(min(Float(size.width) / span.x, Float(size.height) / span.y))
        let offset = CGPoint(
            x: (size.width - CGFloat(span.x) * scale) / 2,
            y: (size.height - CGFloat(span.y) * scale) / 2
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
            layer.draw(Image(decorative: model.image, scale: 1), in: imageRect)
        }
        context.stroke(outline, with: .color(.black.opacity(0.8)), lineWidth: 2)

        for p in model.edgePoints {
            let c = toView(p)
            context.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.black.opacity(0.6)))
        }

        // Maßstab unten links.
        let meters: Float = span.x > 25 ? 10 : 5
        let barLength = CGFloat(meters) * scale
        let barStart = CGPoint(x: 8, y: size.height - 12)
        var bar = Path()
        bar.move(to: barStart)
        bar.addLine(to: CGPoint(x: barStart.x + barLength, y: barStart.y))
        context.stroke(bar, with: .color(.primary), lineWidth: 3)
        context.draw(
            Text("\(Int(meters)) m").font(.caption.bold()),
            at: CGPoint(x: barStart.x + barLength / 2, y: barStart.y - 10)
        )
    }

    private var legend: some View {
        HStack(spacing: 8) {
            Text("tief").font(.caption)
            LinearGradient(
                stops: [0.0, 0.5, 1.0].map { (t: Double) -> Gradient.Stop in
                    let c = GreenModel.heightColor(Float(t))
                    return Gradient.Stop(color: Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)), location: CGFloat(t))
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
