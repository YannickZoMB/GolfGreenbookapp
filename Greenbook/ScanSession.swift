import ARKit
import Combine
import simd

#if !targetEnvironment(simulator)

/// Führt den AR-Scan: liest LiDAR-Tiefenbilder, rechnet sie in Weltpunkte um und füllt das Höhenraster.
final class ScanSession: NSObject, ObservableObject, ARSessionDelegate {
    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    let session = ARSession()
    private let grid = HeightGrid()

    @Published private(set) var edgePoints: [SIMD3<Float>] = []
    @Published private(set) var coverage: [CellKey] = []
    @Published private(set) var trackingMessage: String?
    @Published private(set) var cameraPosition = SIMD2<Float>(0, 0)
    @Published private(set) var cameraForward = SIMD2<Float>(0, -1)
    /// Punkt, auf den das Fadenkreuz gerade zeigt (nil, wenn dort keine gültige Messung ist).
    @Published private(set) var aimPoint: SIMD3<Float>?
    @Published private(set) var pointCount = 0

    var coverageCellSize: Float { grid.coverageCellSize }
    var coveredArea: Float { Float(coverage.count) * grid.coverageCellSize * grid.coverageCellSize }

    /// Waagerechter Abstand vom Zielpunkt zum zuletzt gesetzten Kantenpunkt.
    var distanceToLastEdgePoint: Float? {
        guard let aim = aimPoint, let last = edgePoints.last else { return nil }
        return simd_distance(SIMD2(aim.x, aim.z), SIMD2(last.x, last.z))
    }

    private var lastProcessed: TimeInterval = 0
    private var lastPublished: TimeInterval = 0

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

    /// Setzt einen Kantenpunkt dort, wo das Fadenkreuz hinzeigt.
    @discardableResult
    func addEdgePoint() -> Bool {
        guard let aim = aimPoint else { return false }
        edgePoints.append(aim)
        return true
    }

    func removeLastEdgePoint() {
        _ = edgePoints.popLast()
    }

    func makeCapture() -> ScanCapture {
        ScanCapture(cells: grid.cells, cellSize: grid.cellSize, edgePoints: edgePoints)
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let transform = frame.camera.transform
        let position = transform.columns.3
        let forward = -transform.columns.2

        switch frame.camera.trackingState {
        case .normal:
            if trackingMessage != nil { trackingMessage = nil }
        case .notAvailable:
            trackingMessage = "Tracking nicht verfügbar"
        case .limited(let reason):
            switch reason {
            case .initializing: trackingMessage = "Wird gestartet … iPhone langsam bewegen"
            case .excessiveMotion: trackingMessage = "Langsamer bewegen"
            case .insufficientFeatures: trackingMessage = "Zu wenig erkennbar, mehr Boden ins Bild nehmen"
            case .relocalizing: trackingMessage = "Position wird wiedergefunden …"
            @unknown default: trackingMessage = "Tracking eingeschränkt"
            }
        }

        guard case .normal = frame.camera.trackingState,
              let depth = frame.sceneDepth,
              frame.timestamp - lastProcessed > 0.15 else { return }
        lastProcessed = frame.timestamp

        let projector = DepthProjector(frame: frame, depth: depth)
        projector.forEachPoint(step: 2, maxDepth: 3.5) { point in
            grid.add(point)
        }
        aimPoint = projector.centerPoint()

        if frame.timestamp - lastPublished > 0.5 {
            lastPublished = frame.timestamp
            cameraPosition = SIMD2(position.x, position.z)
            let flat = SIMD2(forward.x, forward.z)
            if simd_length(flat) > 0.01 { cameraForward = simd_normalize(flat) }
            coverage = Array(grid.coverage)
            pointCount = grid.pointCount
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

    @Published private(set) var edgePoints: [SIMD3<Float>] = []
    @Published private(set) var coverage: [CellKey] = []
    @Published private(set) var trackingMessage: String? = "Im Simulator gibt es keine Kamera"
    @Published private(set) var cameraPosition = SIMD2<Float>(0, 0)
    @Published private(set) var cameraForward = SIMD2<Float>(0, -1)
    @Published private(set) var aimPoint: SIMD3<Float>?
    @Published private(set) var pointCount = 0

    let coverageCellSize: Float = 0.25
    var coveredArea: Float { 0 }
    var distanceToLastEdgePoint: Float? { nil }

    func start() {}
    func pause() {}
    @discardableResult
    func addEdgePoint() -> Bool { false }
    func removeLastEdgePoint() {}
    func makeCapture() -> ScanCapture { DemoGreen.makeCapture() }
}

#endif
