import ARKit
import Combine
import simd

/// Daten für die Mini-Karte. Eigenes Objekt, damit die Karte nur einmal pro Sekunde neu gezeichnet wird
/// und nicht bei jeder kleinen Änderung des Scan-Bildschirms.
final class MiniMapState: ObservableObject {
    @Published var coverage: [CellKey] = []
    @Published var edgePoints: [SIMD3<Float>] = []
    @Published var cameraPosition = SIMD2<Float>(0, 0)
    @Published var cameraForward = SIMD2<Float>(0, -1)
    var cellSize: Float = 0.25
}

#if !targetEnvironment(simulator)
import RealityKit

/// Führt den AR-Scan: liest LiDAR-Tiefenbilder, rechnet sie in Weltpunkte um und füllt das Höhenraster.
final class ScanSession: NSObject, ObservableObject, ARSessionDelegate {
    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    let session = ARSession()
    /// Grüne Fläche und Kantenpunkte, die im Kamerabild über das Gescannte gelegt werden.
    let overlay = ScanOverlay()
    private let grid = HeightGrid()

    let map = MiniMapState()

    @Published private(set) var edgePoints: [SIMD3<Float>] = []
    @Published private(set) var trackingMessage: String?
    /// Punkt, auf den das Fadenkreuz gerade zeigt (nil, wenn dort keine gültige Messung ist).
    @Published private(set) var aimPoint: SIMD3<Float>?
    @Published private(set) var coveredArea: Float = 0

    /// Waagerechter Abstand vom Zielpunkt zum zuletzt gesetzten Kantenpunkt.
    var distanceToLastEdgePoint: Float? {
        guard let aim = aimPoint, let last = edgePoints.last else { return nil }
        return simd_distance(SIMD2(aim.x, aim.z), SIMD2(last.x, last.z))
    }

    private var lastProcessed: TimeInterval = 0
    private var lastPublished: TimeInterval = 0
    private var lastOverlayUpdate: TimeInterval = 0

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.frameSemantics = [.sceneDepth]
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() {
        session.pause()
    }

    func setOverlayVisible(_ visible: Bool) {
        overlay.isVisible = visible
    }

    /// Setzt einen Kantenpunkt dort, wo das Fadenkreuz hinzeigt.
    @discardableResult
    func addEdgePoint() -> Bool {
        guard let aim = aimPoint else { return false }
        edgePoints.append(aim)
        overlay.updateEdgePoints(edgePoints, grid: grid)
        map.edgePoints = edgePoints
        return true
    }

    func removeLastEdgePoint() {
        _ = edgePoints.popLast()
        overlay.updateEdgePoints(edgePoints, grid: grid)
        map.edgePoints = edgePoints
    }

    func makeCapture() -> ScanCapture {
        ScanCapture(cells: grid.cells, cellSize: grid.cellSize, edgePoints: edgePoints)
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Nur bei Änderung veröffentlichen, sonst würde der Bildschirm 60-mal pro Sekunde neu aufgebaut.
        let message = Self.message(for: frame.camera.trackingState)
        if message != trackingMessage { trackingMessage = message }

        guard case .normal = frame.camera.trackingState,
              let depth = frame.sceneDepth,
              frame.timestamp - lastProcessed > 0.15 else { return }
        lastProcessed = frame.timestamp

        let projector = DepthProjector(frame: frame, depth: depth)
        // Jeder dritte Pixel reicht: Das 256×192-Tiefenbild ist aus deutlich weniger echten
        // Laserpunkten hochgerechnet, dichter abzutasten bringt kaum neue Information.
        projector.forEachPoint(step: 3, maxDepth: 3.5) { point in
            grid.add(point)
        }
        aimPoint = projector.centerPoint()

        if frame.timestamp - lastOverlayUpdate > 0.5 {
            lastOverlayUpdate = frame.timestamp
            let dirty = grid.takeDirtyChunks()
            if !dirty.isEmpty { overlay.updateChunks(dirty, grid: grid) }
        }
        if frame.timestamp - lastPublished > 1.0 {
            lastPublished = frame.timestamp
            let transform = frame.camera.transform
            let position = transform.columns.3
            let forward = -transform.columns.2
            map.cameraPosition = SIMD2(position.x, position.z)
            let flat = SIMD2(forward.x, forward.z)
            if simd_length(flat) > 0.01 { map.cameraForward = simd_normalize(flat) }
            if grid.takeCoverageChanged() {
                map.cellSize = grid.coverageCellSize
                map.coverage = Array(grid.coverage)
                coveredArea = Float(grid.coverage.count) * grid.coverageCellSize * grid.coverageCellSize
            }
        }
    }

