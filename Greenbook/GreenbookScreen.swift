import SwiftUI
import UIKit

/// Zeigt das Greenbook eines Grüns: Karte, Legende, Kennzahlen, Regler und Teilen.
struct GreenbookScreen: View {
    let title: String
    let subtitle: String?
    /// Lädt die Scan-Daten; läuft im Hintergrund.
    let loadCapture: @Sendable () -> ScanCapture?

    @State private var capture: ScanCapture?
    @State private var model: GreenModel?
    @State private var layers: GreenbookLayers?
    @State private var failed = false
    @State private var showSettings = false
    @State private var shareItems: ShareItems?
    private var storage = GreenbookStyleStorage()

    init(title: String, subtitle: String? = nil, loadCapture: @escaping @Sendable () -> ScanCapture?) {
        self.title = title
        self.subtitle = subtitle
        self.loadCapture = loadCapture
    }

    var body: some View {
        Group {
            if let model, let layers {
                VStack(spacing: 12) {
                    GreenMapView(model: model, layers: layers)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal)
                    HeightLegend(model: model, coloring: layers.style.coloring)
                        .padding(.horizontal)
                    stats(model)
                }
                .padding(.bottom)
            } else if failed {
                ContentUnavailableView(
                    "Auswertung nicht möglich",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Innerhalb der Kante wurden keine Messpunkte gefunden. Scanne die Innenfläche und setze mindestens drei Kantenpunkte.")
                )
            } else {
                ProgressView("Grün wird ausgewertet …")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                Button {
                    share()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(layers == nil)
            }
        }
        .sheet(isPresented: $showSettings) {
            GreenbookSettingsView()
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(item: $shareItems) { items in
            ShareSheet(items: items.urls)
        }
        .task {
            let load = loadCapture
            let result = await Task.detached(priority: .userInitiated) { () -> (ScanCapture, GreenModel)? in
                guard let capture = load(), let model = GreenModel.build(from: capture) else { return nil }
                return (capture, model)
            }.value
            if let result {
                capture = result.0
                model = result.1
            } else {
                failed = true
            }
        }
        .task(id: LayerKey(ready: model != nil, style: storage.style)) {
            guard let model else { return }
            let style = storage.style
            let computed = await Task.detached(priority: .userInitiated) {
                GreenbookLayers.compute(model: model, style: style)
            }.value
            if !Task.isCancelled { layers = computed }
        }
    }

    private struct LayerKey: Equatable {
        let ready: Bool
        let style: GreenbookStyle
    }

    private func stats(_ model: GreenModel) -> some View {
        HStack {
            stat("Fläche", String(format: "%.0f m²", model.area))
            stat("Höhenunterschied", String(format: "%.1f cm", (model.highHeight - model.lowHeight) * 100))
            stat("Gemessen", String(format: "%.0f %%", model.measuredFraction * 100))
        }
        .padding(.horizontal)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.bold().monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func share() {
        guard let model, let layers, let capture else { return }
        var urls: [URL] = []
        let base = GreenbookExport.fileName(title: title, subtitle: subtitle)
        if let png = GreenbookExport.renderPage(model: model, layers: layers, title: title, subtitle: subtitle),
           let url = GreenbookExport.write(png, name: "\(base).png") {
            urls.append(url)
        }
        if let data = GreenModel.rawCSV(from: capture).data(using: .utf8),
           let url = GreenbookExport.write(data, name: "\(base)-messwerte.csv") {
            urls.append(url)
        }
        if let data = GreenModel.edgeCSV(from: capture).data(using: .utf8),
           let url = GreenbookExport.write(data, name: "\(base)-kante.csv") {
            urls.append(url)
        }
        if !urls.isEmpty { shareItems = ShareItems(urls: urls) }
    }
}

struct ShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Das normale iPhone-Teilen-Menü (AirDrop, Fotos, Dateien …).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Erzeugt die Export-Seiten als PNG.
enum GreenbookExport {
    @MainActor
    static func renderPage(model: GreenModel, layers: GreenbookLayers, title: String, subtitle: String?) -> Data? {
        let page = VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 44, weight: .bold))
            if let subtitle {
                Text(subtitle).font(.system(size: 22)).foregroundStyle(.secondary)
            }
            GreenMapView(model: model, layers: layers)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HeightLegend(model: model, coloring: layers.style.coloring)
            Text(pageFooter(model: model, style: layers.style))
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(width: 1000, height: 1400)
        .background(Color.white)
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: page)
        renderer.scale = 2
        return renderer.uiImage?.pngData()
    }

    private static func pageFooter(model: GreenModel, style: GreenbookStyle) -> String {
        var parts = [String(format: "Fläche %.0f m²", model.area)]
        if style.contoursOn {
            parts.append(String(format: "Höhenlinien alle %g cm", style.contourIntervalCm))
        }
        if style.arrowsOn {
            parts.append("Pfeile zeigen bergab")
        }
        return parts.joined(separator: " · ")
    }

    static func fileName(title: String, subtitle: String?) -> String {
        let raw = [subtitle, title].compactMap { $0 }.joined(separator: " - ")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        return String(raw.unicodeScalars.filter { allowed.contains($0) }.map(Character.init))
    }

    static func write(_ data: Data, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
