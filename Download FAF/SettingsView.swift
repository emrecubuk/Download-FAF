import SwiftUI
import ServiceManagement
import UserNotifications
import Observation
import OSLog

enum AppPreferences {
    static let saveHistory = "DownloadFAF.SaveHistory"
    static let completionNotifications = "DownloadFAF.CompletionNotifications"
    static let failureNotifications = "DownloadFAF.FailureNotifications"
    static let theme = "DownloadFAF.Theme"
    static let keepInMenuBar = "DownloadFAF.KeepInMenuBar"

    static func enabled(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppCache {
    @MainActor
    static func clear(networkCache: URLCache = .shared) async -> String {
        let beforeMemory = networkCache.currentMemoryUsage
        let beforeDisk = networkCache.currentDiskUsage
        let originalMemoryCapacity = networkCache.memoryCapacity
        let originalDiskCapacity = networkCache.diskCapacity

        // Use a unique, local test entry without making any network request.
        let probeURL = URL(string: "https://download-faf.invalid/cache-test/\(UUID().uuidString)")!
        let request = URLRequest(url: probeURL)
        let response = HTTPURLResponse(
            url: probeURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Cache-Control": "public, max-age=3600"]
        )!
        let cached = CachedURLResponse(response: response, data: Data("test".utf8))
        networkCache.storeCachedResponse(cached, for: request)
        let probeStored = networkCache.cachedResponse(for: request) != nil

        networkCache.removeAllCachedResponses()
        networkCache.memoryCapacity = 0
        networkCache.diskCapacity = 0
        try? await Task.sleep(for: .milliseconds(500))

        let probeRemovedWhileDisabled = networkCache.cachedResponse(for: request) == nil
        networkCache.memoryCapacity = originalMemoryCapacity
        networkCache.diskCapacity = originalDiskCapacity
        try? await Task.sleep(for: .milliseconds(500))

        let probeRemovedAfterRestore = networkCache.cachedResponse(for: request) == nil
        let afterMemory = networkCache.currentMemoryUsage
        let afterDisk = networkCache.currentDiskUsage

        func size(_ bytes: Int) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }

        let verification: String
        if !probeStored {
            verification = "Test entry could not be stored; removal cannot be verified."
        } else if probeRemovedWhileDisabled && probeRemovedAfterRestore {
            verification = "Test entry removed and still absent after cache capacity was restored."
        } else {
            verification = "Test entry is still accessible; removal could not be verified."
        }

        return """
        Network cache cleanup requested.

        \(verification)

        Memory: \(size(beforeMemory)) → \(size(afterMemory))
        Disk: \(size(beforeDisk)) → \(size(afterDisk))

        Cache capacities were temporarily set to zero and restored. Disk usage can remain unchanged even after entries are removed. This test only verifies the test entry, not every cached response.

        Downloads, history, settings and the active queue were not changed.
        """
    }
}

@MainActor
@Observable
final class DownloadNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DownloadNotifications()
    private(set) var permissionMessage = ""
    private(set) var lastError: String?
    @ObservationIgnored private var authorizationTask: Task<Bool, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DownloadFAF", category: "Notifications")