    private static func message(for state: ARCamera.TrackingState) -> String? {
        switch state {
        case .normal:
            return nil
        case .notAvailable:
            return "Tracking nicht verfügbar"
        case .limited(let reason):
            switch reason {
            case .initializing: return "Wird gestartet … iPhone langsam bewegen"
            case .excessiveMotion: return "Langsamer bewegen"
            case .insufficientFeatures: return "Zu wenig erkennbar, mehr Boden ins Bild nehmen"
            case .relocalizing: return "Position wird wiedergefunden …"
            @unknown default: return "Tracking eingeschränkt"
            }
        }
    }
}

/// Zeichnet im AR-Bild eine halbtransparente grüne Fläche über alles, was schon gemessen wurde,
/// sowie die Kante als weiße Linie mit kleinen Kugeln an den gesetzten Punkten.
final class ScanOverlay {
    let anchor = AnchorEntity(world: .zero)
    /// Ein 3D-Objekt pro 2-m-Block, damit bei neuen Kacheln nur der betroffene Block neu gebaut wird.
    private var chunkEntities: [CellKey: ModelEntity] = [:]
    private var edgeEntities: [ModelEntity] = []
    private let edgeLine = ModelEntity()

    private let areaMaterial: UnlitMaterial = {
        var material = UnlitMaterial(color: UIColor(red: 0.35, green: 0.95, blue: 0.55, alpha: 1))
        material.blending = .transparent(opacity: 0.28)
        return material
    }()
    private let edgeLineMaterial: UnlitMaterial = {
        var material = UnlitMaterial(color: .white)
        material.blending = .transparent(opacity: 0.9)
        return material
    }()
    private let edgeMaterial = UnlitMaterial(color: .white)
    private let edgeMesh = MeshResource.generateSphere(radius: 0.03)

    init() {
        anchor.addChild(edgeLine)
    }

    var isVisible: Bool {
        get { anchor.isEnabled }
        set { anchor.isEnabled = newValue }
    }

    /// Baut die Fläche der geänderten Blöcke neu. Benachbarte Kacheln teilen sich ihre Eckpunkte,
    /// deren Höhe der Mittelwert der angrenzenden Kacheln ist: So liegt eine durchgehende, weiche
    /// Fläche auf dem Rasen statt einzelner Kästchen.
    func updateChunks(_ chunks: Set<CellKey>, grid: HeightGrid) {
        let size = grid.arCellSize
        let n = grid.arChunkSize
        for chunk in chunks {
            let originX = chunk.x * n
            let originZ = chunk.z * n

            // Höhen der Kacheln im Block plus einem Rand von einer Kachel ringsum.
            var heights: [CellKey: Float] = [:]
            for x in (originX - 1)...(originX + n) {
                for z in (originZ - 1)...(originZ + n) {
                    let key = CellKey(x: x, z: z)
                    if grid.arCells.contains(key), let h = grid.arHeight(key) { heights[key] = h }
                }
            }

            var positions: [SIMD3<Float>] = []
            var indices: [UInt32] = []
            var vertexIndex: [CellKey: UInt32] = [:]
            /// Eckpunkt (x, z) des Rasters; Höhe aus den bis zu vier angrenzenden Kacheln.
            func vertex(_ x: Int32, _ z: Int32) -> UInt32 {
                let key = CellKey(x: x, z: z)
                if let index = vertexIndex[key] { return index }
                var sum: Float = 0
                var count: Float = 0
                for (dx, dz) in [(-1, -1), (0, -1), (-1, 0), (0, 0)] as [(Int32, Int32)] {
                    if let h = heights[CellKey(x: x + dx, z: z + dz)] {
                        sum += h
                        count += 1
                    }
                }
                // 1 cm über dem Boden, damit die Fläche nicht im Gras verschwindet.
                let y = sum / max(count, 1) + 0.01
                let index = UInt32(positions.count)
                positions.append(SIMD3(Float(x) * size, y, Float(z) * size))
                vertexIndex[key] = index
                return index
            }

            for x in originX..<(originX + n) {
                for z in originZ..<(originZ + n) {
                    guard heights[CellKey(x: x, z: z)] != nil else { continue }
                    let a = vertex(x, z)
                    let b = vertex(x, z + 1)
                    let c = vertex(x + 1, z + 1)
                    let d = vertex(x + 1, z)
                    // Gegen den Uhrzeigersinn von oben gesehen: Vorderseite zeigt nach oben zur Kamera.
                    indices.append(contentsOf: [a, b, c, a, c, d])
                }
            }
            guard !positions.isEmpty else { continue }

            var descriptor = MeshDescriptor(name: "coverage")
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.primitives = .triangles(indices)
            guard let mesh = try? MeshResource.generate(from: [descriptor]) else { continue }

            if let entity = chunkEntities[chunk] {
                entity.model?.mesh = mesh
            } else {
                let entity = ModelEntity(mesh: mesh, materials: [areaMaterial])
                anchor.addChild(entity)
                chunkEntities[chunk] = entity
            }
        }
    }

