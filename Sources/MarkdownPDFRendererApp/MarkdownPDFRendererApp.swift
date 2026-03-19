import SwiftUI

@main
struct MarkdownPDFRendererApp: App {
    var body: some Scene {
        WindowGroup("Markdown PDF Renderer") {
            ContentView()
                .frame(minWidth: 980, minHeight: 720)
        }
        .windowResizability(.contentSize)
    }
}
