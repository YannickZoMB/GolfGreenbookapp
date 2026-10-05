import SwiftData
import SwiftUI

/// Navigationsziele der App.
enum Route: Hashable {
    case courses
    case course(Course)
    case hole(Hole)
    case demo
}

/// Startbildschirm mit Logo und den beiden Hauptknöpfen.
struct HomeView: View {
    @State private var path: [Route] = []
    @State private var showNewCourse = false

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Spacer()
                AppLogo()
                    .frame(width: 120, height: 120)
                Text("Greenbook")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .padding(.top, 20)
                Text("Grüns scannen. Breaks lesen.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Spacer()

                VStack(spacing: 12) {
                    NavigationLink(value: Route.courses) {
                        Label("Golfplätze", systemImage: "list.bullet")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button {
                        showNewCourse = true
                    } label: {
                        Label("Neuen Golfplatz anlegen", systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)

                    NavigationLink("Demo-Grün ansehen", value: Route.demo)
                        .font(.subheadline)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .courses:
                    CourseListView { showNewCourse = true }
                case .course(let course):
                    CourseDetailView(course: course)
                case .hole(let hole):
                    HoleView(hole: hole)
                case .demo:
                    DemoView()
                }
            }
            .sheet(isPresented: $showNewCourse) {
                NewCourseView { course in
                    showNewCourse = false
                    path = [.courses, .course(course)]
                }
            }
        }
        .tint(.green)
    }
}

/// Demo-Grün mit eigener, nicht gespeicherter Drehung.
private struct DemoView: View {
    @State private var rotation: Double = 0

    var body: some View {
        GreenbookScreen(title: "Demo-Grün", rotation: $rotation) { DemoGreen.makeCapture() }
            .navigationTitle("Demo-Grün")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Logo: weiße Fahne auf grünem, leicht gewölbtem Grün.
struct AppLogo: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color(red: 0.36, green: 0.78, blue: 0.4), Color(red: 0.08, green: 0.48, blue: 0.22)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Circle()
                .strokeBorder(.white.opacity(0.35), lineWidth: 3)
                .padding(14)
            Image(systemName: "flag.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .padding(34)
        }
        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
    }
}

// MARK: - Golfplätze

struct CourseListView: View {
    let onNewCourse: () -> Void

    @Query(sort: \Course.createdAt, order: .reverse) private var courses: [Course]
    @Environment(\.modelContext) private var context
    @State private var courseToDelete: Course?

    var body: some View {
        List {
            ForEach(courses) { course in
                NavigationLink(value: Route.course(course)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(course.name).font(.headline)
                        Text("\(course.scannedHoles.count) von \(course.holes.count) Grüns gescannt")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Löschen", systemImage: "trash", role: .destructive) { courseToDelete = course }
                }
                .contextMenu {
                    Button("Golfplatz löschen", systemImage: "trash", role: .destructive) { courseToDelete = course }
                }
            }
        }
        .confirmationDialog(
            "„\(courseToDelete?.name ?? "")“ löschen?",
            isPresented: Binding(get: { courseToDelete != nil }, set: { if !$0 { courseToDelete = nil } }),
            titleVisibility: .visible,
            presenting: courseToDelete
        ) { course in
            Button("Golfplatz löschen", role: .destructive) {
                context.delete(course)
                try? context.save()
                courseToDelete = nil
            }
        } message: { course in
            Text("Alle \(course.scannedHoles.count) gescannten Grüns dieses Platzes werden ebenfalls gelöscht. Das lässt sich nicht rückgängig machen.")
        }
        .overlay {
            if courses.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Golfplätze", systemImage: "flag")
                } description: {
                    Text("Lege deinen ersten Platz an und scanne die Grüns.")
                } actions: {
                    Button("Golfplatz anlegen", action: onNewCourse)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Golfplätze")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onNewCourse) { Image(systemName: "plus") }
            }
        }
    }
}

struct NewCourseView: View {
    let onCreated: (Course) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var holeCount = 18
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("z. B. GC Musterstadt", text: $name)
                        .focused($nameFocused)
                }
                Section("Löcher") {
                    Picker("Anzahl Löcher", selection: $holeCount) {
                        Text("9 Loch").tag(9)
                        Text("18 Loch").tag(18)
                        Text("27 Loch").tag(27)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Neuer Golfplatz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Starten", action: create)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { nameFocused = true }
        }
    }

    private func create() {
        let course = Course(name: name.trimmingCharacters(in: .whitespaces))
        context.insert(course)
        for number in 1...holeCount {
            let hole = Hole(number: number)
            context.insert(hole)
            hole.course = course
        }
        try? context.save()
        onCreated(course)
    }
}

