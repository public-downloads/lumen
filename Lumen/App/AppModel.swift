import CoreImage
import SwiftUI

enum Tab: Hashable {
    case camera
    case editor
}

/// Owns cross-tab state: which tab is showing, and the handoff of a freshly
/// captured frame from the camera into the editor.
final class AppModel: ObservableObject {
    @Published var tab: Tab = .camera

    /// Set by the camera when the user taps the last-shot thumbnail. The editor
    /// consumes it once and clears it so re-entering the tab doesn't reload.
    @Published var pendingImage: CIImage?

    func openInEditor(_ image: CIImage) {
        pendingImage = image
        tab = .editor
    }

    func consumePendingImage() -> CIImage? {
        defer { pendingImage = nil }
        return pendingImage
    }
}