    func updateEdgePoints(_ points: [SIMD3<Float>], grid: HeightGrid) {
        while edgeEntities.count > points.count {
            edgeEntities.removeLast().removeFromParent()
        }
        while edgeEntities.count < points.count {
            let entity = ModelEntity(mesh: edgeMesh, materials: [edgeMaterial])
            anchor.addChild(entity)
            edgeEntities.append(entity)
        }
        for (entity, point) in zip(edgeEntities, points) {
            entity.position = point + SIMD3(0, 0.02, 0)
        }
        updateEdgeLine(points, grid: grid)
    }

    /// Weiße Linie entlang der bisher gesetzten Kante (offen, damit keine Sehne quer übers Grün läuft).
    private func updateEdgeLine(_ points: [SIMD3<Float>], grid: HeightGrid) {
        guard points.count >= 2 else {
            edgeLine.model = nil
            return
        }
        let samplesPerSegment = 8
        var path: [SIMD3<Float>] = []
        let flat = points.map { SIMD2($0.x, $0.z) }
        let curve = points.count >= 3
            ? EdgeSpline.closedCurve(through: flat, samplesPerSegment: samplesPerSegment)
            : flat
        let segments = points.count >= 3 ? points.count - 1 : 1
        let perSegment = points.count >= 3 ? samplesPerSegment : 1
        for k in 0..<(segments * perSegment) {
            let p = curve[k]
            let i = k / perSegment
            let u = Float(k % perSegment) / Float(perSegment)
            let fallback = points[i].y + (points[i + 1].y - points[i].y) * u
            let cell = CellKey(x: Int32(floor(p.x / grid.arCellSize)), z: Int32(floor(p.y / grid.arCellSize)))
            let y = grid.arCells.contains(cell) ? (grid.arHeight(cell) ?? fallback) : fallback
            path.append(SIMD3(p.x, y + 0.015, p.y))
        }
        path.append(points[points.count - 1] + SIMD3(0, 0.015, 0))

        let halfWidth: Float = 0.015
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for (j, p) in path.enumerated() {
            let prev = path[max(j - 1, 0)]
            let next = path[min(j + 1, path.count - 1)]
            var dir = SIMD2(next.x - prev.x, next.z - prev.z)
            if simd_length(dir) < 1e-5 { dir = SIMD2(1, 0) }
            dir = simd_normalize(dir)
            let side = SIMD3(-dir.y, 0, dir.x) * halfWidth
            positions.append(p - side)
            positions.append(p + side)
        }
        for j in 0..<(path.count - 1) {
            let base = UInt32(j * 2)
            for tri in [[base, base + 1, base + 2], [base + 1, base + 3, base + 2]] {
                // Dreieck so drehen, dass die Vorderseite nach oben zeigt.
                let a = positions[Int(tri[0])], b = positions[Int(tri[1])], c = positions[Int(tri[2])]
                if simd_cross(b - a, c - a).y >= 0 {
                    indices.append(contentsOf: tri)
                } else {
                    indices.append(contentsOf: [tri[0], tri[2], tri[1]])
                }
            }
        }
        var descriptor = MeshDescriptor(name: "edge")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return }
        if edgeLine.model == nil {
            edgeLine.model = ModelComponent(mesh: mesh, materials: [edgeLineMaterial])
        } else {
            edgeLine.model?.mesh = mesh
        }
    }
}

