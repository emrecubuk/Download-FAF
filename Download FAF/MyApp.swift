import SwiftUI

import AppKit
import Combine



final class DownloadFAFAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem?

    private var popover: NSPopover?

    private var defaultsObserver: NSObjectProtocol?
    private var appliedMenuBarState: Bool?
    private var isUpdatingMenuBar = false



    func applicationDidFinishLaunching(_ notification: Notification) {

        defaultsObserver = NotificationCenter.default.addObserver(

            forName: UserDefaults.didChangeNotification,

            object: nil,

            queue: .main

        ) { [weak self] _ in

            self?.updateMenuBar()

        }

        DispatchQueue.main.async { [weak self] in
            self?.updateMenuBar()
        }

    }



    func applicationWillTerminate(_ notification: Notification) {

        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }

    }



    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {

        !UserDefaults.standard.bool(forKey: AppPreferences.keepInMenuBar)

    }



    private func updateMenuBar() {
        guard !isUpdatingMenuBar else { return }
        let enabled = UserDefaults.standard.bool(forKey: AppPreferences.keepInMenuBar)
        guard appliedMenuBarState != enabled || (enabled && statusItem == nil) else { return }

        isUpdatingMenuBar = true
        defer { isUpdatingMenuBar = false }

        if enabled {
            guard statusItem == nil else { appliedMenuBarState = true; return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem = item
            item.button?.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Download FAF")
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            appliedMenuBarState = true
        } else {
            popover?.close()
            popover = nil
            if let statusItem {
                self.statusItem = nil
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            appliedMenuBarState = false
        }
    }

    @objc private func togglePopover(_ sender: Any?) {

        guard let button = statusItem?.button else { return }

        if popover?.isShown == true {

            popover?.close()

            return

        }

        if popover == nil {

            let panel = NSPopover()

            panel.behavior = .transient

            panel.contentSize = NSSize(width: 390, height: 320)

            panel.contentViewController = NSHostingController(rootView: QuickDownloadView())

            panel.delegate = self

            popover = panel

        }

        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

    }

}



@main

struct Download_FAFApp: App {

    @NSApplicationDelegateAdaptor(DownloadFAFAppDelegate.self) private var appDelegate



    init() {

        DownloadNotifications.shared.configure()

    }



    var body: some Scene {

        WindowGroup(id: "main") {

            ThemeRootView()

        }

        .windowToolbarStyle(.unifiedCompact)

        .defaultSize(width: 720, height: 300)

        .windowResizability(.contentMinSize)

    }

}




@MainActor
final class SharedAnalysisState: ObservableObject {
    static let shared = SharedAnalysisState()

    @Published private(set) var url = ""
    @Published private(set) var video: VideoInfo?
    @Published private(set) var format = "MP4"
    @Published private(set) var qualityHeight: Int?

    private var sizeVerificationTask: Task<Void, Never>?
    private var analysisID = UUID()

    func publish(
        url: String,
        video: VideoInfo,
        format: String,
        qualityHeight: Int?
    ) {
        sizeVerificationTask?.cancel()

        let currentID = UUID()
        analysisID = currentID

        self.url = url
        self.format = format
        self.qualityHeight = qualityHeight
        self.video = video

        guard video.verifiedSizes == nil else {
            return
        }

        sizeVerificationTask = Task(priority: .utility) {
            let verified = await VideoEngine.verifySizes(in: video)

            guard !Task.isCancelled,
                  self.analysisID == currentID,
                  self.url == url else {
                return
            }

            self.video = verified
            self.sizeVerificationTask = nil
        }
    }

    func updateSelection(
        format: String,
        qualityHeight: Int?
    ) {
        guard video != nil else {
            return
        }

        if self.format != format {
            self.format = format
        }

        if self.qualityHeight != qualityHeight {
            self.qualityHeight = qualityHeight
        }
    }

    func clear() {
        sizeVerificationTask?.cancel()
        sizeVerificationTask = nil

        analysisID = UUID()

        url = ""
        video = nil
        qualityHeight = nil
    }
}

@MainActor
private struct QuickDownloadView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var sharedAnalysis = SharedAnalysisState.shared
    @ObservedObject private var queue = DownloadServices.shared.queue
    @AppStorage("DownloadFAF.DefaultFolder") private var storedFolder = ""
    @State private var link = ""
    @State private var info: VideoInfo?
    @State private var analyzedLink = ""
    @State private var format = "MP4"
    @State private var qualityHeight: Int?
    @State private var analyzing = false
    @State private var errorMessage: String?

    private var folder: String {
        storedFolder.isEmpty
            ? (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory())
            : storedFolder
    }

    private var qualities: [VideoQuality] { info?.qualities(for: format) ?? [] }
    private var selectedQuality: VideoQuality? { qualities.first { $0.height == qualityHeight } }
    private var audio: Bool { format == "MP3" || format == "M4A" }
    private var trimmedLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canDownload: Bool {
        info != nil && !analyzing && analyzedLink == trimmedLink && (audio || selectedQuality != nil)
    }
    private var activeItems: [QueueItem] {
        queue.items.filter { [.queued, .downloading, .paused, .cancelling].contains($0.phase) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            linkSection
            if analyzing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing link...").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if let info { preview(info) }
            optionsSection
            destinationSection
            downloadButton
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !activeItems.isEmpty { activitySection }
        }
        .padding(16)
        .frame(width: 390)
        .onAppear(perform: receiveSharedAnalysis)
        .onReceive(sharedAnalysis.$video.dropFirst()) { _ in
            DispatchQueue.main.async { receiveSharedAnalysis() }
        }
        .onReceive(sharedAnalysis.$format.dropFirst()) { _ in
            DispatchQueue.main.async { receiveSharedAnalysis() }
        }
        .onReceive(sharedAnalysis.$qualityHeight.dropFirst()) { _ in
            DispatchQueue.main.async { receiveSharedAnalysis() }
        }
        .onChange(of: format) { _, _ in publishSelection() }
        .onChange(of: qualityHeight) { _, _ in publishSelection() }
    }

    private var linkSection: some View {
        HStack(spacing: 8) {
            Button {
                openApp()
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Open Download FAF")
            Image(systemName: "link")
                .foregroundStyle(.secondary)
            TextField("Paste a video URL", text: $link)
                .textFieldStyle(.plain)
                .onSubmit { if !trimmedLink.isEmpty && !analyzing { analyze() } }
                .onChange(of: link) { _, _ in
                    guard trimmedLink != analyzedLink else { return }
                    info = nil
                    analyzedLink = ""
                    errorMessage = nil
                }
            Button {
                if let value = NSPasteboard.general.string(forType: .string) { link = value }
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .help("Paste from clipboard")
            Button("Analyze") { analyze() }
                .buttonStyle(.bordered)
                .disabled(analyzing || trimmedLink.isEmpty)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func preview(_ video: VideoInfo) -> some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail = video.thumbnail, let url = URL(string: thumbnail) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "play.rectangle").foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "play.rectangle").foregroundStyle(.secondary)
                }
            }
            .frame(width: 86, height: 52)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title).font(.subheadline.weight(.medium)).lineLimit(2)
                Text(video.uploader ?? "Unknown creator")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var optionsSection: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("FORMAT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Format", selection: $format) {
                    ForEach(["MP4", "WebM", "MP3", "M4A"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .onChange(of: format) { _, _ in qualityHeight = qualities.first?.height }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("QUALITY").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if audio {
                    Text("Best audio")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 24)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Quality", selection: $qualityHeight) {
                        Text(info == nil ? "Auto after analysis" : "Unavailable")
                            .tag(nil as Int?)
                        ForEach(qualities) { quality in
                            Text("\(quality.name) · \(quality.sizeText)").tag(Optional(quality.height))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .disabled(info == nil || qualities.isEmpty)
                }
            }
        }
    }

    private var destinationSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(URL(fileURLWithPath: folder).lastPathComponent)
                .font(.caption).lineLimit(1)
            Spacer()
            Button("Change") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let url = panel.url { storedFolder = url.path }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private var downloadButton: some View {
        Button(action: download) {
            Label("Download Now", systemImage: "arrow.down.to.line")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canDownload)
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("ACTIVE DOWNLOADS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(activeItems.count) active").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(activeItems.prefix(2)) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(item.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(Int(item.progress * 100))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                        if item.phase == .downloading {
                            Button { queue.pause(item.id) } label: { Image(systemName: "pause.fill") }
                                .help("Pause")
                        } else if item.phase == .paused {
                            Button { queue.resume(item.id) } label: { Image(systemName: "play.fill") }
                                .help("Resume")
                        }
                        Button { queue.cancel(item.id) } label: { Image(systemName: "xmark") }
                            .help("Cancel download")
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    ProgressView(value: item.progress)
                    HStack {
                        Text(item.phase.rawValue)
                        Spacer()
                        Text(item.speed)
                        Text("ETA: \(item.eta)")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func receiveSharedAnalysis() {
        guard let video = sharedAnalysis.video else { return }
        analyzedLink = sharedAnalysis.url
        link = sharedAnalysis.url
        info = video
        format = sharedAnalysis.format
        let available = video.qualities(for: format)
        let requested = sharedAnalysis.qualityHeight
        qualityHeight = available.first(where: { $0.height == requested })?.height ?? available.first?.height
        errorMessage = nil
    }

    private func publishSelection() {
        guard info != nil, analyzedLink == sharedAnalysis.url else { return }
        guard sharedAnalysis.format != format || sharedAnalysis.qualityHeight != qualityHeight else { return }
        sharedAnalysis.updateSelection(format: format, qualityHeight: qualityHeight)
    }

    private func openApp(page: String? = nil) {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        }
        if let page {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .downloadFAFOpenPage, object: page)
            }
        }
    }

    private func analyze() {
        let urlString = trimmedLink
        guard let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            errorMessage = "Enter a valid URL."
            return
        }
        guard let ytDLP = VideoEngine.toolPath else { errorMessage = VideoEngine.missingYTDLP; return }
        guard VideoEngine.ffmpegPath != nil else { errorMessage = VideoEngine.missingFFmpeg; return }
        analyzing = true
        errorMessage = nil
        info = nil
        Task {
            let result: Result<VideoInfo, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: ytDLP)
                    process.environment = VideoEngine.processEnvironment
                    process.arguments = ["--dump-single-json", "--skip-download", "--no-playlist", "--no-warnings", urlString]
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw QuickDownloadError.analysisFailed }
                    let decoded = try JSONDecoder().decode(VideoInfo.self, from: data)
                    return .success(decoded)
                } catch { return .failure(error) }
            }.value
            analyzing = false
            guard trimmedLink == urlString else { return }
            switch result {
            case .success(let value):
                info = value
                analyzedLink = urlString
                qualityHeight = value.qualities(for: format).first?.height
                sharedAnalysis.publish(url: urlString, video: value, format: format, qualityHeight: qualityHeight)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func download() {
        guard canDownload, let info else { return }
        let url = analyzedLink
        var arguments = VideoEngine.downloadArguments(
            url: url, folder: folder, quality: audio ? nil : selectedQuality, format: format
        )
        arguments.insert(contentsOf: ["--print", "after_move:FAF_FINAL_PATH:%(filepath)s"], at: max(0, arguments.count - 1))
        let job = DownloadJob(url: url, folder: folder, format: format,
                              qualityName: audio ? "Audio" : selectedQuality?.name ?? "Video",
                              arguments: arguments)
        queue.add(job: job, info: info)
        sharedAnalysis.clear()
        link = ""
        self.info = nil
        analyzedLink = ""
        errorMessage = nil
    }
}

