import Foundation
import Photos

/** User opt-in for local media plus the OS photo library grant. */
enum MediaPermissions {
    private static let allowKey = "allowMedia"

    static var allowMedia: Bool {
        get { UserDefaults.standard.bool(forKey: allowKey) }
        set { UserDefaults.standard.set(newValue, forKey: allowKey) }
    }

    static var hasLibraryAccess: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /** True once the user opted in and the OS grant exists. */
    static var hasMediaPermission: Bool { allowMedia && hasLibraryAccess }

    /** Shows the system prompt when undetermined; returns whether access is granted. */
    static func request() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }
}
