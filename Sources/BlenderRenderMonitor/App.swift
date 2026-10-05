import SwiftUI

@main
struct BlenderRenderMonitorApp: App {
    @State private var store = JobStore()

    var body: some Scene {
        Window("Blender Render Monitor", id: "main") {
            ContentView(store: store)
        }
        .defaultSize(width: 560, height: 420)

        MenuBarExtra {
            MenuBarContent(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
    }
}