/// Rechnet Pixel des LiDAR-Tiefenbilds in Weltkoordinaten um.
private struct DepthProjector {
    let frame: ARFrame
    let depth: ARDepthData

    /// Ruft `body` für jeden gültigen Punkt mit hoher Messsicherheit auf.
    func forEachPoint(step: Int, maxDepth: Float, _ body: (SIMD3<Float>) -> Void) {
        withBuffers { width, height, depthAt, confidenceAt, unproject in
            for v in stride(from: 0, to: height, by: step) {
                for u in stride(from: 0, to: width, by: step) {
                    guard confidenceAt(u, v) >= UInt8(ARConfidenceLevel.high.rawValue) else { continue }
                    let d = depthAt(u, v)
                    guard d > 0.3, d < maxDepth else { continue }
                    body(unproject(Float(u), Float(v), d))
                }
            }
        }
    }

    /// Weltpunkt in der Bildmitte (Fadenkreuz), als Median eines kleinen Fensters.
    func centerPoint() -> SIMD3<Float>? {
        var result: SIMD3<Float>?
        withBuffers { width, height, depthAt, confidenceAt, unproject in
            let cu = width / 2, cv = height / 2
            var samples: [Float] = []
            for v in (cv - 2)...(cv + 2) {
                for u in (cu - 2)...(cu + 2) {
                    guard confidenceAt(u, v) >= UInt8(ARConfidenceLevel.medium.rawValue) else { continue }
                    let d = depthAt(u, v)
                    if d > 0.3 && d < 6 { samples.append(d) }
                }
            }
            guard samples.count >= 5 else { return }
            samples.sort()
            result = unproject(Float(cu), Float(cv), samples[samples.count / 2])
        }
        return result
    }

    private func withBuffers(_ body: (
        _ width: Int,
        _ height: Int,
        _ depthAt: (Int, Int) -> Float,
        _ confidenceAt: (Int, Int) -> UInt8,
        _ unproject: (Float, Float, Float) -> SIMD3<Float>
    ) -> Void) {
        let depthMap = depth.depthMap
        guard let confidenceMap = depth.confidenceMap else { return }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap) else { return }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthRow = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let confidenceRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)
        let confidencePtr = confidenceBase.assumingMemoryBound(to: UInt8.self)

        // Kamera-Intrinsik bezieht sich auf das Farbbild; auf die Auflösung des Tiefenbilds umrechnen.
        let intrinsics = frame.camera.intrinsics
        let imageSize = frame.camera.imageResolution
        let sx = Float(width) / Float(imageSize.width)
        let sy = Float(height) / Float(imageSize.height)
        let fx = intrinsics[0][0] * sx
        let fy = intrinsics[1][1] * sy
        let cx = intrinsics[2][0] * sx
        let cy = intrinsics[2][1] * sy
        let cameraToWorld = frame.camera.transform

        body(
            width,
            height,
            { u, v in depthPtr[v * depthRow + u] },
            { u, v in confidencePtr[v * confidenceRow + u] },
            { u, v, d in
                // Bildkoordinaten (y nach unten, z nach vorn) → ARKit-Kamera (y nach oben, Blick entlang -z).
                let local = SIMD4<Float>((u - cx) * d / fx, -(v - cy) * d / fy, -d, 1)
                let world = cameraToWorld * local
                return SIMD3(world.x, world.y, world.z)
            }
        )
    }
}

#else

/// Platzhalter für den Simulator: dort gibt es weder Kamera noch LiDAR.
final class ScanSession: ObservableObject {
    static var isSupported: Bool { false }

    let map = MiniMapState()
    @Published private(set) var edgePoints: [SIMD3<Float>] = []
    @Published private(set) var trackingMessage: String? = "Im Simulator gibt es keine Kamera"
    @Published private(set) var aimPoint: SIMD3<Float>?
    @Published private(set) var coveredArea: Float = 0

    var distanceToLastEdgePoint: Float? { nil }

    func start() {}
    func pause() {}
    func setOverlayVisible(_ visible: Bool) {}
    @discardableResult
    func addEdgePoint() -> Bool { false }
    func removeLastEdgePoint() {}
    func makeCapture() -> ScanCapture { DemoGreen.makeCapture() }
}

#endif
