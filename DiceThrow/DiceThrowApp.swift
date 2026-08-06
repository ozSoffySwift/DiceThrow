import SwiftUI
import SwiftData
import FirebaseCore

@main
struct DiceThrowApp: App {
    init() {
        // Skipped when GoogleService-Info.plist is absent — it's gitignored, so a
        // fresh clone without a Firebase config still builds and runs, just with
        // analytics disabled rather than crashing on launch.
        if Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil {
            FirebaseApp.configure()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: ThrowResult.self)
    }
}