private enum QuickDownloadError: LocalizedError {

    case analysisFailed

    var errorDescription: String? { "Could not analyze this link. Check the URL or open the main app for details." }

}



private struct ThemeRootView: View {

    @AppStorage("DownloadFAF.Theme")

    private var storedTheme = AppTheme.system.rawValue



    @State private var previousScreen: NSImage?

    @State private var revealProgress: CGFloat = 0

    @State private var transitionID = UUID()



    var body: some View {

        ContentView()

            .overlay {

                if let previousScreen {

                    GeometryReader { geometry in

                        Image(nsImage: previousScreen)

                            .resizable()

                            .frame(width: geometry.size.width, height: geometry.size.height)

                            .mask {

                                TornPaperMask(progress: revealProgress)

                            }

                            .allowsHitTesting(false)

                            .accessibilityHidden(true)

                    }

                    .id(transitionID)

                    .ignoresSafeArea()

                }

            }

            .onAppear {

                applyTheme()

            }

            .onReceive(NotificationCenter.default.publisher(for: .downloadFAFThemeWillChange)) { _ in

                captureCurrentAppearance()

            }

            .onChange(of: storedTheme) { _, _ in

                applyTheme()

                guard previousScreen != nil else { return }



                withAnimation(.easeInOut(duration: 0.78)) {

                    revealProgress = 1

                }



                let currentID = transitionID

                Task { @MainActor in

                    try? await Task.sleep(for: .milliseconds(850))

                    if transitionID == currentID {

                        previousScreen = nil

                        revealProgress = 0

                    }

                }

            }

    }