// MARK: - Ein Golfplatz mit seinen Löchern

struct CourseDetailView: View {
    let course: Course

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var confirmDelete = false
    @State private var shareItems: ShareItems?
    private var storage = GreenbookStyleStorage()

    init(course: Course) {
        self.course = course
    }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(course.sortedHoles) { hole in
                    NavigationLink(value: Route.hole(hole)) {
                        HoleTile(hole: hole)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(course.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await exportBook() }
                } label: {
                    Label("Buch exportieren", systemImage: "book")
                }
                .disabled(course.scannedHoles.isEmpty || exporting)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Golfplatz löschen", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("„\(course.name)“ löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Golfplatz löschen", role: .destructive, action: deleteCourse)
        } message: {
            Text("Alle \(course.scannedHoles.count) gescannten Grüns dieses Platzes werden ebenfalls gelöscht. Das lässt sich nicht rückgängig machen.")
        }
        .overlay {
            if exporting {
                ProgressView("Buch wird erstellt …")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .sheet(item: $shareItems) { items in
            ShareSheet(items: items.urls)
        }
    }

    /// Erst zurück zur Liste, dann löschen, damit diese Ansicht nicht mehr auf den gelöschten Platz zugreift.
    private func deleteCourse() {
        let course = course
        let context = context
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            context.delete(course)
            try? context.save()
        }
    }

    /// Erstellt eine PNG-Seite pro gescanntem Loch.
    private func exportBook() async {
        exporting = true
        defer { exporting = false }
        let style = storage.style
        var urls: [URL] = []
        for hole in course.scannedHoles {
            guard let data = hole.scanData else { continue }
            let rotation = hole.rotationDegrees
            let computed = await Task.detached(priority: .userInitiated) { () -> (GreenModel, GreenbookLayers)? in
                guard let capture = ScanCapture(encoded: data),
                      let model = GreenModel.build(from: capture),
                      let layers = GreenbookLayers.compute(model: model, style: style) else { return nil }
                return (model, layers)
            }.value
            guard let computed else { continue }
            let (model, layers) = computed
            let title = "Loch \(hole.number)"
            if let png = GreenbookExport.renderPage(model: model, layers: layers, rotation: rotation, title: title, subtitle: course.name),
               let url = GreenbookExport.write(png, name: String(format: "%@ - Loch %02d.png", GreenbookExport.fileName(title: course.name, subtitle: nil), hole.number)) {
                urls.append(url)
            }
        }
        if !urls.isEmpty { shareItems = ShareItems(urls: urls) }
    }
}

private struct HoleTile: View {
    let hole: Hole

    var body: some View {
        VStack(spacing: 6) {
            Text("\(hole.number)")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Label(hole.isScanned ? "Gescannt" : "Offen", systemImage: hole.isScanned ? "checkmark.circle.fill" : "circle.dashed")
                .font(.caption)
                .foregroundStyle(hole.isScanned ? Color.green : Color.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(hole.isScanned ? Color.green.opacity(0.12) : Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(hole.isScanned ? Color.green.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Ein Loch

struct HoleView: View {
    @Bindable var hole: Hole

    @Environment(\.modelContext) private var context
    @State private var scanning = false

    private var title: String { "Loch \(hole.number)" }

    var body: some View {
        Group {
            if hole.isScanned, let data = hole.scanData {
                GreenbookScreen(title: title, subtitle: hole.course?.name, rotation: $hole.rotationDegrees) { ScanCapture(encoded: data) }
                    .id(hole.scannedAt)
            } else {
                ContentUnavailableView {
                    Label("Noch nicht gescannt", systemImage: "viewfinder")
                } description: {
                    Text("Lauf zuerst die Kante des Grüns ab und setze alle 2–3 m einen Punkt. Scanne danach die Fläche in Bahnen.")
                } actions: {
                    Button("Grün scannen") { scanning = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!ScanSession.isSupported)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hole.isScanned {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Neu scannen", systemImage: "arrow.clockwise") { scanning = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            ScanView(
                title: [hole.course?.name, title].compactMap { $0 }.joined(separator: " · "),
                onCancel: { scanning = false },
                onFinish: { capture in
                    hole.store(capture)
                    try? context.save()
                    scanning = false
                }
            )
        }
    }
}