    private override init() {
        super.init()
    }

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .denied:
            permissionMessage = "Notifications are blocked in macOS System Settings → Notifications → Download FAF. Your preferences below are still saved."
        case .notDetermined:
            permissionMessage = "macOS will ask for permission when a notification is first needed."
        default:
            permissionMessage = "Delivery follows your macOS notification settings and Focus mode."
        }
    }

    func authorizeIfNeeded() async -> Bool {
        if let authorizationTask { return await authorizationTask.value }
        let task = Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                do {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                } catch {
                    lastError = "Notification permission could not be requested: \(error.localizedDescription)"
                    logger.error("Authorization failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            await refreshAuthorization()
            let status = await center.notificationSettings().authorizationStatus
            return status == .authorized || status == .provisional
        }
        authorizationTask = task
        let allowed = await task.value
        authorizationTask = nil
        return allowed
    }

    func send(
        id: UUID,
        title: String,
        succeeded: Bool,
        thumbnailURL: String? = nil
    ) async {
        let key = succeeded
            ? AppPreferences.completionNotifications
            : AppPreferences.failureNotifications

        guard AppPreferences.enabled(key) else { return }

        configure()

        guard await authorizeIfNeeded(),
              AppPreferences.enabled(key) else { return }

        let content = UNMutableNotificationContent()

        content.title = succeeded
            ? "Download Complete"
            : "Download Failed"

        content.body = succeeded
            ? "\(title.isEmpty ? "Your download" : title) finished successfully."
            : "\(title.isEmpty ? "Your download" : title) could not be downloaded. Open Downloads for details or to retry."

        content.sound = .default

        if succeeded,
           let thumbnailURL,
           let url = URL(string: thumbnailURL),
           ["https", "http"].contains(url.scheme?.lowercased() ?? "") {

            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 10

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let response = response as? HTTPURLResponse,
                      (200...299).contains(response.statusCode),
                      data.count <= 5_000_000,
                      let image = NSImage(data: data),
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let jpeg = bitmap.representation(
                        using: .jpeg,
                        properties: [.compressionFactor: 0.85]
                      )
                else {
                    throw NSError(
                        domain: "DownloadFAF",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Invalid thumbnail image."
                        ]
                    )
                }

                let attachmentURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "DownloadFAF-\(id.uuidString).jpg"
                    )

                try jpeg.write(to: attachmentURL, options: .atomic)

                let attachment = try UNNotificationAttachment(
                    identifier: "video-thumbnail",
                    url: attachmentURL
                )

                content.attachments = [attachment]

            } catch {
                logger.warning(
                    "Thumbnail attachment failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: id.uuidString,
                    content: content,
                    trigger: nil
                )
            )

            lastError = nil

        } catch {
            lastError = "A download notification could not be delivered: \(error.localizedDescription)"

            logger.error(
                "Delivery failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

struct SettingsView: View {
    @ObservedObject var history: DownloadHistoryStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppPreferences.saveHistory) private var saveHistory = true
    @AppStorage(AppPreferences.completionNotifications) private var completionNotifications = true
    @AppStorage(AppPreferences.failureNotifications) private var failureNotifications = true
    @AppStorage(AppPreferences.theme) private var theme: AppTheme = .system
    @AppStorage(AppPreferences.keepInMenuBar) private var keepInMenuBar = false
    @State private var loginEnabled = false
    @State private var loginBusy = false
    @State private var loginMessage: String?
    @State private var loginNeedsApproval = false
    @State private var confirmHistory = false
    @State private var confirmCache = false
    @State private var isClearingCache = false
    @State private var feedback: String?
    @StateObject private var dependencies = DependencyManager.shared
    private let notifications = DownloadNotifications.shared
    private var accent: Color {
        colorScheme == .dark ? Color(nsColor: .systemBlue) : Color(red: 0.12, green: 0.42, blue: 0.94)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                generalSection
                privacySection
                notificationsSection
                dependenciesSection
                appearanceSection
            }
            .padding(12)
        }
        .tint(accent)
        .task {
            refreshLoginStatus()
            await notifications.refreshAuthorization()
            await dependencies.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshLoginStatus()
                Task { await notifications.refreshAuthorization() }
            }
        }
        .onChange(of: completionNotifications) { _, enabled in
            if enabled { Task { _ = await notifications.authorizeIfNeeded() } }
        }
        .onChange(of: failureNotifications) { _, enabled in
            if enabled { Task { _ = await notifications.authorizeIfNeeded() } }
        }
        .alert("Homebrew Required", isPresented: $dependencies.showHomebrewPrompt) {
            Button("Cancel", role: .cancel) {}
            Button("Install Homebrew") { dependencies.installHomebrewWithConsent() }
        } message: {
            Text("Download FAF uses Homebrew to install yt-dlp and FFmpeg. Homebrew is not installed. Would you like to start the official Homebrew installer? Initial setup may require Terminal and an administrator password.")
        }
        .confirmationDialog("Clear download history?", isPresented: $confirmHistory, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                let count = history.items.count
                history.clear()
                feedback = count == 0 ? "There is no saved download history to clear." : "Download history cleared. Downloaded files and active downloads were not changed."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes saved records only. Downloaded files and the active queue will be kept.")
        }
        .confirmationDialog("Clear application cache?", isPresented: $confirmCache, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) {
                isClearingCache = true
                Task {
                    feedback = await AppCache.clear()
                    isClearingCache = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only this app’s cached network responses will be removed. Download files, yt-dlp temporary files, history, and preferences will be kept.")
        }
        .alert("Download FAF", isPresented: Binding(
            get: { feedback != nil },
            set: { if !$0 { feedback = nil } }
        )) {
            Button("OK") { feedback = nil }
        } message: {
            Text(feedback ?? "")
        }
    }

    private var generalSection: some View {
        section("General", icon: "gearshape") {
            row("Launch at Login", description: "Automatically launch Download FAF when you log in to your Mac.") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { loginEnabled },
                    set: { value in Task { await setLoginEnabled(value) } }
                ))
                .labelsHidden()
                .disabled(loginBusy)
            }

            // Login item feedback belongs to Launch at Login, not Keep in Menu Bar.
            if let loginMessage {
                status(loginMessage)
            }
            if loginNeedsApproval {
                Button("Open Login Items Settings") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }

            Divider()

            row("Keep in Menu Bar", description: "Keep Download FAF available for quick downloads after closing its window.") {
                Toggle("Keep in Menu Bar", isOn: $keepInMenuBar)
                    .labelsHidden()
            }
        }
    }

    private var privacySection: some View {
        section("Privacy & Storage", icon: "lock.shield") {
                    row("Save Download History", description: "Keep a record of your completed downloads.") {
                        Toggle("Save Download History", isOn: $saveHistory).labelsHidden()
                    }
                    Divider()
                    row("Clear Download History", description: "Remove saved download records without deleting downloaded files.") {
                        Button("Clear Download History") { confirmHistory = true }
                    }
                    Divider()
                    row("Clear Cache", description: "Clear cached network responses used by the application.") {
                        Button("Clear Cache") { confirmCache = true }
                            .disabled(isClearingCache)
                    }
                }
    }

    private var notificationsSection: some View {
        section("Notifications", icon: "bell") {
                    row("Completion Notifications", description: "Notify me when a download finishes successfully.") {
                        Toggle("Completion Notifications", isOn: $completionNotifications).labelsHidden()
                    }
                    Divider()
                    row("Failure Notifications", description: "Notify me when a download fails.") {
                        Toggle("Failure Notifications", isOn: $failureNotifications).labelsHidden()
                    }
                    status(notifications.permissionMessage)
                    if let error = notifications.lastError { status(error) }
                }
    }

    private var dependenciesSection: some View {
        section("Dependencies", icon: "shippingbox") {
            row("yt-dlp", description: dependencies.ytDLPStatus) {
                Image(systemName: VideoEngine.toolPath == nil ? "xmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(VideoEngine.toolPath == nil ? Color.secondary : Color.green)
            }
            HStack(spacing: 10) {
                Button("Install") { Task { await dependencies.install("yt-dlp") } }
                    .disabled(dependencies.ytDLPBusy || dependencies.ytDLPInstalledByBrew)
                Button("Check & Update") { Task { await dependencies.checkAndUpdate("yt-dlp") } }
                    .disabled(dependencies.ytDLPBusy)
                if dependencies.ytDLPBusy { ProgressView().controlSize(.small) }
            }
            status(dependencies.ytDLPMessage)

            Divider()

            row("FFmpeg", description: dependencies.ffmpegStatus) {
                Image(systemName: VideoEngine.ffmpegPath == nil ? "xmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(VideoEngine.ffmpegPath == nil ? Color.secondary : Color.green)
            }
            HStack(spacing: 10) {
                Button("Install") { Task { await dependencies.install("ffmpeg") } }
                    .disabled(dependencies.ffmpegBusy || dependencies.ffmpegInstalledByBrew)
                Button("Check & Update") { Task { await dependencies.checkAndUpdate("ffmpeg") } }
                    .disabled(dependencies.ffmpegBusy)
                if dependencies.ffmpegBusy { ProgressView().controlSize(.small) }
            }
            status(dependencies.ffmpegMessage)
            status("Homebrew manages installations and updates. Existing tools outside Homebrew are preserved.")
        }
    }

    private var appearanceSection: some View {
        section("Appearance", icon: "circle.lefthalf.filled") {
                    row("Theme", description: "Choose how Download FAF appears.") {
                        Picker("Theme", selection: Binding(
                            get: { theme },
                            set: { newTheme in
                                guard newTheme != theme else { return }
                                NotificationCenter.default.post(
                                    name: .downloadFAFThemeWillChange,
                                    object: nil
                                )
                                theme = newTheme
                            }
                        )) {
                            ForEach(AppTheme.allCases) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }

                }
    }

    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
    }

    private func row<Control: View>(_ title: String, description: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(description).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .fixedSize()
                .accessibilityLabel(title)
                .accessibilityHint(description)
        }
    }

    private func status(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled
        loginNeedsApproval = status == .requiresApproval
        switch status {
        case .requiresApproval:
            loginMessage = "Launch at Login is not enabled. Allow Download FAF in macOS Login Items."
        case .notFound:
            // A missing login item is normal for an Xcode development build.
            // Do not show an error until the user actually tries to enable it.
            loginMessage = nil
        default:
            loginMessage = nil
        }
    }

    private func setLoginEnabled(_ enabled: Bool) async {
        guard !loginBusy else { return }
        loginBusy = true
        defer { loginBusy = false }
        do {
            if enabled {
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                } else if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try await SMAppService.mainApp.unregister()
            }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            loginMessage = "Could not change Launch at Login: \(error.localizedDescription). Development builds may need to be signed and installed in Applications."
        }
    }
}


