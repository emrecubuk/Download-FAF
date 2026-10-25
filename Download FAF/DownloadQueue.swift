import Foundation
import Combine

enum QueuePhase: String {

    case queued = "Queued"

    case downloading = "Downloading"

    case paused = "Paused"

    case cancelling = "Cancelling"

    case completed = "Completed"

    case cancelled = "Cancelled"

    case failed = "Failed"

}

struct QueueItem: Identifiable {

    let id: UUID

    let job: DownloadJob

    let title: String

    let uploader: String

    let thumbnail: String?

    var phase: QueuePhase = .queued

    var progress: Double = 0

    var speed = "—"

    var eta = "—"

    var message: String?

    var completedAt: Date?

    var filePath: String?

    var fileSize: Int64?

    var temporaryDirectory: String?

}

@MainActor

final class DownloadQueue: ObservableObject {

    @Published private(set) var items: [QueueItem] = []

    private var sessions: [UUID: DownloadSession] = [:]

    private let history: DownloadHistoryStore
    private let notify: @MainActor (UUID, String, Bool, String?) async -> Void
    let maximumConcurrent = 3

    init(
        history: DownloadHistoryStore,
        notify: @escaping @MainActor (UUID, String, Bool, String?) async -> Void = { id, title, succeeded, thumbnail in
            await DownloadNotifications.shared.send(
                id: id,
                title: title,
                succeeded: succeeded,
                thumbnailURL: thumbnail
            )
        }
    ) {
        self.notify = notify
        self.history = history
    }

    var activeCount: Int {

        items.filter { [.downloading, .paused, .cancelling].contains($0.phase) }.count

    }

    var waitingCount: Int {

        items.filter { $0.phase == .queued }.count

    }

    func add(job: DownloadJob, info: VideoInfo) {

        items.append(QueueItem(

            id: UUID(), job: job, title: info.title,

            uploader: info.uploader ?? "Unknown creator", thumbnail: info.thumbnail

        ))

        schedule()

    }

    func pause(_ id: UUID) {

        guard let index = items.firstIndex(where: { $0.id == id }),

              items[index].phase == .downloading,

              sessions[id]?.pause() == true else { return }

        items[index].phase = .paused

        items[index].speed = "—"

        items[index].eta = "—"

    }

    func resume(_ id: UUID) {

        guard let index = items.firstIndex(where: { $0.id == id }),

              items[index].phase == .paused,

              sessions[id]?.resume() == true else { return }

        items[index].phase = .downloading

    }

