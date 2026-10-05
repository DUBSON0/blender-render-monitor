import SwiftUI

@main
struct BlenderRenderMonitorApp: App {
    @State private var store = JobStore()

    var body: some Scene {
        Window("Blender Renders", id: "main") {
            ContentView(store: store)
        }
        .defaultSize(width: 520, height: 320)

        MenuBarExtra {
            MenuBarContent(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
    }
}
