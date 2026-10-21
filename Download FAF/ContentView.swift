import SwiftUI

import AppKit

import Foundation

import Combine

struct DownloadHistoryItem: Identifiable, Codable {

    let id: UUID

    let title: String

    let uploader: String

    let thumbnail: String?

    let quality: String

    let format: String

    let filePath: String

    let completedAt: Date

    let fileSize: Int64

}

@MainActor

final class DownloadHistoryStore: ObservableObject {

    @Published private(set) var items: [DownloadHistoryItem] = []

    private let storageKey = "DownloadFAF.CompletedHistory.v1"

    init() {

        guard let data = UserDefaults.standard.data(forKey: storageKey),

              let saved = try? JSONDecoder().decode(

                [DownloadHistoryItem].self,

                from: data

              ) else {

            return

        }

        items = saved

    }

    func add(_ item: DownloadHistoryItem) {

        items.insert(item, at: 0)

        save()

    }

    func remove(_ id: UUID) {

        items.removeAll { $0.id == id }

        save()

    }

    private func save() {

        guard let data = try? JSONEncoder().encode(items) else {

            return

        }

        UserDefaults.standard.set(data, forKey: storageKey)

    }

}

struct ContentView: View {
    private enum Page: String, CaseIterable {
        case home = "Home", downloads = "Downloads", videos = "Videos", audio = "Audio", settings = "Settings"
        var icon: String {
            switch self {
            case .home: return "house"
            case .downloads: return "arrow.down.circle"
            case .videos: return "film"
            case .audio: return "music.note"
            case .settings: return "gearshape"
            }
        }
    }

    @State private var page: Page = .home
    @State private var videoURL = ""
    @State private var video: VideoInfo?
    @State private var analyzedURL = ""
    @State private var isAnalyzing = false
    @State private var analyzeError: String?
    @State private var selectedHeight: Int?
    @State private var format = "MP4"
    @State private var selectedTab = 0
    @AppStorage("DownloadFAF.DefaultFolder") private var storedFolder = ""
    @AppStorage("DownloadFAF.DefaultFormat") private var defaultFormat = "MP4"
    @StateObject private var history: DownloadHistoryStore
    @StateObject private var queue: DownloadQueue

    init() {
        let store = DownloadHistoryStore()
        _history = StateObject(wrappedValue: store)
        _queue = StateObject(wrappedValue: DownloadQueue(history: store))
    }

