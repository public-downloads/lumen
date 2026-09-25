import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        TabView(selection: $app.tab) {
            CameraView()
                .tabItem { Label("Camera", systemImage: "camera.aperture") }
                .tag(Tab.camera)

            EditorView()
                .tabItem { Label("Edit", systemImage: "slider.horizontal.below.square.filled.and.square") }
                .tag(Tab.editor)
        }
        .tint(.yellow)
        .ignoresSafeArea(.keyboard)
    }
}
