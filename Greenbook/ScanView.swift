import ARKit
import RealityKit
import SwiftUI

/// Scan-Bildschirm im Stil der Apple-Kamera: oben Schritt-Auswahl, unten ein großer Auslöser.
struct ScanView: View {
    let title: String
    let onCancel: () -> Void
    let onFinish: (ScanCapture) -> Void

    /// Die zwei Schritte eines Scans.
    enum Phase: String, CaseIterable, Identifiable {
        case edge = "Kante"
        case area = "Fläche"
        var id: Self { self }
    }

    @StateObject private var scan = ScanSession()
    @State private var phase: Phase = .edge
    @State private var showOverlay = true

    var body: some View {
        ZStack {
            #if targetEnvironment(simulator)
            Color.black.ignoresSafeArea()
            #else
            ARViewContainer(scan: scan)
                .ignoresSafeArea()
            #endif

            // Leichte Abdunklung oben und unten, damit die Bedienelemente auf hellem Rasen lesbar bleiben.
            VStack {
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 180)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 260)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            Reticle(
                phase: phase,
                active: scan.aimPoint != nil,
                distance: phase == .edge ? scan.distanceToLastEdgePoint : nil
            )

            VStack(spacing: 10) {
                topBar
                guidance
                Spacer()
                HStack(alignment: .bottom) {
                    MiniMapView(map: scan.map)
                        .equatable()
                        .frame(width: 112, height: 112)
                    Spacer()
                }
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .animation(.snappy(duration: 0.25), value: phase)
        .animation(.easeInOut(duration: 0.2), value: scan.trackingMessage)
        .sensoryFeedback(.selection, trigger: phase)
        .onAppear { scan.start() }
        .onDisappear { scan.pause() }
    }

    // MARK: Oben

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                scan.pause()
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Abbrechen")

            Spacer(minLength: 0)
            PhasePicker(phase: $phase)
            Spacer(minLength: 0)

            Button {
                scan.pause()
                onFinish(scan.makeCapture())
            } label: {
                Text("Fertig")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(canFinish ? AnyShapeStyle(Color.green) : AnyShapeStyle(Material.ultraThinMaterial), in: Capsule())
            }
            .disabled(!canFinish)
        }
        .foregroundStyle(.white)
    }

    private var canFinish: Bool { scan.edgePoints.count >= 3 }

    /// Hinweis zum aktuellen Schritt, oder eine Tracking-Warnung, wenn es gerade hakt.
    @ViewBuilder
    private var guidance: some View {
        if let message = scan.trackingMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.yellow, in: Capsule())
                .transition(.move(edge: .top).combined(with: .opacity))
        } else {
            VStack(spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                Text(phase == .edge
                     ? "Fadenkreuz auf die Grünkante, alle 2–3 m einen Punkt"
                     : "In Bahnen übers Grün gehen, iPhone schräg nach unten")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 3)
            .id(phase)
            .transition(.opacity)
        }
    }

    // MARK: Unten

    private var bottomBar: some View {
        HStack(alignment: .center) {
            RoundIconButton(systemImage: "arrow.uturn.backward", label: "Letzten Punkt löschen") {
                scan.removeLastEdgePoint()
            }
            .disabled(scan.edgePoints.isEmpty)
            .opacity(scan.edgePoints.isEmpty ? 0.4 : 1)
            .frame(maxWidth: .infinity)

            centerControl
                .frame(width: 96)

            RoundIconButton(systemImage: showOverlay ? "eye" : "eye.slash", label: "Grüne Fläche ein- oder ausblenden") {
                showOverlay.toggle()
                scan.setOverlayVisible(showOverlay)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var centerControl: some View {
        VStack(spacing: 8) {
            if phase == .edge {
                ShutterButton(enabled: scan.aimPoint != nil) {
                    if scan.addEdgePoint() {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } else {
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                    }
                }
                .transition(.scale.combined(with: .opacity))
                Text(scan.edgePoints.count == 1 ? "1 Punkt" : "\(scan.edgePoints.count) Punkte")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
            } else {
                AreaBadge(area: scan.coveredArea)
                    .transition(.scale.combined(with: .opacity))
                Text("erfasst")
                    .font(.caption.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .animation(.snappy, value: scan.edgePoints.count)
    }
}

/// Umschalter Kante / Fläche als Kapsel mit gleitender Markierung.
private struct PhasePicker: View {
    @Binding var phase: ScanView.Phase
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ScanView.Phase.allCases) { item in
                Button {
                    phase = item
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(phase == item ? Color.black : Color.white)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background {
                            if phase == item {
                                Capsule().fill(.white).matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// Großer runder Auslöser wie in der Kamera-App.
private struct ShutterButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(enabled ? Color.black : Color.white.opacity(0.6))
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(enabled ? Color.white : Color.white.opacity(0.25)))
            }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Kantenpunkt setzen")
    }
}

/// Erfasste Fläche als runde Anzeige an der Stelle des Auslösers.
private struct AreaBadge: View {
    let area: Float

    var body: some View {
        VStack(spacing: 0) {
            Text("\(Int(area))")
                .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text("m²")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(width: 76, height: 76)
        .background(.ultraThinMaterial, in: Circle())
        .overlay(Circle().strokeBorder(Color.green, lineWidth: 3))
        .animation(.snappy, value: Int(area))
    }
}

private struct RoundIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.ultraThinMaterial, in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Zielmarke in der Bildmitte. Bei der Kante: Ring, der grün wird, sobald dort gemessen wird,
/// darunter der Abstand zum letzten Punkt. Bei der Fläche nur ein dezenter Punkt.
private struct Reticle: View {
    let phase: ScanView.Phase
    let active: Bool
    let distance: Float?

    var body: some View {
        VStack(spacing: 10) {
            if phase == .edge {
                ZStack {
                    Circle()
                        .fill(active ? Color.green.opacity(0.18) : Color.clear)
                    Circle()
                        .strokeBorder(
                            active ? Color.green : Color.white.opacity(0.7),
                            style: StrokeStyle(lineWidth: 2.5, dash: active ? [] : [5, 5])
                        )
                    Circle()
                        .fill(active ? Color.green : Color.white)
                        .frame(width: 6, height: 6)
                }
                .frame(width: 48, height: 48)
                .scaleEffect(active ? 1 : 0.85)
                .shadow(color: .black.opacity(0.35), radius: 3)

                if let distance {
                    Text(String(format: "%.1f m", distance))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(distance > 3.5 ? Color.black : Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(distance > 3.5 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Material.ultraThinMaterial), in: Capsule())
                        .contentTransition(.numericText())
                }
            } else {
                Circle()
                    .fill(.white.opacity(0.8))
                    .frame(width: 6, height: 6)
                    .shadow(color: .black.opacity(0.4), radius: 2)
            }
        }
        // Abstandsanzeige soll die Zielmarke nicht aus der Bildmitte schieben.
        .frame(height: 48)
        .offset(y: phase == .edge && distance != nil ? 18 : 0)
        .animation(.snappy(duration: 0.2), value: active)
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

/// Draufsicht während des Scans: grün = bereits erfasst, weiß = Kante, blau = eigene Position und Blickrichtung.
private struct MiniMapView: View, Equatable {
    @ObservedObject var map: MiniMapState

    // Nur neu zeichnen, wenn sich die Kartendaten selbst ändern, nicht bei jeder Änderung des Scan-Bildschirms.
    static func == (lhs: MiniMapView, rhs: MiniMapView) -> Bool { lhs.map === rhs.map }

    var body: some View {
        Canvas { context, size in
            let cell = map.cellSize
            var minP = map.cameraPosition - SIMD2(5, 5)
            var maxP = map.cameraPosition + SIMD2(5, 5)
            for key in map.coverage {
                let p = SIMD2(Float(key.x) * cell, Float(key.z) * cell)
                minP = simd_min(minP, p)
                maxP = simd_max(maxP, p + SIMD2(cell, cell))
            }
            for e in map.edgePoints {
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
            for key in map.coverage {
                let origin = toView(SIMD2(Float(key.x) * cell, Float(key.z) * cell))
                covered.addRect(CGRect(origin: origin, size: CGSize(width: side, height: side)))
            }
            context.fill(covered, with: .color(Color(red: 0.35, green: 0.95, blue: 0.55).opacity(0.55)))

            let edge2D = map.edgePoints.map { SIMD2($0.x, $0.z) }
            if edge2D.count >= 3 {
                let curve = EdgeSpline.closedCurve(through: edge2D)
                var path = Path()
                path.addLines(curve.map(toView))
                path.closeSubpath()
                context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            for p in edge2D {
                let c = toView(p)
                context.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)), with: .color(.white))
            }

            // Eigene Position: blauer Punkt mit Blickkegel wie in Karten.
            let me = toView(map.cameraPosition)
            let forward = map.cameraForward
            let left = SIMD2(-forward.y, forward.x)
            var cone = Path()
            cone.move(to: me)
            cone.addLine(to: toView(map.cameraPosition + forward * 2.5 + left * 1.2))
            cone.addLine(to: toView(map.cameraPosition + forward * 2.5 - left * 1.2))
            cone.closeSubpath()
            context.fill(cone, with: .linearGradient(
                Gradient(colors: [Color.blue.opacity(0.55), Color.blue.opacity(0)]),
                startPoint: me,
                endPoint: toView(map.cameraPosition + forward * 2.5)
            ))
            let dot = CGRect(x: me.x - 5, y: me.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: dot.insetBy(dx: -2, dy: -2)), with: .color(.white))
            context.fill(Path(ellipseIn: dot), with: .color(.blue))
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.15)))
    }
}