    private var folder: String {
        storedFolder.isEmpty ? (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()) : storedFolder
    }
    private var isAudio: Bool { selectedTab == 1 }
    private var qualities: [VideoQuality] { video?.qualities(for: format) ?? [] }
    private var selectedQuality: VideoQuality? { qualities.first { $0.height == selectedHeight } }
    private var canStart: Bool {
        video != nil && !isAnalyzing && (isAudio || selectedQuality != nil) &&
        analyzedURL == videoURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var activeItems: [QueueItem] {
        queue.items.filter { [.queued, .downloading, .paused, .cancelling, .failed].contains($0.phase) }
    }
    private let accent = Color(red: 0.12, green: 0.42, blue: 0.94)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.black.opacity(0.07)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                if page != .home { header; Divider() }
                Group {
                    switch page {
                    case .home: homePage
                    case .downloads: downloadsPage
                    case .videos: libraryPage(audio: false)
                    case .audio: libraryPage(audio: true)
                    case .settings: settingsPage
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 600, height: 225)
        .background(Color(red: 0.965, green: 0.972, blue: 0.984))
        .foregroundStyle(Color(red: 0.14, green: 0.19, blue: 0.28))
        .preferredColorScheme(.light)
        .onAppear { resetFormatToDefault() }
        .onChange(of: videoURL) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines) != analyzedURL {
                video = nil
                selectedHeight = nil
                analyzeError = nil
            }
        }
        .onChange(of: format) { _, newValue in
            if !isAudio { selectedHeight = video?.qualities(for: newValue).first?.height }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background(accent, in: RoundedRectangle(cornerRadius: 8))
                Text("Download AF")
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.top, 12)
            VStack(spacing: 3) {
                ForEach(Page.allCases, id: \.self) { item in
                    Button { page = item } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.icon).frame(width: 16)
                            Text(item.rawValue)
                            Spacer(minLength: 0)
                            if item == .downloads && !activeItems.isEmpty {
                                Text("\(activeItems.count)")
                                    .font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 4)
                                    .background(.white, in: Capsule())
                            }
                        }
                        .font(.system(size: 11, weight: page == item ? .semibold : .regular))
                        .foregroundStyle(page == item ? accent : Color.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 31)
                        .background(page == item ? Color.white.opacity(0.95) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: 151)
        .background(Color(red: 0.937, green: 0.948, blue: 0.965))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    page == .downloads ? "Active Downloads" :
                    page == .videos ? "Downloaded Videos" :
                    page == .audio ? "Downloaded Audio" :
                    page.rawValue
                )
                .font(.system(size: 17, weight: .bold))
            }
            Spacer()
            if page == .home || page == .downloads {
                Button { page = .downloads } label: {
                    Label("\(queue.activeCount)/3 active", systemImage: "arrow.down.circle")
                    .padding(.horizontal, 16).padding(.vertical, 5)                }
                .buttonStyle(.plain).foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
    private var headerSubtitle: String {
        switch page {
        case .home: return "Paste a link, choose a format, and download."
        case .downloads: return "Manage active downloads and your waiting queue."
        case .videos: return "Your completed video downloads."
        case .audio: return "Your completed audio downloads."
        case .settings: return "Customize your download preferences."
        }
    }

    private var homePage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("Paste a video URL...", text: $videoURL)
                    .textFieldStyle(.plain).font(.system(size: 11))
                    .onSubmit(analyze)
                if !videoURL.isEmpty {
                    Button { videoURL = ""; video = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Button {
                    videoURL = NSPasteboard.general.string(forType: .string) ?? ""
                } label: { Image(systemName: "doc.on.clipboard") }
                    .buttonStyle(.plain).help("Paste URL")
                Button(action: analyze) {
                    Text("Analyze").font(.system(size: 11, weight: .semibold))
                        .frame(width: 62, height: 28)
                }
                .buttonStyle(.borderedProminent).tint(accent)
                .disabled(isAnalyzing || videoURL.isEmpty)
            }
            .padding(.horizontal, 10).frame(height: 46)
            .background(.white, in: RoundedRectangle(cornerRadius: 13))

            if isAnalyzing {
                HStack { ProgressView().controlSize(.small); Text("Analyzing link...") }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let analyzeError {
                Text(analyzeError).font(.system(size: 10))
                    .foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
            }
            if let video {
                videoCard(video)
            } else if !isAnalyzing {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 28, weight: .ultraLight)).foregroundStyle(accent)
                    Text("Ready for your next download")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Paste a link to preview the video.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white, in: RoundedRectangle(cornerRadius: 13))
            }
            if !activeItems.isEmpty {
                HStack {
                    Text("Download Activity").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button("View all") { page = .downloads }
                        .buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 10))
                }
                ForEach(Array(activeItems.prefix(1))) { item in queueRow(item) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func videoCard(_ info: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
          HStack(alignment: .top, spacing: 9) {
            thumbnail(info.thumbnail, width: 113, height: 87, audio: false)
            VStack(alignment: .leading, spacing: 6) {
                Text(info.title)
                    .font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Text(info.uploader ?? "Unknown creator")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                if let duration = info.duration {
                    Label(durationText(duration), systemImage: "clock")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Button {
                    if let url = URL(string: analyzedURL) { NSWorkspace.shared.open(url) }
                } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.plain).foregroundStyle(accent)
                    .help("Open original")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 6) {
                Picker("Type", selection: $selectedTab) {
                    Text("Video").tag(0)
                    Text("Audio").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden()
                .onChange(of: selectedTab) { _, newValue in
                    format = newValue == 1 ? "MP3" : "MP4"
                    selectedHeight = newValue == 1 ? nil : video?.qualities(for: "MP4").first?.height
                }
                Picker("Format", selection: $format) {
                    ForEach(isAudio ? ["MP3", "M4A"] : ["MP4", "WebM"], id: \.self) { item in
                        Text(item).tag(item)
                    }
                }.labelsHidden()
                if !isAudio {
                    Picker("Quality", selection: $selectedHeight) {
                        Text("Quality").tag(nil as Int?)
                        ForEach(qualities) { quality in
                            Text("\(quality.name) · \(quality.sizeText)").tag(Optional(quality.height))
                        }
                    }.labelsHidden()
                }
                Button(action: addToQueue) {
                    Label("Download", systemImage: "arrow.down.to.line")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 24)
                }
                .buttonStyle(.borderedProminent).tint(accent).disabled(!canStart)
            }
            .frame(width: 119)
        }
          Button(action: chooseFolder) {
                Label(URL(fileURLWithPath: folder).lastPathComponent, systemImage: "folder")
                    .font(.system(size: 9)).lineLimit(1)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 13))
    }

    private var downloadsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if queue.items.isEmpty {
                    emptyLibrary("No downloads yet", icon: "arrow.down.circle")
                } else {
                    ForEach(queue.items.reversed()) { item in
                        queueRow(item)
                    }
                }
            }
            .padding(12)
        }
    }

    private func queueRow(_ item: QueueItem) -> some View {
        HStack(spacing: 8) {
            thumbnail(item.thumbnail, width: 55, height: 39, audio: item.job.format == "MP3" || item.job.format == "M4A")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text("\(Int(item.progress * 100))%")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
                ProgressView(value: item.progress).tint(accent)
                HStack(spacing: 5) {
                    Text(item.phase.rawValue)
                    if item.phase == .downloading { Text("· \(item.speed) · \(item.eta) left") }
                    if item.phase == .failed { Text("· Download interrupted") }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            if item.phase == .downloading {
                Button { queue.pause(item.id) } label: { Image(systemName: "pause.fill") }.help("Pause")
            } else if item.phase == .paused {
                Button { queue.resume(item.id) } label: { Image(systemName: "play.fill") }.help("Resume")
            } else if item.phase == .failed {
                Button { queue.retry(item.id) } label: { Image(systemName: "arrow.clockwise") }.help("Retry")
            }
            if [.queued, .downloading, .paused].contains(item.phase) {
                Button { queue.cancel(item.id) } label: { Image(systemName: "xmark") }.help("Cancel")
            } else if [.completed, .cancelled, .failed].contains(item.phase) {
                Button { queue.removeFinished(item.id) } label: { Image(systemName: "trash") }.help("Remove from queue")
            }
        }
        .buttonStyle(.plain).padding(9)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
    }

    private func libraryPage(audio: Bool) -> some View {
        let filtered = history.items.filter { item in
            let isAudioFile = item.format == "MP3" || item.format == "M4A"
            return isAudioFile == audio
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if filtered.isEmpty {
                    emptyLibrary(audio ? "No audio downloads yet" : "No video downloads yet", icon: audio ? "music.note" : "film")
                } else {
                    ForEach(filtered) { item in historyRow(item) }
                }
            }.padding(12)
        }
    }

    private func historyRow(_ item: DownloadHistoryItem) -> some View {
        let url = URL(fileURLWithPath: item.filePath)
        let exists = FileManager.default.fileExists(atPath: item.filePath)
        return HStack(spacing: 8) {
            thumbnail(item.thumbnail, width: 55, height: 39, audio: item.format == "MP3" || item.format == "M4A")
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(item.quality) · \(item.format) · \(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(item.completedAt, style: .date).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "play.fill") }
                .disabled(!exists).help("Open file")
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                .disabled(!exists).help("Show in Finder")
            Button { history.remove(item.id) } label: { Image(systemName: "trash") }
                .help("Remove history entry only")
        }
        .buttonStyle(.plain).padding(9)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
    }

    private func emptyLibrary(_ message: String, icon: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 38, weight: .ultraLight)).foregroundStyle(accent)
            Text(message).font(.system(size: 15, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity).frame(height: 145)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
    }

    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 17) {
                    Text("General").font(.system(size: 16, weight: .semibold))
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Download folder").font(.system(size: 13, weight: .medium))
                            Text(folder).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Change…", action: chooseFolder)
                    }
                }
                .padding(20).background(.white, in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 17) {
                    Text("Downloads").font(.system(size: 16, weight: .semibold))
                    HStack {
                        Text("Default format").font(.system(size: 13))
                        Spacer()
                        Picker("Default format", selection: $defaultFormat) {
                            ForEach(["MP4", "WebM", "MP3", "M4A"], id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(width: 130)
                    }
                    Divider()
                    HStack {
                        Text("Simultaneous downloads").font(.system(size: 13))
                        Spacer()
                        Text("3").font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                    }
                    Text("Additional downloads automatically wait in the queue.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(20).background(.white, in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 8) {
                    Text("About").font(.system(size: 16, weight: .semibold))
                    Text("Download AF · yt-dlp + FFmpeg")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 15))
            }.padding(12)
        }
    }

    private func thumbnail(_ source: String?, width: CGFloat, height: CGFloat, audio: Bool) -> some View {
        Group {
            if let source, let url = URL(string: source) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: audio ? "music.note" : "play.rectangle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Image(systemName: audio ? "music.note" : "play.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: width, height: height)
        .background(Color(red: 0.92, green: 0.94, blue: 0.97))
        .clipped().clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func durationText(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func resetFormatToDefault() {
        let chosen = ["MP4", "WebM", "MP3", "M4A"].contains(defaultFormat) ? defaultFormat : "MP4"
        selectedTab = (chosen == "MP3" || chosen == "M4A") ? 1 : 0
        format = chosen
    }

    private func validLink() -> String? {

        let link = videoURL.trimmingCharacters(

            in: .whitespacesAndNewlines

        )

        guard let url = URL(string: link),

              let scheme = url.scheme?.lowercased(),

              ["http", "https"].contains(scheme),

              url.host != nil else {

            return nil

        }

        return link

    }

    private func analyze() {

        guard let link = validLink() else {

            analyzeError = "Please enter a valid video URL."

            video = nil

            return

        }

        isAnalyzing = true

        analyzeError = nil

        video = nil

        selectedHeight = nil

        resetFormatToDefault()

        Task {

            let result = await Task.detached(

                priority: .userInitiated

            ) {

                await Self.fetchVideoInfo(link: link)

            }.value

            isAnalyzing = false

            guard videoURL.trimmingCharacters(

                in: .whitespacesAndNewlines

            ) == link else {

                return

            }

            video = result.info

            analyzedURL = link

            analyzeError = result.error

            selectedHeight = result.info?

                .qualities(for: format)

                .first?.height

        }

    }

    nonisolated private static func fetchVideoInfo(

        link: String

    ) async -> (info: VideoInfo?, error: String?) {

        let process = Process()

        let outputPipe = Pipe()

        let errorPipe = Pipe()

        process.executableURL = URL(

            fileURLWithPath: VideoEngine.tool

        )

        process.arguments = [

            "--dump-single-json",

            "--skip-download",

            "--no-playlist",

            "--no-warnings",

            link

        ]

        process.standardOutput = outputPipe

        process.standardError = errorPipe

        do {

            try process.run()

            let data = outputPipe.fileHandleForReading

                .readDataToEndOfFile()

            let errorData = errorPipe.fileHandleForReading

                .readDataToEndOfFile()

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {

                return (

                    nil,

                    String(decoding: errorData, as: UTF8.self)

                )

            }

            let info = try JSONDecoder().decode(

                VideoInfo.self,

                from: data

            )

            let verified = await VideoEngine.verifySizes(

                in: info

            )

            return (verified, nil)

        } catch {

            return (nil, error.localizedDescription)

        }

    }

    private func chooseFolder() {

        let picker = NSOpenPanel()

        picker.canChooseDirectories = true

        picker.canChooseFiles = false

        picker.allowsMultipleSelection = false

        picker.prompt = "Select Folder"

        if picker.runModal() == .OK,

           let url = picker.url {

            storedFolder = url.path

        }

    }

    private func addToQueue() {
        guard canStart, let info = video, let link = validLink() else { return }
        let chosenQuality: VideoQuality? = isAudio ? nil : selectedQuality
        var arguments = VideoEngine.downloadArguments(
            url: link,
            folder: folder,
            quality: chosenQuality,
            format: format
        )
        arguments.insert(
            contentsOf: ["--print", "after_move:FAF_FINAL_PATH:%(filepath)s"],
            at: max(0, arguments.count - 1)
        )
        let job = DownloadJob(
            url: link,
            folder: folder,
            format: format,
            qualityName: isAudio ? "Audio" : chosenQuality?.name ?? "Video",
            arguments: arguments
        )
        queue.add(job: job, info: info)
        videoURL = ""
        video = nil
        analyzedURL = ""
        selectedHeight = nil
        analyzeError = nil
    }

}

#Preview {

    ContentView()

}
