import Foundation
import simd

/// Erfundenes Beispielgrün, damit man die App ohne Scan (z. B. im Simulator) ausprobieren kann:
/// ca. 26 × 20 m, fällt von hinten nach vorn ab, mit einer Kuppe und einer Senke.
enum DemoGreen {
    static func makeCapture() -> ScanCapture {
        let cellSize: Float = 0.05

        var edgePoints: [SIMD3<Float>] = []
        let edgeCount = 22
        for i in 0..<edgeCount {
            let angle = Float(i) / Float(edgeCount) * 2 * .pi
            let wobble = 1 + 0.06 * sin(3 * angle) + 0.03 * cos(5 * angle)
            let x = 13 * cos(angle) * wobble
            let z = 10 * sin(angle) * wobble
            edgePoints.append(SIMD3(x, height(x, z), z))
        }

        var random = SeededRandom(seed: 42)
        var cells: [CellKey: CellAccum] = [:]
        for cz in Int32(-240)..<Int32(240) {
            for cx in Int32(-300)..<Int32(300) {
                let x = (Float(cx) + 0.5) * cellSize
                let z = (Float(cz) + 0.5) * cellSize
                // Gras- und Sensorrauschen von einigen Millimetern.
                let noisy = height(x, z) + random.nextSigned() * 0.004
                cells[CellKey(x: cx, z: cz)] = CellAccum(sum: Double(noisy) * 4, count: 4)
            }
        }
        return ScanCapture(cells: cells, cellSize: cellSize, edgePoints: edgePoints)
    }

    /// Höhe in Metern an der Stelle (x, z); +z ist vorn (unten in der Karte).
    private static func height(_ x: Float, _ z: Float) -> Float {
        let tilt = 0.012 * z + 0.006 * x
        let crown = 0.08 * exp(-(pow(x - 4, 2) + pow(z + 3, 2)) / (2 * 9))
        let hollow = -0.06 * exp(-(pow(x + 5, 2) + pow(z - 4, 2)) / (2 * 6.25))
        return -tilt + crown + hollow
    }
}

/// Einfacher, wiederholbarer Zufallsgenerator, damit das Demo-Grün immer gleich aussieht.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// Zufallszahl zwischen -1 und 1.
    mutating func nextSigned() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 24) * 2 - 1
    }
}
