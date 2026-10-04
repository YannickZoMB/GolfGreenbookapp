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
final class HeightGrid {
    /// Kantenlänge einer Zelle des Höhenrasters in Metern.
    let cellSize: Float = 0.05
    /// Kantenlänge der groben Zellen für die Abdeckungsanzeige.
    let coverageCellSize: Float = 0.25
    /// Punkte, die so weit vom bisherigen Mittelwert einer Zelle abweichen, werden verworfen (Füße, Fahnenstange …).
    private let outlierThreshold: Double = 0.05

    private(set) var cells: [CellKey: CellAccum] = [:]
    private(set) var coverage: Set<CellKey> = []
    private(set) var pointCount = 0

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

        coverage.insert(CellKey(x: Int32(floor(p.x / coverageCellSize)), z: Int32(floor(p.z / coverageCellSize))))
    }
}

/// Alles, was ein abgeschlossener Scan an das Ergebnis weitergibt.
struct ScanCapture {
    let cells: [CellKey: CellAccum]
    let cellSize: Float
    let edgePoints: [SIMD3<Float>]
}