    func cancel(_ id: UUID) {

        guard let index = items.firstIndex(where: { $0.id == id }) else { return }

        switch items[index].phase {

        case .queued:

            items[index].phase = .cancelled

            schedule()

        case .downloading, .paused:

            items[index].phase = .cancelling

            sessions[id]?.cancel()

        default:

            break

        }

    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].phase == .failed else { return }
        cleanupTemporaryFiles(for: items[index])
        items[index].temporaryDirectory = nil
        items[index].phase = .queued
        items[index].progress = 0
        items[index].speed = "—"
        items[index].eta = "—"
        items[index].message = nil
        items[index].completedAt = nil
        items[index].filePath = nil
        items[index].fileSize = nil
        schedule()
    }

    func removeFinished(_ id: UUID) {

        guard let index = items.firstIndex(where: { $0.id == id }),

              [.completed, .cancelled, .failed].contains(items[index].phase) else { return }

        let item = items[index]
        if item.phase == .failed || item.phase == .cancelled {
            cleanupTemporaryFiles(for: item)
        }
        items.remove(at: index)

    }

    func moveCompletedToTrash(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].phase == .completed,
              let path = items[index].filePath else {
            throw NSError(domain: "DownloadFAF", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The completed file could not be located."])
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "DownloadFAF", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The file is no longer on this Mac."])
        }
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
        for entry in history.items where entry.filePath == path {
            history.remove(entry.id)
        }
        items.remove(at: index)
    }

    private func cleanupTemporaryFiles(for item: QueueItem) {
        guard let path = item.temporaryDirectory else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let parent = URL(fileURLWithPath: item.job.folder, isDirectory: true).standardizedFileURL
        guard directory.deletingLastPathComponent() == parent,
              directory.lastPathComponent.hasPrefix(".DownloadFAF-Partial-"),
              (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func schedule() {

        while activeCount < maximumConcurrent,

              let index = items.firstIndex(where: { $0.phase == .queued }) {

            launch(items[index].id)

        }

    }

    private func launch(_ id: UUID) {

        guard let index = items.firstIndex(where: { $0.id == id }),

              items[index].phase == .queued else { return }

        var item = items[index]
        let tempURL = URL(fileURLWithPath: item.job.folder, isDirectory: true)
            .appendingPathComponent(".DownloadFAF-Partial-\(id.uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        } catch {
            items[index].phase = .failed
            items[index].message = "Cannot create temporary download folder: \(error.localizedDescription)"
            schedule()
            return
        }
        items[index].temporaryDirectory = tempURL.path
        item = items[index]
        var arguments = item.job.arguments
        arguments.insert(contentsOf: ["-P", "temp:\(tempURL.path)"], at: max(0, arguments.count - 1))

        let runArguments = arguments
        let session = DownloadSession()

        sessions[id] = session

        items[index].phase = .downloading

        Task {

            let result = await Task.detached(priority: .userInitiated) {

                VideoEngine.run(arguments: runArguments, session: session) { fraction, speed, eta in

                    Task { @MainActor [weak self] in

                        self?.update(id, fraction: fraction, speed: speed, eta: eta)

                    }

                }

            }.value

            complete(id, success: result.0, output: result.1, cancelled: session.isCancelled)

        }

    }

    private func update(_ id: UUID, fraction: Double, speed: String, eta: String) {

        guard let index = items.firstIndex(where: { $0.id == id }),

              items[index].phase == .downloading else { return }

        items[index].progress = min(max(fraction, 0), 0.99)

        items[index].speed = speed

        items[index].eta = eta

    }

    private func complete(_ id: UUID, success: Bool, output: String, cancelled: Bool) {

        guard let index = items.firstIndex(where: { $0.id == id }) else { return }

        let item = items[index]
        // Only a running attempt may transition to a terminal state once.
        guard [.downloading, .paused, .cancelling].contains(item.phase) else { return }

        sessions.removeValue(forKey: id)

        items[index].speed = "—"

        items[index].eta = "—"

        if cancelled {

            items[index].phase = .cancelled

        } else if success {

            items[index].phase = .completed

            items[index].progress = 1

            items[index].completedAt = Date()
            if let file = completedFile(from: output) {
                items[index].filePath = file.path
                items[index].fileSize = file.size
                history.add(DownloadHistoryItem(
                    id: UUID(), title: item.title, uploader: item.uploader,
                    thumbnail: item.thumbnail, quality: item.job.qualityName,
                    format: item.job.format, filePath: file.path,
                    completedAt: items[index].completedAt!, fileSize: file.size
                ))
            }

        } else {

            items[index].phase = .failed

            items[index].message = String(output.suffix(300))

        }

        if cancelled || success {
            cleanupTemporaryFiles(for: items[index])
        }

        if !cancelled {
            let notificationID = UUID()
            Task {
                await notify(notificationID, item.title, success, item.thumbnail)            }
        }
        schedule()

    }

    private func completedFile(from output: String) -> (path: String, size: Int64)? {
        guard let marker = output.range(of: "FAF_FINAL_PATH:", options: .backwards) else { return nil }
        let path = String(output[marker.upperBound...])
            .components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return (path, size)
    }

}


@MainActor
final class DownloadServices {
    static let shared = DownloadServices()
    let history: DownloadHistoryStore
    let queue: DownloadQueue

    private init() {
        let store = DownloadHistoryStore()
        history = store
        queue = DownloadQueue(history: store)
    }
}
