import CoreGraphics
import Foundation
import simd

/// Strecke einer Höhenlinie in Weltkoordinaten (X, Z).
struct ContourSegment {
    let a: SIMD2<Float>
    let b: SIMD2<Float>
    /// Jede fünfte Linie wird kräftiger gezeichnet.
    let major: Bool
}

/// Gefälle-Pfeil: Position, Richtung bergab (Länge 1) und Gefälle in Prozent.
struct SlopeArrow {
    let position: SIMD2<Float>
    let downhill: SIMD2<Float>
    let percent: Float
}

/// Alles, was aus Höhenmodell und Einstellungen fürs Zeichnen berechnet wird.
struct GreenbookLayers {
    let image: CGImage
    let contours: [ContourSegment]
    let arrows: [SlopeArrow]
    let style: GreenbookStyle

    static func compute(model: GreenModel, style: GreenbookStyle) -> GreenbookLayers? {
        guard let image = makeImage(model: model, coloring: style.coloring) else { return nil }
        let contours = style.contoursOn ? makeContours(model: model, intervalCm: style.contourIntervalCm) : []
        let arrows = style.arrowsOn ? makeArrows(model: model, spacing: Float(style.arrowSpacing)) : []
        return GreenbookLayers(image: image, contours: contours, arrows: arrows, style: style)
    }

    // MARK: - Farbbild

    private static func makeImage(model: GreenModel, coloring: HeightColoring) -> CGImage? {
        let cols = model.cols, rows = model.rows
        // Werte ein paar Zellen über die Kante hinaus fortsetzen, damit beim Zuschneiden
        // auf die Kante kein heller Rand entsteht.
        var h = model.heights
        for _ in 0..<4 {
            var next = h
            for r in 0..<rows {
                for c in 0..<cols where h[r * cols + c].isNaN {
                    var sum: Float = 0
                    var count = 0
                    for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let rr = r + dr, cc = c + dc
                        guard rr >= 0, rr < rows, cc >= 0, cc < cols else { continue }
                        let v = h[rr * cols + cc]
                        if !v.isNaN { sum += v; count += 1 }
                    }
                    if count > 0 { next[r * cols + c] = sum / Float(count) }
                }
            }
            h = next
        }

