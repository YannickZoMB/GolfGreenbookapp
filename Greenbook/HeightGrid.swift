import Foundation
import simd

/// Rasterzelle in der waagerechten Ebene (Welt-X / Welt-Z).
struct CellKey: Hashable {
    let x: Int32
    let z: Int32
}

/// Aufsummierte Höhenmessungen einer Zelle.
struct CellAccum {
    var sum: Double = 0
    var count: Int32 = 0

    var mean: Float { Float(sum / Double(max(count, 1))) }
}

/// Sammelt LiDAR-Punkte als Höhenraster.
/// ARKit richtet die Welt-Y-Achse an der Schwerkraft aus, Y ist also die echte Höhe.
///
/// Pro Punkt wird nur eine Zelle des feinen 5-cm-Rasters aktualisiert. Die gröberen Raster für
/// AR-Kacheln (10 cm) und Mini-Karte (25 cm) werden nur ergänzt, wenn eine feine Zelle zum ersten
/// Mal genug Messungen hat. Das hält die Arbeit pro Bild klein, auch auf großen Grüns.
final class HeightGrid {
    /// Kantenlänge einer Zelle des Höhenrasters in Metern.
    let cellSize: Float = 0.05
    /// AR-Kachel = 2 × 2 feine Zellen (10 cm).
    private let arFactor: Int32 = 2
    /// Mini-Karten-Zelle = 5 × 5 feine Zellen (25 cm).
    private let coverageFactor: Int32 = 5
    /// AR-Kacheln werden in Blöcken von 20 × 20 Kacheln (2 m) gezeichnet.
    let arChunkSize: Int32 = 20
    /// Ab so vielen Messungen gilt eine Zelle als erfasst.
    private let minCount: Int32 = 3
    /// Punkte, die so weit vom bisherigen Mittelwert einer Zelle abweichen, werden verworfen (Füße, Fahnenstange …).
    private let outlierThreshold: Double = 0.05

    private(set) var cells: [CellKey: CellAccum] = [:]
    private(set) var arCells: Set<CellKey> = []
    private(set) var coverage: Set<CellKey> = []
    private(set) var pointCount = 0
    private var dirtyChunks: Set<CellKey> = []
    private var coverageChanged = false

    var arCellSize: Float { cellSize * Float(arFactor) }
    var coverageCellSize: Float { cellSize * Float(coverageFactor) }

    init() {
        cells.reserveCapacity(200_000)
    }

    func add(_ p: SIMD3<Float>) {
        let key = CellKey(x: Int32(floor(p.x / cellSize)), z: Int32(floor(p.z / cellSize)))
        var cell = cells[key] ?? CellAccum()
        if cell.count >= 5 {
            let mean = cell.sum / Double(cell.count)
            if abs(Double(p.y) - mean) > outlierThreshold { return }
        }
        cell.sum += Double(p.y)
        cell.count += 1
        cells[key] = cell
        pointCount += 1

        guard cell.count == minCount else { return }
        let ar = CellKey(x: floorDiv(key.x, arFactor), z: floorDiv(key.z, arFactor))
        if arCells.insert(ar).inserted {
            dirtyChunks.insert(CellKey(x: floorDiv(ar.x, arChunkSize), z: floorDiv(ar.z, arChunkSize)))
        }
        if coverage.insert(CellKey(x: floorDiv(key.x, coverageFactor), z: floorDiv(key.z, coverageFactor))).inserted {
            coverageChanged = true
        }
    }

    /// Mittlere Höhe einer AR-Kachel aus ihren erfassten feinen Zellen.
    func arHeight(_ ar: CellKey) -> Float? {
        var sum: Float = 0
        var count: Float = 0
        for dx in 0..<arFactor {
            for dz in 0..<arFactor {
                if let cell = cells[CellKey(x: ar.x * arFactor + dx, z: ar.z * arFactor + dz)], cell.count >= minCount {
                    sum += cell.mean
                    count += 1
                }
            }
        }
        return count > 0 ? sum / count : nil
    }

    /// Blöcke mit neuen AR-Kacheln seit dem letzten Aufruf.
    func takeDirtyChunks() -> Set<CellKey> {
        defer { dirtyChunks.removeAll(keepingCapacity: true) }
        return dirtyChunks
    }

    /// Ob seit dem letzten Aufruf neue Mini-Karten-Zellen dazugekommen sind.
    func takeCoverageChanged() -> Bool {
        defer { coverageChanged = false }
        return coverageChanged
    }

    /// Ganzzahlige Division, die auch bei negativen Zahlen abrundet.
    private func floorDiv(_ a: Int32, _ b: Int32) -> Int32 {
        a >= 0 ? a / b : (a - b + 1) / b
    }
}

/// Alles, was ein abgeschlossener Scan an das Ergebnis weitergibt.
struct ScanCapture {
    let cells: [CellKey: CellAccum]
    let cellSize: Float
    let edgePoints: [SIMD3<Float>]
}
