import SwiftUI

@main
struct ThreadTidyApp: App {
    var body: some Scene {
        WindowGroup("ThreadTidy") {
            ContentView()
        }
        // .contentMinSize lets the window honor the content's minimum
        // (small while idle, big while showing the side-by-side
        // comparison) but still allows the user to resize freely.
        .windowResizability(.contentMinSize)
    }
}
