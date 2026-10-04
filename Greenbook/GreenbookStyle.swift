import simd
import SwiftUI

/// Wie die Höhen eingefärbt werden.
enum HeightColoring: String, CaseIterable, Identifiable {
    case gradient = "Verlauf"
    case twoColor = "Zweifarbig"
    case mono = "Einfarbig"
    case off = "Aus"

    var id: String { rawValue }

    /// Farbe für eine Höhe zwischen 0 (tiefster Punkt) und 1 (höchster Punkt).
    func color(_ t: Float) -> SIMD3<Float> {
        switch self {
        case .gradient:
            let red = SIMD3<Float>(0.85, 0.16, 0.12)
            let yellow = SIMD3<Float>(0.98, 0.84, 0.22)
            let green = SIMD3<Float>(0.12, 0.58, 0.22)
            return t < 0.5 ? simd_mix(red, yellow, SIMD3(repeating: t * 2)) : simd_mix(yellow, green, SIMD3(repeating: (t - 0.5) * 2))
        case .twoColor:
            let red = SIMD3<Float>(0.86, 0.22, 0.18)
            let neutral = SIMD3<Float>(0.95, 0.95, 0.92)
            let green = SIMD3<Float>(0.15, 0.6, 0.25)
            return t < 0.5 ? simd_mix(red, neutral, SIMD3(repeating: t * 2)) : simd_mix(neutral, green, SIMD3(repeating: (t - 0.5) * 2))
        case .mono:
            return simd_mix(SIMD3<Float>(0.83, 0.93, 0.78), SIMD3<Float>(0.1, 0.42, 0.18), SIMD3(repeating: t))
        case .off:
            return SIMD3<Float>(0.62, 0.82, 0.52)
        }
    }

    func swiftUIColor(_ t: Float) -> Color {
        let c = color(t)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}

enum ArrowStyle: String, CaseIterable, Identifiable {
    case direction = "Nur Richtung"
    case strength = "Mit Stärke"

    var id: String { rawValue }
}

/// Alle Einstellungen, wie ein Greenbook dargestellt wird.
struct GreenbookStyle: Equatable {
    var coloring: HeightColoring = .gradient
    var contoursOn = true
    /// Abstand der Höhenlinien in Zentimetern.
    var contourIntervalCm: Double = 2
    var arrowsOn = true
    /// Abstand der Pfeile in Metern.
    var arrowSpacing: Double = 1
    var arrowStyle: ArrowStyle = .strength
    var showPercent = false
}

/// Speichert die Einstellungen dauerhaft, damit die App sie sich merkt.
struct GreenbookStyleStorage: DynamicProperty {
    @AppStorage("style.coloring") var coloring: HeightColoring = .gradient
    @AppStorage("style.contoursOn") var contoursOn = true
    @AppStorage("style.contourIntervalCm") var contourIntervalCm: Double = 2
    @AppStorage("style.arrowsOn") var arrowsOn = true
    @AppStorage("style.arrowSpacing") var arrowSpacing: Double = 1
    @AppStorage("style.arrowStyle") var arrowStyle: ArrowStyle = .strength
    @AppStorage("style.showPercent") var showPercent = false

    var style: GreenbookStyle {
        GreenbookStyle(
            coloring: coloring,
            contoursOn: contoursOn,
            contourIntervalCm: contourIntervalCm,
            arrowsOn: arrowsOn,
            arrowSpacing: arrowSpacing,
            arrowStyle: arrowStyle,
            showPercent: showPercent
        )
    }
}

/// Regler für die Darstellung, als Blatt von unten.
struct GreenbookSettingsView: View {
    private var storage = GreenbookStyleStorage()
    @Environment(\.dismiss) private var dismiss

    init() {}

    var body: some View {
        NavigationStack {
            Form {
                Section("Farben") {
                    Picker("Einfärbung", selection: storage.$coloring) {
                        ForEach(HeightColoring.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LinearGradient(
                        stops: [0.0, 0.5, 1.0].map { (t: Double) -> Gradient.Stop in
                            Gradient.Stop(color: storage.coloring.swiftUIColor(Float(t)), location: CGFloat(t))
                        },
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 14)
                    .clipShape(Capsule())
                }

                Section("Höhenlinien") {
                    Toggle("Höhenlinien anzeigen", isOn: storage.$contoursOn)
                    if storage.contoursOn {
                        Picker("Abstand", selection: storage.$contourIntervalCm) {
                            Text("0,5 cm").tag(0.5)
                            Text("1 cm").tag(1.0)
                            Text("2 cm").tag(2.0)
                            Text("3 cm").tag(3.0)
                            Text("5 cm").tag(5.0)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("Gefälle-Pfeile") {
                    Toggle("Pfeile anzeigen", isOn: storage.$arrowsOn)
                    if storage.arrowsOn {
                        VStack(alignment: .leading) {
                            Text(String(format: "Abstand: %.2g m", storage.arrowSpacing))
                            Slider(value: storage.$arrowSpacing, in: 0.25...3, step: 0.25)
                        }
                        Picker("Stil", selection: storage.$arrowStyle) {
                            ForEach(ArrowStyle.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Toggle("Gefälle in % anzeigen", isOn: storage.$showPercent)
                    }
                }
            }
            .navigationTitle("Darstellung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
