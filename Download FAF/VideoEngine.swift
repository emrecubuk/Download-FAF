import Foundation
import Darwin
nonisolated struct VideoQuality: Identifiable, Hashable, Sendable {
    let height: Int
    let videoFormatID: String
    let audioFormatID: String?
    let estimatedBytes: Int64?
    let isEstimated: Bool
    var id: Int {
        height
    }
    var name: String {
        height == 2160 ? "4K (2160p)" : "\(height)p"
    }
    var sizeText: String {
        guard let estimatedBytes, estimatedBytes > 0 else {
            return "Size unknown"
        }
        let size = ByteCountFormatter.string(
            fromByteCount: estimatedBytes,
            countStyle: .file
        )
        return isEstimated ? "~\(size)" : size
    }
    var selector: String {
        guard let audioFormatID else {
            return videoFormatID
        }
        return "\(videoFormatID)+\(audioFormatID)"
    }
}
nonisolated struct VideoFormatInfo: Decodable, Sendable {
    let format_id: String?
    let vcodec: String?
    let acodec: String?
    let height: Int?
    let width: Int?
    let filesize: Int64?
    let filesize_approx: Int64?
    let tbr: Double?
    let ext: String?
    let url: String?
    let protocolName: String?
    let http_headers: [String: String]?
    enum CodingKeys: String, CodingKey {
        case format_id
        case vcodec
        case acodec
        case height
        case width
        case filesize
        case filesize_approx
        case tbr
        case ext
        case url
        case http_headers
        case protocolName = "protocol"
    }
    var hasVideo: Bool {
        guard let vcodec else {
            return false
        }
        return vcodec != "none"
    }
    var hasAudio: Bool {
        guard let acodec else {
            return false
        }
        return acodec != "none"
    }
    var isDirectHTTP: Bool {
        let value = protocolName?.lowercased()
        return value == "https" || value == "http"
    }
    var displayResolution: Int? {
        guard let height, height > 0 else { return nil }
        guard let width, width > 0 else { return height }
        return min(width, height)
    }
    var knownBytes: Int64? {
        guard let filesize, filesize > 0 else {
            return nil
        }
        return filesize
    }
}
nonisolated struct VideoInfo: Decodable, Sendable {
    let title: String
    let uploader: String?
    let duration: Double?
    let thumbnail: String?
    let formats: [VideoFormatInfo]?
    var verifiedSizes: [String: Int64]?
    enum CodingKeys: String, CodingKey {
        case title
        case uploader
        case duration
        case thumbnail
        case formats
    }
    func qualities(for output: String) -> [VideoQuality] {
        guard let formats else {
            return []
        }
        let container = output.lowercased()
        guard container == "mp4" || container == "webm" else {
            return []
        }
        let audioExtension = container == "mp4"
            ? "m4a"
            : "webm"
        let audioCandidates = formats.filter {
            !$0.hasVideo &&
            $0.hasAudio &&
            $0.ext?.lowercased() == audioExtension &&
            $0.format_id != nil
        }
        let audio = preferredFormat(
            from: audioCandidates
        )
        let videos = formats.filter {
            $0.hasVideo &&
            ($0.displayResolution ?? 0) > 0 &&
            $0.ext?.lowercased() == container &&
            $0.format_id != nil &&
            ($0.hasAudio || audio != nil)
        }
        let heights = Set(
            videos.compactMap(\.displayResolution)
        )
        return heights
            .sorted(by: >)
            .compactMap { height -> VideoQuality? in
                let candidates = videos.filter {
                    $0.displayResolution == height
                }
                guard let selected = preferredFormat(
                    from: candidates
                ),
                let videoID = selected.format_id else {
                    return nil
                }
                let audioChoice: VideoFormatInfo? =
                    selected.hasAudio ? nil : audio
                let videoBytes = bytes(
                    for: selected
                )
                let audioBytes = audioChoice.flatMap {
                    bytes(for: $0)
                }
                let total: Int64?
                if let videoBytes {
                    if selected.hasAudio {
                        total = videoBytes
                    } else if let audioBytes {
                        let result = videoBytes
                            .addingReportingOverflow(audioBytes)
                        total = result.overflow
                            ? nil
                            : result.partialValue
                    } else {
                        total = nil
                    }
                } else {
                    total = nil
                }
                return VideoQuality(
                    height: height,
                    videoFormatID: videoID,
                    audioFormatID: audioChoice?.format_id,
                    estimatedBytes: total,
                    isEstimated: false
                )
            }
    }
    private func bytes(
        for format: VideoFormatInfo
    ) -> Int64? {
        if let id = format.format_id,
           let verified = verifiedSizes?[id],
           verified > 0 {
            return verified
        }
        return format.knownBytes
    }
    private func preferredFormat(
        from candidates: [VideoFormatInfo]
    ) -> VideoFormatInfo? {
        candidates.max { first, second in
            if first.isDirectHTTP != second.isDirectHTTP {
                return !first.isDirectHTTP
            }
            return (first.tbr ?? 0) < (second.tbr ?? 0)
        }
    }
}
struct DownloadJob: Codable, Sendable {
    let url: String
    let folder: String
    let format: String
    let qualityName: String
    let arguments: [String]
}
nonisolated final class DownloadSession: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var paused = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }
    func attach(_ newProcess: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else {
            return false
        }
        process = newProcess
        return true
    }
    @discardableResult
    func pause() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled,
              !paused,
              let process,
              process.isRunning else {
            return false
        }
        let result = kill(
            process.processIdentifier,
            SIGSTOP
        )
        guard result == 0 else {
            return false
        }
        paused = true
        return true
    }
    @discardableResult
    func resume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled,
              paused,
              let process,
              process.isRunning else {
            return false
        }
        let result = kill(
            process.processIdentifier,
            SIGCONT
        )
        guard result == 0 else {
            return false
        }
        paused = false
        return true
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let active = process
        let wasPaused = paused
        paused = false
        lock.unlock()
        guard let active, active.isRunning else {
            return
        }
        if wasPaused {
            kill(
                active.processIdentifier,
                SIGCONT
            )
        }
        active.terminate()
    }
    func clear() {
        lock.lock()
        process = nil
        paused = false
        lock.unlock()
    }
}
nonisolated enum VideoEngine {
    private static let searchDirectories: [String] = {
        let home = NSHomeDirectory()
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        return Array(Set([
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            home + "/.local/bin", home + "/bin"
        ] + inherited)).sorted()
    }()

    private static func locate(_ name: String) -> String? {
        let homebrewPath = "/opt/homebrew/bin/\(name)"

        if FileManager.default.isExecutableFile(atPath: homebrewPath) {
            return homebrewPath
        }

        let managed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DownloadFAF/Tools")
            .appendingPathComponent(name)
            .path

        if FileManager.default.isExecutableFile(atPath: managed) {
            return managed
        }

        for directory in searchDirectories {
            let path = (directory as NSString).appendingPathComponent(name)

            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    static var toolPath: String? { locate("yt-dlp") }
    static var ffmpegPath: String? { locate("ffmpeg") }
    static var tool: String { toolPath ?? "" }
    static var ffmpeg: String { ffmpegPath ?? "" }

    static var processEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let current = environment["PATH"] ?? ""
        environment["PATH"] = ([FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DownloadFAF/Tools").path] + searchDirectories + [current]).joined(separator: ":")
        return environment
    }

    static let missingYTDLP = "yt-dlp was not found. Open Settings → Dependencies → Install Dependencies"
    static let missingFFmpeg = "ffmpeg was not found. Open Settings → Dependencies → Install Dependencies"
    static func verifySizes(
        in info: VideoInfo
    ) async -> VideoInfo {
        var updated = info
        guard let formats = info.formats else {
            return updated
        }
        let selectedQualities =
            info.qualities(for: "MP4") +
            info.qualities(for: "WEBM")
        var selectedIDs = Set<String>()
        for quality in selectedQualities {
            selectedIDs.insert(
                quality.videoFormatID
            )
            if let audioID = quality.audioFormatID {
                selectedIDs.insert(audioID)
            }
        }
        let candidates = formats.filter {
            guard let id = $0.format_id else {
                return false
            }
            return selectedIDs.contains(id) &&
                $0.knownBytes == nil &&
                $0.isDirectHTTP &&
                $0.url != nil
        }
        var results: [String: Int64] = [:]
        await withTaskGroup(
            of: (String, Int64)?.self
        ) { group in
            for format in candidates {
                group.addTask {
                    guard let id = format.format_id,
                          let size = await fetchSize(
                            for: format
                          ) else {
                        return nil
                    }
                    return (id, size)
                }
            }
            for await result in group {
                if let result {
                    results[result.0] = result.1
                }
            }
        }
        updated.verifiedSizes = results
        return updated
    }
    private static func fetchSize(
        for format: VideoFormatInfo
    ) async -> Int64? {
        guard let urlString = format.url,
              let url = URL(string: urlString),
              url.scheme == "https" ||
              url.scheme == "http" else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 6
        for (key, value) in format.http_headers ?? [:] {
            request.setValue(
                value,
                forHTTPHeaderField: key
            )
        }
        request.setValue(
            "identity",
            forHTTPHeaderField: "Accept-Encoding"
        )
        do {
            let (_, response) = try await URLSession.shared.data(
                for: request
            )
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                return nil
            }
            guard let lengthString = http.value(
                forHTTPHeaderField: "Content-Length"
            ),
            let length = Int64(lengthString),
            length > 0 else {
                return nil
            }
            return length
        } catch {
            return nil
        }
    }
    static func downloadArguments(
        url: String,
        folder: String,
        quality: VideoQuality?,
        format: String
    ) -> [String] {
        let downloadID = String(UUID().uuidString.prefix(8))
        var args = [
            "--no-playlist", "--newline", "--continue", "--part",
            "--no-overwrites", "--no-colors", "--progress",
            "--progress-delta", "0.2",
            "--progress-template",
            "download:DLJSON:%(progress)j",
            "--ffmpeg-location", ffmpeg,
            "-P", folder,
            "-o", "%(title).180B [%(id)s] [\(downloadID)].%(ext)s"
        ]
        let outputFormat = format.uppercased()
        if outputFormat == "MP3" || outputFormat == "M4A" {
            args += ["-f", "bestaudio/best", "-x", "--audio-format", outputFormat.lowercased()]
        } else if let quality {
            args += ["-f", quality.selector, "--merge-output-format", outputFormat.lowercased()]
        } else {
            args += ["-f", "__no_selected_quality__"]
        }
        args.append(url)
        return args
    }
    private static func formatETA(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 86400 * 30 else { return "—" }
        let total = Int(seconds.rounded(.up))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
    private struct ProgressMetrics: Decodable {
        let status: String?
        let downloaded_bytes: Double?
        let total_bytes: Double?
        let total_bytes_estimate: Double?
        let speed: Double?
    }

    private struct SpeedSample {
        let time: TimeInterval
        let bytes: Double
    }

    static func run(
        arguments: [String],
        session: DownloadSession,
        progress: @escaping @Sendable (Double, String, String) -> Void
    ) -> (Bool, String) {
        if session.isCancelled { return (false, "Cancelled") }
        guard let ytDLP = toolPath else { return (false, missingYTDLP) }
        guard let ffmpegExecutable = ffmpegPath else { return (false, missingFFmpeg) }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ytDLP)
        var resolvedArguments = arguments
        if let index = resolvedArguments.firstIndex(of: "--ffmpeg-location"),
           resolvedArguments.indices.contains(index + 1) {
            resolvedArguments[index + 1] = ffmpegExecutable
        }
        process.arguments = resolvedArguments
        process.environment = processEnvironment
        process.standardOutput = pipe
        process.standardError = pipe

        guard session.attach(process) else { return (false, "Cancelled") }
        defer { session.clear() }

        do {
            if session.isCancelled { return (false, "Cancelled") }
            try process.run()
            if session.isCancelled && process.isRunning { process.terminate() }
        } catch {
            return (false, error.localizedDescription)
        }

        var pending = ""
        var recentOutput = ""
        var samples: [SpeedSample] = []
        var previousBytes: Double?
        var previousTime: TimeInterval?
        var previousTotal: Double?
        var previousPaused = false
        let window: TimeInterval = 8
        let formatIndex = arguments.firstIndex(of: "-f")
        let selector = formatIndex.flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        } ?? ""
        let hasSeparateAudio = selector.contains("+")
        let videoWeight = 0.95
        var stage = 0
        var lastStageFraction = 0.0
        var lastOverallFraction = 0.0

        func consume(_ line: String) {
            recentOutput += line + "\n"
            if recentOutput.count > 6000 {
                recentOutput = String(recentOutput.suffix(6000))
            }

            guard let marker = line.range(of: "DLJSON:") else { return }
            let json = String(line[marker.upperBound...])
            guard let data = json.data(using: .utf8),
                  let metric = try? JSONDecoder().decode(ProgressMetrics.self, from: data) else {
                return
            }

            guard metric.status == "downloading" else {
                if metric.status == "finished" {
                    if hasSeparateAudio && stage == 0 {
                        stage = 1
                        lastOverallFraction = max(lastOverallFraction, videoWeight)
                    }
                    samples.removeAll()
                    previousBytes = nil
                    previousTime = nil
                    previousTotal = nil
                    lastStageFraction = 0
                    progress(min(lastOverallFraction, 0.99), "—", "Processing...")
                }
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            let downloaded = metric.downloaded_bytes ?? 0
            let total = metric.total_bytes ?? metric.total_bytes_estimate
            let paused = session.isPaused

            if paused {
                previousPaused = true
                return
            }

            let bytesWentBack = previousBytes.map { downloaded < $0 } ?? false
            let longGap = previousTime.map { now - $0 > 5 } ?? false
            let totalChanged = previousTotal.flatMap { oldTotal in
                total.map { abs($0 - oldTotal) > max(oldTotal * 0.15, 1_000_000) }
            } ?? false
            if hasSeparateAudio && stage == 0 && bytesWentBack && lastStageFraction > 0.8 {
                stage = 1
                lastOverallFraction = max(lastOverallFraction, videoWeight)
            }
            if previousPaused || bytesWentBack || longGap || totalChanged {
                samples.removeAll()
                previousBytes = nil
                previousTime = nil
            }
            previousPaused = false
            previousTotal = total
            previousBytes = downloaded
            previousTime = now

            samples.append(SpeedSample(time: now, bytes: downloaded))
            samples.removeAll { now - $0.time > window }
            if samples.count > 30 { samples.removeFirst(samples.count - 30) }

            var averageSpeed: Double?
            if let first = samples.first, let last = samples.last {
                let elapsed = last.time - first.time
                let delta = last.bytes - first.bytes
                if elapsed >= 0.5 && delta > 0 {
                    averageSpeed = delta / elapsed
                }
            }

            let speedValue = averageSpeed ?? metric.speed
            let speedText: String
            if let speedValue, speedValue.isFinite, speedValue > 0 {
                speedText = ByteCountFormatter.string(fromByteCount: Int64(speedValue), countStyle: .file) + "/s"
            } else {
                speedText = "—"
            }

            let fraction: Double
            if let total, total > 0 {
                fraction = min(max(downloaded / total, 0), 1)
            } else {
                fraction = 0
            }

            lastStageFraction = fraction
            let overallFraction = hasSeparateAudio
                ? (stage == 0 ? fraction * videoWeight : videoWeight + fraction * (1 - videoWeight))
                : fraction
            lastOverallFraction = max(lastOverallFraction, min(overallFraction, 0.99))

            let etaText: String
            if let total, total > 0, downloaded >= total {
                etaText = "Processing..."
            } else if let total, total > downloaded,
                      let speedValue, speedValue.isFinite, speedValue > 0 {
                let seconds = (total - downloaded) / speedValue
                etaText = Self.formatETA(seconds)
            } else {
                etaText = "—"
            }

            progress(lastOverallFraction, speedText, etaText)
        }

        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            pending += String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "\n")
            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newline])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                pending.removeSubrange(...newline)
                consume(line)
            }
        }
        if !pending.isEmpty { consume(pending) }
        process.waitUntilExit()
        if session.isCancelled { return (false, "Cancelled") }
        return (process.terminationStatus == 0,
                recentOutput.isEmpty ? "Download failed" : recentOutput)
    }
}

