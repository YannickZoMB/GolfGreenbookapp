import Foundation
import simd

/// Ausgewertetes Grün: geglättetes Höhenraster innerhalb der Kante, fertig zum Zeichnen.
struct GreenModel {
    let cellSize: Float
    /// Weltkoordinate (X, Z) der linken oberen Ecke des Rasters.
    let origin: SIMD2<Float>
    let cols: Int
    let rows: Int
    /// Höhe pro Zelle in Metern, zeilenweise; NaN = außerhalb oder keine Messung.
    let heights: [Float]
    /// Geschwungene Kante als Polygon in Weltkoordinaten (X, Z).
    let outline: [SIMD2<Float>]
    let edgePoints: [SIMD2<Float>]
    /// Höhen, die dem unteren und oberen Ende der Farbskala entsprechen (2. und 98. Perzentil).
    let lowHeight: Float
    let highHeight: Float
    let area: Float
    /// Anteil der Fläche innerhalb der Kante, der tatsächlich gemessen wurde.
    let measuredFraction: Float

    static func build(from capture: ScanCapture) -> GreenModel? {
        let cs = capture.cellSize
        let edge2D = capture.edgePoints.map { SIMD2($0.x, $0.z) }
        guard edge2D.count >= 3 else { return nil }
        let outline = EdgeSpline.closedCurve(through: edge2D)

        var minP = outline[0], maxP = outline[0]
        for p in outline {
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }
        let originCellX = Int(floor(minP.x / cs)) - 2
        let originCellZ = Int(floor(minP.y / cs)) - 2
        let origin = SIMD2(Float(originCellX) * cs, Float(originCellZ) * cs)
        let cols = Int(ceil((maxP.x - origin.x) / cs)) + 2
        let rows = Int(ceil((maxP.y - origin.y) / cs)) + 2
        guard cols > 0, rows > 0, cols * rows < 4_000_000 else { return nil }

        let inside = insideMask(outline: outline, origin: origin, cellSize: cs, cols: cols, rows: rows)
        let insideCount = inside.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard insideCount > 0 else { return nil }

        // Gemessene Mittelwerte übernehmen.
        var heights = [Float](repeating: .nan, count: cols * rows)
        var measured = 0
        for r in 0..<rows {
            for c in 0..<cols where inside[r * cols + c] {
                let key = CellKey(x: Int32(originCellX + c), z: Int32(originCellZ + r))
                if let cell = capture.cells[key], cell.count >= 2 {
                    heights[r * cols + c] = cell.mean
                    measured += 1
                }
            }
        }
        guard measured > 0 else { return nil }

        fillGaps(&heights, inside: inside, cols: cols, rows: rows, maxPasses: 60)
        // Zweimal über ca. 35 cm mitteln, um Gras- und Sensorrauschen zu glätten.
        for _ in 0..<2 {
            heights = boxBlur(heights, inside: inside, cols: cols, rows: rows, radius: 3)
        }

        let valid = heights.filter { !$0.isNaN }.sorted()
        let low = valid[Int(Float(valid.count - 1) * 0.02)]
        let high = valid[Int(Float(valid.count - 1) * 0.98)]

        return GreenModel(
            cellSize: cs,
            origin: origin,
            cols: cols,
            rows: rows,
            heights: heights,
            outline: outline,
            edgePoints: edge2D,
            lowHeight: low,
            highHeight: high,
            area: Float(insideCount) * cs * cs,
            measuredFraction: Float(measured) / Float(insideCount)
        )
    }

    // MARK: - Schritte

