import SwiftUI
import SwiftData

@main
struct DiceThrowApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: ThrowResult.self)
    }
}
