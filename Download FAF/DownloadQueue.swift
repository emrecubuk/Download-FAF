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

}

@MainActor

final class DownloadQueue: ObservableObject {

    @Published private(set) var items: [QueueItem] = []

    private var sessions: [UUID: DownloadSession] = [:]

    private let history: DownloadHistoryStore

    let maximumConcurrent = 3

    init(history: DownloadHistoryStore) {

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
        items[index].phase = .queued
        items[index].progress = 0
        items[index].speed = "—"
        items[index].eta = "—"
        items[index].message = nil
        schedule()
    }

    func removeFinished(_ id: UUID) {

        guard let index = items.firstIndex(where: { $0.id == id }),

              [.completed, .cancelled, .failed].contains(items[index].phase) else { return }

        items.remove(at: index)

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

        let item = items[index]

        let session = DownloadSession()

        sessions[id] = session

        items[index].phase = .downloading

        Task {

            let result = await Task.detached(priority: .userInitiated) {

                VideoEngine.run(arguments: item.job.arguments, session: session) { fraction, speed, eta in

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

        sessions.removeValue(forKey: id)

        items[index].speed = "—"

        items[index].eta = "—"

        if cancelled {

            items[index].phase = .cancelled

        } else if success {

            items[index].phase = .completed

            items[index].progress = 1

            saveHistory(for: item, output: output)

        } else {

            items[index].phase = .failed

            items[index].message = String(output.suffix(300))

        }

        schedule()

    }

    private func saveHistory(for item: QueueItem, output: String) {

        guard let marker = output.range(of: "FAF_FINAL_PATH:", options: .backwards) else { return }

        let path = String(output[marker.upperBound...])

            .components(separatedBy: .newlines).first?

            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }

        let attributes = try? FileManager.default.attributesOfItem(atPath: path)

        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        history.add(DownloadHistoryItem(

            id: UUID(), title: item.title, uploader: item.uploader,

            thumbnail: item.thumbnail, quality: item.job.qualityName,

            format: item.job.format, filePath: path,

            completedAt: Date(), fileSize: size

        ))

    }

}

