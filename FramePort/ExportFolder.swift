import Foundation
import Observation

/// Where exported frames are saved. One setting for the whole app: every window reads it from
/// here, so choosing a folder in one of them changes it in all.
@MainActor
@Observable
final class ExportFolder {
    static let shared = ExportFolder()

    private(set) var url: URL

    private static let key = "exportFolderPath"

    private init() {
        url = Self.stored ?? Self.downloads
    }

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    var isDownloads: Bool {
        url.standardizedFileURL == Self.downloads.standardizedFileURL
    }

    func choose(_ folder: URL) {
        url = folder
        UserDefaults.standard.set(folder.path, forKey: Self.key)
    }

    func reset() {
        url = Self.downloads
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    private static var stored: URL? {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }
}
