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
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: storageKey),

              let saved = try? JSONDecoder().decode(

                [DownloadHistoryItem].self,

                from: data

              ) else {

            return

        }

        items = saved

    }

    func add(_ item: DownloadHistoryItem) {
        guard AppPreferences.enabled(AppPreferences.saveHistory, defaults: defaults) else { return }

        items.insert(item, at: 0)

        save()

    }

    func remove(_ id: UUID) {

        items.removeAll { $0.id == id }

        save()

    }

    func clear() {
        defaults.removeObject(forKey: storageKey)
        items.removeAll()
    }

    private func save() {

        guard let data = try? JSONEncoder().encode(items) else {

            return

        }

        defaults.set(data, forKey: storageKey)

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

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppPreferences.saveHistory) private var saveHistory = true
    @State private var hasRevealedDownloads = false
    // nil is the settled state; 0 reserves space, 1 reveals the icon, 2...10 types the label.
    @State private var downloadsRevealStep: Int?
    @State private var pendingRemoval: UUID?
    @State private var removalError: String?
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

    private var downloadsVisible: Bool {
        hasRevealedDownloads || !queue.items.isEmpty
    }

    private var sidebarPages: [Page] {
        downloadsVisible ? Page.allCases : [.home, .videos, .audio, .settings]
    }

    private func isHistoryPage(_ item: Page) -> Bool {
        item == .videos || item == .audio
    }

    private var downloadsIconVisible: Bool {
        downloadsRevealStep.map { $0 >= 1 } ?? true
    }

    private var downloadsLabel: String {
        String(Page.downloads.rawValue.prefix(downloadsRevealStep.map { max(0, $0 - 1) } ?? 9))
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
    private var accent: Color {
        colorScheme == .dark ? Color(nsColor: .systemBlue) : Color(red: 0.12, green: 0.42, blue: 0.94)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
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
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
        .background(colorScheme == .dark ? Color(nsColor: .underPageBackgroundColor) : Color(red: 0.965, green: 0.972, blue: 0.984))
        .foregroundStyle(Color.primary)
        .confirmationDialog("Delete Download?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible) {
            Button("Remove from List") {
                if let id = pendingRemoval { queue.removeFinished(id) }
                pendingRemoval = nil
            }
            if let id = pendingRemoval,
               let item = queue.items.first(where: { $0.id == id }),
               item.phase == .completed, item.filePath != nil {
                Button("Move to Trash", role: .destructive) {
                    do { try queue.moveCompletedToTrash(id) }
                    catch { removalError = error.localizedDescription }
                    pendingRemoval = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Remove this download from the list, or move the completed file to your Mac's Trash? Removing from the list keeps the file.")
        }
        .alert("Could Not Delete File", isPresented: Binding(
            get: { removalError != nil },
            set: { if !$0 { removalError = nil } }
        )) {
            Button("OK") { removalError = nil }
        } message: {
            Text(removalError ?? "")
        }
        .onAppear {
            resetFormatToDefault()
        }
        .onChange(of: saveHistory) { _, enabled in
            if !enabled && isHistoryPage(page) { page = .home }
        }
        .onChange(of: reduceMotion) { _, enabled in
            if enabled { downloadsRevealStep = nil }
        }
        .task(id: downloadsRevealStep != nil) {
            guard downloadsRevealStep != nil else { return }
            await animateDownloadsReveal()
        }
        .onDisappear { downloadsRevealStep = nil }
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
                Text("Download FAF")
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.top, 12)
            VStack(spacing: 3) {
                ForEach(sidebarPages, id: \.self) { item in
                    Button {
                        guard saveHistory || !isHistoryPage(item) else { return }
                        page = item
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.icon)
                                .frame(width: 16)
                                .opacity(item == .downloads && !downloadsIconVisible ? 0 : 1)
                                .scaleEffect(item == .downloads && !downloadsIconVisible ? 0.75 : 1)
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                                           value: downloadsIconVisible)
                            // Reserve the complete label width so typing never shifts the badge.
                            Text(item.rawValue)
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(1)
                                .hidden()
                                .overlay(alignment: .leading) {
                                    Text(item == .downloads ? downloadsLabel : item.rawValue)
                                        .lineLimit(1)
                                }
                            Spacer(minLength: 0)
                            if item == .downloads && !activeItems.isEmpty {
                                Text("\(activeItems.count)")
                                    .font(.system(size: 9, weight: .medium))
                                    .fixedSize()
                                    .padding(.horizontal, 4)
                                    .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                                    .opacity(downloadsRevealStep == nil ? 1 : 0)
                            }
                        }
                        .font(.system(size: 11, weight: page == item ? .semibold : .regular))
                        .foregroundStyle(page == item ? accent : Color.secondary)
                        .opacity(!saveHistory && isHistoryPage(item) ? 0.35 : 1)
                        .padding(.horizontal, 9)
                        .frame(height: 31)
                        .background(page == item ? Color(nsColor: .controlBackgroundColor) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled((item == .downloads && downloadsRevealStep != nil) || (!saveHistory && isHistoryPage(item)))
                    .accessibilityLabel(item.rawValue)
                    .accessibilityHidden((item == .downloads && downloadsRevealStep != nil) || (!saveHistory && isHistoryPage(item)))
                    .transition(.identity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: downloadsVisible)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: 175)
        .background(Color(nsColor: .underPageBackgroundColor))
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
        GeometryReader { geometry in
            ScrollView(.vertical) {
                homeContent
                    .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
    }

    private var homeContent: some View {
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
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))

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
                    .fixedSize(horizontal: false, vertical: true)
            } else if !isAnalyzing {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 28, weight: .ultraLight)).foregroundStyle(accent)
                    Text("Ready for your next download")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Paste a link to preview the video.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 110, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
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
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func videoCard(_ info: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                thumbnail(info.thumbnail, width: 160, height: 112, audio: false)
                    .overlay(alignment: .bottomTrailing) {
                        if let duration = info.duration {
                            Text(durationText(duration))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
                                .padding(6)
                        }
                    }

                VStack(alignment: .leading, spacing: 9) {
                    Text(info.title)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(info.uploader ?? "Unknown creator")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button {
                        if let url = URL(string: analyzedURL) { NSWorkspace.shared.open(url) }
                    } label: {
                        Label("Open original", systemImage: "arrow.up.right.square")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .help("Open original video")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)

                VStack(spacing: 9) {
                    Picker("Type", selection: $selectedTab) {
                        Text("Video").tag(0)
                        Text("Audio").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: selectedTab) { _, newValue in
                        format = newValue == 1 ? "MP3" : "MP4"
                        selectedHeight = newValue == 1 ? nil : video?.qualities(for: "MP4").first?.height
                    }

                    HStack(spacing: 6) {
                        Picker("Format", selection: $format) {
                            ForEach(isAudio ? ["MP3", "M4A"] : ["MP4", "WebM"], id: \.self) { item in
                                Text(item).tag(item)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 75)

                        if !isAudio {
                            Picker("Quality", selection: $selectedHeight) {
                                ForEach(qualities) { quality in
                                    Text("\(quality.name) · \(quality.sizeText)")
                                        .tag(Optional(quality.height))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 29)

                    Button(action: addToQueue) {
                        Label("Download", systemImage: "arrow.down.to.line")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 31)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(!canStart)
                }
                .frame(width: 194)
            }

            Button(action: chooseFolder) {
                Label(URL(fileURLWithPath: folder).lastPathComponent, systemImage: "folder")
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Choose download folder")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
    }

    private var downloadsPage: some View {
        responsivePage { availableHeight in
            VStack(alignment: .leading, spacing: 12) {
                if queue.items.isEmpty {
                    emptyLibrary("No downloads yet", icon: "arrow.down.circle", minimumHeight: availableHeight)
                } else {
                    ForEach(queue.items.reversed()) { item in
                        queueRow(item)
                    }
                }
            }
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
                    if item.phase == .completed {
                        if let size = item.fileSize {
                            Text("· " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        }
                        if let completedAt = item.completedAt {
                            Text("· " + completedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            if item.phase == .completed, let path = item.filePath {
                let fileURL = URL(fileURLWithPath: path)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Image(systemName: "folder")
                }
                .disabled(!FileManager.default.fileExists(atPath: path))
                .help("Show in Finder")
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
                Button {
                    if item.phase == .completed {
                        pendingRemoval = item.id
                    } else {
                        queue.removeFinished(item.id)
                    }
                } label: { Image(systemName: "trash") }.help("Remove download")
            }
        }
        .buttonStyle(.plain).padding(9)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private func libraryPage(audio: Bool) -> some View {
        let filtered = history.items.filter { item in
            let isAudioFile = item.format == "MP3" || item.format == "M4A"
            return isAudioFile == audio
        }
        return responsivePage { availableHeight in
            VStack(alignment: .leading, spacing: 12) {
                if filtered.isEmpty {
                    emptyLibrary(audio ? "No audio downloads yet" : "No video downloads yet", icon: audio ? "music.note" : "film", minimumHeight: availableHeight)
                } else {
                    ForEach(filtered) { item in historyRow(item) }
                }
            }
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
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    // ScrollView proposes an unbounded height. Supply its viewport as a minimum,
    // so empty cards fill it while longer content can still scroll naturally.
    private func responsivePage<Content: View>(
        @ViewBuilder content: @escaping (CGFloat) -> Content
    ) -> some View {
        GeometryReader { geometry in
            let availableHeight = max(0, geometry.size.height - 24)
            ScrollView(.vertical) {
                content(availableHeight)
                    .frame(maxWidth: .infinity, minHeight: availableHeight, alignment: .top)
                    .padding(12)
            }
        }
    }

    private func emptyLibrary(_ message: String, icon: String, minimumHeight: CGFloat) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 38, weight: .ultraLight)).foregroundStyle(accent)
            Text(message).font(.system(size: 15, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: minimumHeight)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private var settingsPage: some View {
        SettingsView(history: history)
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
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
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

        guard let ytDLP = VideoEngine.toolPath else {
            return (nil, VideoEngine.missingYTDLP)
        }
        guard VideoEngine.ffmpegPath != nil else {
            return (nil, VideoEngine.missingFFmpeg)
        }

        let process = Process()
        process.environment = VideoEngine.processEnvironment

        let outputPipe = Pipe()

        let errorPipe = Pipe()

        process.executableURL = URL(

            fileURLWithPath: ytDLP

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

    private func revealDownloadsAfterAcceptance() {
        guard !hasRevealedDownloads else { return }
        downloadsRevealStep = reduceMotion ? nil : 0
        // Reveal once per app session; a fresh launch starts hidden when the queue is empty.
        hasRevealedDownloads = true
    }

    @MainActor
    private func animateDownloadsReveal() async {
        do {
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            downloadsRevealStep = 1
            try await Task.sleep(for: .milliseconds(150))
            for count in 1...Page.downloads.rawValue.count {
                try await Task.sleep(for: .milliseconds(50))
                try Task.checkCancellation()
                downloadsRevealStep = count + 1
            }
            downloadsRevealStep = nil
        } catch {
            // A disappearing view or Reduce Motion change settles the item for this session.
            downloadsRevealStep = nil
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
        revealDownloadsAfterAcceptance()
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
