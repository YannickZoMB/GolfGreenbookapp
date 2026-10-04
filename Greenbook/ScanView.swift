import ARKit
import RealityKit
import SwiftUI

struct ScanView: View {
    let title: String
    let onCancel: () -> Void
    let onFinish: (ScanCapture) -> Void

    @StateObject private var scan = ScanSession()
    @State private var showOverlay = true

    var body: some View {
        ZStack {
            #if targetEnvironment(simulator)
            Color.black.ignoresSafeArea()
            #else
            ARViewContainer(scan: scan)
                .ignoresSafeArea()
            #endif

            Crosshair(active: scan.aimPoint != nil)

            VStack(spacing: 12) {
                statusBar
                Spacer()
                HStack(alignment: .bottom) {
                    MiniMapView(scan: scan)
                        .frame(width: 150, height: 150)
                    Spacer()
                }
                controls
            }
            .padding()
        }
        .onAppear { scan.start() }
        .onDisappear { scan.pause() }
    }

    private var statusBar: some View {
        VStack(spacing: 4) {
            Text(title).font(.headline)
            if let message = scan.trackingMessage {
                Text(message).font(.headline).foregroundStyle(.yellow)
            }
            Text("Kantenpunkte: \(scan.edgePoints.count) · Erfasst: \(Int(scan.coveredArea)) m²")
                .font(.subheadline.monospacedDigit())
            if let distance = scan.distanceToLastEdgePoint {
                Text(String(format: "Abstand zum letzten Punkt: %.1f m", distance))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(distance > 3.5 ? Color.yellow : Color.white)
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                scan.pause()
                onCancel()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)

            Button {
                scan.removeLastEdgePoint()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .disabled(scan.edgePoints.isEmpty)

            Button {
                showOverlay.toggle()
                scan.setOverlayVisible(showOverlay)
            } label: {
                Image(systemName: showOverlay ? "eye" : "eye.slash")
            }
            .buttonStyle(.bordered)

            Button {
                if scan.addEdgePoint() {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } else {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            } label: {
                Label("Punkt", systemImage: "plus.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)

            Button("Fertig") {
                scan.pause()
                onFinish(scan.makeCapture())
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(scan.edgePoints.count < 3)
        }
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Fadenkreuz in der Bildmitte: zeigt, wohin ein Kantenpunkt gesetzt wird.
private struct Crosshair: View {
    let active: Bool

    var body: some View {
        ZStack {
            Circle().stroke(lineWidth: 2).frame(width: 36, height: 36)
            Rectangle().frame(width: 2, height: 20)
            Rectangle().frame(width: 20, height: 2)
        }
        .foregroundStyle(active ? Color.green : Color.red)
        .shadow(radius: 2)
        .allowsHitTesting(false)
    }
}

#if !targetEnvironment(simulator)
struct ARViewContainer: UIViewRepresentable {
    let scan: ScanSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = scan.session
        view.scene.addAnchor(scan.overlay.anchor)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
#endif

/// Draufsicht während des Scans: grau = bereits erfasst, grün = Kante, blau = eigene Position.
private struct MiniMapView: View {
    @ObservedObject var scan: ScanSession

    var body: some View {
        Canvas { context, size in
            let cell = scan.coverageCellSize
            var minP = scan.cameraPosition - SIMD2(5, 5)
            var maxP = scan.cameraPosition + SIMD2(5, 5)
            for key in scan.coverage {
                let p = SIMD2(Float(key.x) * cell, Float(key.z) * cell)
                minP = simd_min(minP, p)
                maxP = simd_max(maxP, p + SIMD2(cell, cell))
            }
            for e in scan.edgePoints {
                minP = simd_min(minP, SIMD2(e.x, e.z))
                maxP = simd_max(maxP, SIMD2(e.x, e.z))
            }
            let span = maxP - minP
            let scale = CGFloat(min(Float(size.width) / span.x, Float(size.height) / span.y))
            let offset = CGPoint(
                x: (size.width - CGFloat(span.x) * scale) / 2,
                y: (size.height - CGFloat(span.y) * scale) / 2
            )
            func toView(_ p: SIMD2<Float>) -> CGPoint {
                CGPoint(x: offset.x + CGFloat(p.x - minP.x) * scale, y: offset.y + CGFloat(p.y - minP.y) * scale)
            }

            var covered = Path()
            let side = CGFloat(cell) * scale + 0.5
            for key in scan.coverage {
                let origin = toView(SIMD2(Float(key.x) * cell, Float(key.z) * cell))
                covered.addRect(CGRect(origin: origin, size: CGSize(width: side, height: side)))
            }
            context.fill(covered, with: .color(.white.opacity(0.6)))

            let edge2D = scan.edgePoints.map { SIMD2($0.x, $0.z) }
            if edge2D.count >= 3 {
                let curve = EdgeSpline.closedCurve(through: edge2D)
                var path = Path()
                path.addLines(curve.map(toView))
                path.closeSubpath()
                context.stroke(path, with: .color(.green), lineWidth: 2)
            }
            for p in edge2D {
                let c = toView(p)
                context.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.green))
            }

            let me = toView(scan.cameraPosition)
            let ahead = toView(scan.cameraPosition + scan.cameraForward * 2)
            var heading = Path()
            heading.move(to: me)
            heading.addLine(to: ahead)
            context.stroke(heading, with: .color(.blue), lineWidth: 2)
            context.fill(Path(ellipseIn: CGRect(x: me.x - 5, y: me.y - 5, width: 10, height: 10)), with: .color(.blue))
        }
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}
