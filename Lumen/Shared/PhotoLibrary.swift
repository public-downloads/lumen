import Photos

enum PhotoLibraryError: LocalizedError {
    case denied

    var errorDescription: String? {
        switch self {
        case .denied: return "Lumen isn't allowed to add photos. Enable it in Settings › Lumen › Photos."
        }
    }
}

enum PhotoLibrary {

    /// Saves a displayable photo, optionally pairing a DNG with it as the
    /// alternate resource so Photos shows one asset with a RAW badge.
    static func save(photo: Data, alternateRAW: Data? = nil) async throws {
        let status = await requestAddAccess()
        guard status == .authorized || status == .limited else { throw PhotoLibraryError.denied }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: photo, options: nil)
            if let alternateRAW {
                request.addResource(with: .alternatePhoto, data: alternateRAW, options: nil)
            }
        }
    }

    private static func requestAddAccess() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current != .notDetermined { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }
}
