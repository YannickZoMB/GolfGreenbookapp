import SwiftUI

/// Steuert den Ablauf: Start → Scan → Ergebnis.
struct ContentView: View {
    private enum Screen {
        case start
        case scan
        case result(ScanCapture)
    }

    @State private var screen: Screen = .start

    var body: some View {
        switch screen {
        case .start:
            StartView { screen = .scan }
        case .scan:
            ScanView(
                onCancel: { screen = .start },
                onFinish: { capture in screen = .result(capture) }
            )
        case .result(let capture):
            ResultView(capture: capture) { screen = .start }
        }
    }
}

struct StartView: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "flag.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Greenbook")
                .font(.largeTitle.bold())
            Text("Prototyp: Grün scannen und als Höhenkarte anzeigen")
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Label("Lauf die Kante zwischen Grün und Vorgrün ab und setze alle 2–3 m einen Punkt.", systemImage: "1.circle")
                Label("Scanne danach die Innenfläche, indem du in Bahnen über das Grün gehst.", systemImage: "2.circle")
                Label("Halte das iPhone etwa in Hüfthöhe schräg nach unten, ca. 1–3 m vor dir.", systemImage: "3.circle")
            }
            .font(.callout)
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

            Spacer()

            if ScanSession.isSupported {
                Button(action: onStart) {
                    Text("Neuen Scan starten")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            } else {
                Text("Dieses Gerät hat keinen LiDAR-Sensor. Du brauchst ein iPhone Pro ab dem 12 Pro.")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}
