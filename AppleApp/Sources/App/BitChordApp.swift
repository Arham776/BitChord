import SwiftUI
import BitChordShared

@main
struct BitChordApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Milestone-1 gate (spec §8): both frameworks linked into one SwiftUI app.
/// `GreetingKt.sharedGreeting()` comes from the Kotlin Multiplatform `shared`
/// module — Kotlin/Native exports top-level functions as methods on a
/// `<FileName>Kt` class. `coreVersion()` is the UniFFI-generated binding
/// around the Rust `native-core` staticlib (Generated/NativeCore.swift,
/// produced by scripts/build-native-core.sh).
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("BitChord — scaffold")
                .font(.title2.bold())
            Text(GreetingKt.sharedGreeting())
            Text("native-core v\(coreVersion())")
        }
        .padding(32)
    }
}
