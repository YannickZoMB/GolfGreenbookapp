import Foundation
import SwiftData

/// Ein Golfplatz mit seinen Löchern. Wird mit SwiftData lokal auf dem iPhone gespeichert.
@Model
final class Course {
    var name: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \Hole.course)
    var holes: [Hole] = []

    init(name: String) {
        self.name = name
        self.createdAt = Date()
    }

    var sortedHoles: [Hole] { holes.sorted { $0.number < $1.number } }
    var scannedHoles: [Hole] { sortedHoles.filter(\.isScanned) }
}

/// Ein Loch mit dem gespeicherten Scan seines Grüns.
@Model
final class Hole {
    var number: Int
    var scannedAt: Date?
    /// Rohdaten des Scans (Höhenraster + Kantenpunkte), siehe `ScanCapture.encoded()`.
    @Attribute(.externalStorage) var scanData: Data?
    var course: Course?

    init(number: Int) {
        self.number = number
    }

    var isScanned: Bool { scannedAt != nil }

    var capture: ScanCapture? {
        scanData.flatMap(ScanCapture.init(encoded:))
    }

    func store(_ capture: ScanCapture) {
        scanData = capture.encoded()
        scannedAt = Date()
    }
}

// MARK: - Speicherformat

extension ScanCapture {
    private static let formatVersion: UInt32 = 1

    /// Kompaktes Binärformat: Kopf, Kantenpunkte, dann je Zelle x, z, mittlere Höhe, Anzahl.
    func encoded() -> Data {
        var data = Data()
        data.reserveCapacity(16 + edgePoints.count * 12 + cells.count * 16)
        func put<T>(_ value: T) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        put(Self.formatVersion)
        put(cellSize)
        put(UInt32(edgePoints.count))
        put(UInt32(cells.count))
        for p in edgePoints {
            put(p.x); put(p.y); put(p.z)
        }
        for (key, cell) in cells {
            put(key.x); put(key.z); put(cell.mean); put(cell.count)
        }
        return data
    }

    init?(encoded data: Data) {
        var offset = 0
        func get<T>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
            offset += size
            return value
        }
        guard get(UInt32.self) == Self.formatVersion,
              let cellSize = get(Float.self),
              let edgeCount = get(UInt32.self),
              let cellCount = get(UInt32.self) else { return nil }

        var edgePoints: [SIMD3<Float>] = []
        edgePoints.reserveCapacity(Int(edgeCount))
        for _ in 0..<edgeCount {
            guard let x = get(Float.self), let y = get(Float.self), let z = get(Float.self) else { return nil }
            edgePoints.append(SIMD3(x, y, z))
        }
        var cells: [CellKey: CellAccum] = [:]
        cells.reserveCapacity(Int(cellCount))
        for _ in 0..<cellCount {
            guard let x = get(Int32.self), let z = get(Int32.self),
                  let mean = get(Float.self), let count = get(Int32.self) else { return nil }
            cells[CellKey(x: x, z: z)] = CellAccum(sum: Double(mean) * Double(count), count: count)
        }
        self.init(cells: cells, cellSize: cellSize, edgePoints: edgePoints)
    }
}
