import Foundation
import UIKit

/** Shares URLs and files with other apps through the system share sheet. */
final class ShareService {
    private let timeline: Timeline
    private let downloader: Downloader
    private let ui: UIRef

    private let lock = NSLock()
    private var blobs: [[String: Any]]?

    init(timeline: Timeline, downloader: Downloader, ui: UIRef) {
        self.timeline = timeline
        self.downloader = downloader
        self.ui = ui
    }

    /** Stages blobs (JSON array of {auid, href}) for the next [shareBlobs] call. */
    func setShareBlobs(_ json: String) {
        let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]]
        lock.lock()
        blobs = parsed
        lock.unlock()
    }

    func shareURL(_ url: URL) async {
        await present([url])
    }

    /**
     * Shares staged blobs: on-device originals directly, remote ones after an
     * in-process download. Returns once the sheet is up; throws on the first failure.
     */
    func shareBlobs() async throws {
        guard let staged = takeBlobs() else { throw AppError("No blobs to share") }

        var files: [URL] = []
        for obj in staged {
            if let auid = obj["auid"] as? String, !auid.isEmpty,
               let photo = timeline.photos(auids: [auid]).first, let asset = timeline.asset(photo.assetId) {
                files.append(try await MediaFiles.exportOriginal(asset))
            } else if let href = (obj["href"] as? String).flatMap(URL.init(string:)) {
                files.append(try await downloader.download(href))
            }
        }
        guard !files.isEmpty else { throw AppError("Nothing to share") }
        await present(files) {
            files.forEach(MediaFiles.cleanupTemp)
        }
    }

    private func takeBlobs() -> [[String: Any]]? {
        lock.lock()
        defer { lock.unlock() }
        let staged = blobs
        blobs = nil
        return staged
    }

    /** Downloads in-process, then offers the file via the share sheet (Save to Files / Photos). */
    func downloadFromUrl(_ url: URL, filename: String, title: String?) {
        Task {
            await ui.ui?.toast("Downloading \(title.flatMap { $0.isEmpty ? nil : $0 } ?? "file")…", long: false)
            do {
                let file = try await downloader.download(url, filename: filename)
                await present([file]) { MediaFiles.cleanupTemp(file) }
            } catch {
                log.warning("downloadFromUrl failed: \(error.localizedDescription)")
                await ui.ui?.toast("Download failed: \(error.localizedDescription)", long: true)
            }
        }
    }

    @MainActor
    private func present(_ items: [Any], completion: (() -> Void)? = nil) {
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in completion?() }
        ui.ui?.presentSheet(sheet)
    }
}