    /// Markiert alle Zellen, deren Mittelpunkt innerhalb der Kante liegt (Scanline-Füllung).
    private static func insideMask(outline: [SIMD2<Float>], origin: SIMD2<Float>, cellSize cs: Float, cols: Int, rows: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: cols * rows)
        let n = outline.count
        for r in 0..<rows {
            let z = origin.y + (Float(r) + 0.5) * cs
            var xs: [Float] = []
            for i in 0..<n {
                let a = outline[i], b = outline[(i + 1) % n]
                if (a.y <= z) != (b.y <= z) {
                    xs.append(a.x + (z - a.y) / (b.y - a.y) * (b.x - a.x))
                }
            }
            xs.sort()
            var i = 0
            while i + 1 < xs.count {
                let c0 = max(0, Int(ceil((xs[i] - origin.x) / cs - 0.5)))
                let c1 = min(cols - 1, Int(floor((xs[i + 1] - origin.x) / cs - 0.5)))
                if c0 <= c1 {
                    for c in c0...c1 { mask[r * cols + c] = true }
                }
                i += 2
            }
        }
        return mask
    }

    /// Füllt kleine Lücken innerhalb der Kante mit dem Mittel der gemessenen Nachbarn.
    private static func fillGaps(_ h: inout [Float], inside: [Bool], cols: Int, rows: Int, maxPasses: Int) {
        for _ in 0..<maxPasses {
            var next = h
            var changed = false
            for r in 0..<rows {
                for c in 0..<cols {
                    let i = r * cols + c
                    guard inside[i], h[i].isNaN else { continue }
                    var sum: Float = 0
                    var count = 0
                    for dr in -1...1 {
                        for dc in -1...1 {
                            let rr = r + dr, cc = c + dc
                            guard rr >= 0, rr < rows, cc >= 0, cc < cols else { continue }
                            let v = h[rr * cols + cc]
                            if !v.isNaN { sum += v; count += 1 }
                        }
                    }
                    if count >= 2 {
                        next[i] = sum / Float(count)
                        changed = true
                    }
                }
            }
            h = next
            if !changed { break }
        }
    }

    /// Mittelwertfilter, der nur gültige Zellen innerhalb der Kante berücksichtigt.
    private static func boxBlur(_ h: [Float], inside: [Bool], cols: Int, rows: Int, radius: Int) -> [Float] {
        // Erst waagerecht, dann senkrecht.
        var tmp = [Float](repeating: .nan, count: h.count)
        for r in 0..<rows {
            for c in 0..<cols where inside[r * cols + c] && !h[r * cols + c].isNaN {
                var sum: Float = 0
                var count = 0
                for cc in max(0, c - radius)...min(cols - 1, c + radius) {
                    let v = h[r * cols + cc]
                    if inside[r * cols + cc] && !v.isNaN { sum += v; count += 1 }
                }
                tmp[r * cols + c] = sum / Float(count)
            }
        }
        var out = [Float](repeating: .nan, count: h.count)
        for r in 0..<rows {
            for c in 0..<cols where !tmp[r * cols + c].isNaN {
                var sum: Float = 0
                var count = 0
                for rr in max(0, r - radius)...min(rows - 1, r + radius) {
                    let v = tmp[rr * cols + c]
                    if !v.isNaN { sum += v; count += 1 }
                }
                out[r * cols + c] = sum / Float(count)
            }
        }
        return out
    }

    // MARK: - Export der Rohdaten

    /// CSV mit den ungeglätteten Messwerten aller Zellen (zur Auswertung der Genauigkeit).
    static func rawCSV(from capture: ScanCapture) -> String {
        var lines = ["x_m;z_m;hoehe_m;messungen"]
        lines.reserveCapacity(capture.cells.count + 1)
        for (key, cell) in capture.cells {
            let x = (Float(key.x) + 0.5) * capture.cellSize
            let z = (Float(key.z) + 0.5) * capture.cellSize
            lines.append(String(format: "%.3f;%.3f;%.4f;%d", x, z, cell.mean, cell.count))
        }
        return lines.joined(separator: "\n")
    }

    static func edgeCSV(from capture: ScanCapture) -> String {
        var lines = ["x_m;y_m;z_m"]
        for p in capture.edgePoints {
            lines.append(String(format: "%.3f;%.4f;%.3f", p.x, p.y, p.z))
        }
        return lines.joined(separator: "\n")
    }
}
