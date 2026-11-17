import SwiftUI
import AVFoundation

/// Pesu for iPhone: a native shell around the live web app at https://pesu-phrases.vercel.app/.
/// The page recognises this shell (window.KolamShell and the "Pesu-iOS" user-agent token) and
/// switches to its iOS look from the Kolam iOS kit: navigation bar with large titles, tab bar, iOS controls.
/// In Safari or any other browser the same site keeps its Kolam web look.
@main
struct PesuApp: App {
    init() {
        // Sound plays even with the ring/silent switch on, like any media app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