        let range = max(model.highHeight - model.lowHeight, 0.001)
        var pixels = [UInt8](repeating: 0, count: cols * rows * 4)
        for i in 0..<(cols * rows) where !h[i].isNaN {
            let rgb = coloring.color(min(max((h[i] - model.lowHeight) / range, 0), 1))
            pixels[i * 4 + 0] = UInt8(rgb.x * 255)
            pixels[i * 4 + 1] = UInt8(rgb.y * 255)
            pixels[i * 4 + 2] = UInt8(rgb.z * 255)
            pixels[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: cols,
            height: rows,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: cols * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    // MARK: - Höhenlinien (Marching Squares)

    private static func makeContours(model: GreenModel, intervalCm: Double) -> [ContourSegment] {
        let interval = Float(intervalCm / 100)
        guard interval > 0 else { return [] }

        // Auf ca. 10-cm-Zellen vergröbern: glattere Linien und schnellere Berechnung.
        let f = max(1, Int((0.1 / model.cellSize).rounded()))
        let cols = model.cols / f, rows = model.rows / f
        guard cols >= 2, rows >= 2 else { return [] }
        var grid = [Float](repeating: .nan, count: cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                var sum: Float = 0
                var count = 0
                for rr in (r * f)..<(r * f + f) {
                    for cc in (c * f)..<(c * f + f) {
                        let v = model.heights[rr * model.cols + cc]
                        if !v.isNaN { sum += v; count += 1 }
                    }
                }
                if count > 0 { grid[r * cols + c] = sum / Float(count) }
            }
        }
        let step = model.cellSize * Float(f)
        func position(_ c: Float, _ r: Float) -> SIMD2<Float> {
            model.origin + SIMD2((c + 0.5) * step, (r + 0.5) * step)
        }

        var segments: [ContourSegment] = []
        for r in 0..<(rows - 1) {
            for c in 0..<(cols - 1) {
                let tl = grid[r * cols + c]
                let tr = grid[r * cols + c + 1]
                let br = grid[(r + 1) * cols + c + 1]
                let bl = grid[(r + 1) * cols + c]
                if tl.isNaN || tr.isNaN || br.isNaN || bl.isNaN { continue }
                let lo = min(tl, tr, br, bl), hi = max(tl, tr, br, bl)
                var level = Int(ceil(lo / interval))
                while Float(level) * interval <= hi {
                    let l = Float(level) * interval
                    let x = Float(c), y = Float(r)
                    func cross(_ v1: Float, _ v2: Float) -> Float { (l - v1) / (v2 - v1) }
                    // Schnittpunkte auf den vier Kanten der Zelle.
                    let top = { position(x + cross(tl, tr), y) }
                    let right = { position(x + 1, y + cross(tr, br)) }
                    let bottom = { position(x + cross(bl, br), y + 1) }
                    let left = { position(x, y + cross(tl, bl)) }
                    let major = level % 5 == 0
                    var index = 0
                    if tl > l { index |= 8 }
                    if tr > l { index |= 4 }
                    if br > l { index |= 2 }
                    if bl > l { index |= 1 }
                    let centerAbove = (tl + tr + br + bl) / 4 > l
                    var pairs: [(SIMD2<Float>, SIMD2<Float>)] = []
                    switch index {
                    case 1, 14: pairs = [(left(), bottom())]
                    case 2, 13: pairs = [(bottom(), right())]
                    case 3, 12: pairs = [(left(), right())]
                    case 4, 11: pairs = [(top(), right())]
                    case 6, 9: pairs = [(top(), bottom())]
                    case 7, 8: pairs = [(top(), left())]
                    case 5:
                        pairs = centerAbove ? [(top(), left()), (bottom(), right())] : [(top(), right()), (left(), bottom())]
                    case 10:
                        pairs = centerAbove ? [(top(), right()), (left(), bottom())] : [(top(), left()), (bottom(), right())]
                    default: break
                    }
                    for (a, b) in pairs {
                        segments.append(ContourSegment(a: a, b: b, major: major))
                    }
                    level += 1
                }
            }
        }
        return segments
    }

    // MARK: - Gefälle-Pfeile

    private static func makeArrows(model: GreenModel, spacing: Float) -> [SlopeArrow] {
        let cs = model.cellSize
        let cols = model.cols, rows = model.rows
        func height(_ c: Int, _ r: Int) -> Float? {
            guard c >= 0, c < cols, r >= 0, r < rows else { return nil }
            let v = model.heights[r * cols + c]
            return v.isNaN ? nil : v
        }
        // Gefälle über eine Basis von ca. 40 % des Pfeilabstands messen (mind. 10 cm).
        let baseline = max(2, Int(spacing * 0.4 / cs))
        let width = Float(cols) * cs, depth = Float(rows) * cs

        var arrows: [SlopeArrow] = []
        var z = spacing / 2
        while z < depth {
            var x = spacing / 2
            while x < width {
                let c = Int(x / cs), r = Int(z / cs)
                if height(c, r) != nil {
                    var d = baseline
                    var result: SIMD2<Float>?
                    while d >= 1 && result == nil {
                        if let e = height(c + d, r), let w = height(c - d, r),
                           let s = height(c, r + d), let n = height(c, r - d) {
                            let run = 2 * Float(d) * cs
                            result = SIMD2((e - w) / run, (s - n) / run)
                        }
                        d /= 2
                    }
                    if let gradient = result {
                        let slope = simd_length(gradient)
                        if slope > 0.002 {
                            arrows.append(SlopeArrow(
                                position: model.origin + SIMD2(x, z),
                                downhill: -gradient / slope,
                                percent: slope * 100
                            ))
                        }
                    }
                }
                x += spacing
            }
            z += spacing
        }
        return arrows
    }
}
