import SwiftUI

@main
struct BlenderRenderMonitorApp: App {
    @State private var store = JobStore()

    var body: some Scene {
        Window("Blender Render Monitor", id: "main") {
            ContentView(store: store)
        }
        .defaultSize(width: 540, height: 360)

        MenuBarExtra {
            MenuBarContent(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
    }
}