    private func captureCurrentAppearance() {

        guard let window = NSApp.keyWindow,

              let view = window.contentView,

              view.bounds.width > 0,

              view.bounds.height > 0,

              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)

        else {

            previousScreen = nil

            return

        }



        view.cacheDisplay(in: view.bounds, to: bitmap)

        let image = NSImage(size: view.bounds.size)

        image.addRepresentation(bitmap)



        transitionID = UUID()

        revealProgress = 0

        previousScreen = image

    }



    private func applyTheme() {

        switch AppTheme(rawValue: storedTheme) {

        case .light:

            NSApp.appearance = NSAppearance(named: .aqua)

        case .dark:

            NSApp.appearance = NSAppearance(named: .darkAqua)

        default:

            NSApp.appearance = nil

        }

    }

}



extension Notification.Name {

    static let downloadFAFThemeWillChange = Notification.Name("DownloadFAF.ThemeWillChange")

    static let downloadFAFOpenPage = Notification.Name("DownloadFAF.OpenPage")

}



private struct TornPaperMask: Shape {

    var progress: CGFloat



    var animatableData: CGFloat {

        get { progress }

        set { progress = newValue }

    }



    func path(in rect: CGRect) -> Path {

        let width = rect.width

        let height = rect.height

        let diagonal = hypot(width, height)

        let radius = max(0, progress) * (diagonal + 34)

        let roughness: CGFloat = 7



        var path = Path()

        path.move(to: CGPoint(x: 0, y: 0))

        path.addLine(to: CGPoint(x: width, y: 0))

        path.addLine(to: CGPoint(x: width, y: height - radius))



        let segments = 110

        for index in 0...segments {

            let fraction = CGFloat(index) / CGFloat(segments)

            let angle = -.pi / 2 - fraction * (.pi / 2)

            let edgeVariation =

                sin(fraction * 91) * roughness * 0.55 +

                sin(fraction * 207) * roughness * 0.25 +

                sin(fraction * 43) * roughness * 0.20

            let adjustedRadius = max(0, radius + edgeVariation * min(1, radius / 45))

            let point = CGPoint(

                x: width + cos(angle) * adjustedRadius,

                y: height + sin(angle) * adjustedRadius

            )

            path.addLine(to: point)

        }



        path.addLine(to: CGPoint(x: 0, y: height))

        path.closeSubpath()

        return path

    }

}
