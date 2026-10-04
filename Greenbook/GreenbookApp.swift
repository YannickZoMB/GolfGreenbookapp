import SwiftData
import SwiftUI

@main
struct GreenbookApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .modelContainer(for: [Course.self, Hole.self])
    }
}
