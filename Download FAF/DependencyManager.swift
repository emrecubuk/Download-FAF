import Foundation
import Combine
import AppKit

@MainActor
final class DependencyManager: ObservableObject {
    static let shared = DependencyManager()

    @Published private(set) var ytDLPBusy = false
    @Published private(set) var ffmpegBusy = false
    @Published private(set) var ytDLPInstalledByBrew = false
    @Published private(set) var ffmpegInstalledByBrew = false
    @Published private(set) var ytDLPMessage = "Ready"
    @Published private(set) var ffmpegMessage = "Ready"
    @Published private(set) var message = "Ready"
    var busy: Bool { ytDLPBusy || ffmpegBusy }
    private let brewQueue = BrewOperationQueue()
    @Published private(set) var ytDLPStatus = "Checking..."
    @Published private(set) var ffmpegStatus = "Checking..."
    @Published var showHomebrewPrompt = false

    private init() {}

    private static let brewPaths = [
        "/opt/homebrew/bin/brew", "/usr/local/bin/brew", "/home/linuxbrew/.linuxbrew/bin/brew"
    ]

    private var brewPath: String? {
        Self.brewPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    func refresh() async {
        ytDLPStatus = await version(name: "yt-dlp", path: VideoEngine.toolPath)
        ffmpegStatus = await version(name: "ffmpeg", path: VideoEngine.ffmpegPath)
        await refreshBrewInstallStates()
    }

    private func refreshBrewInstallStates() async {
        guard let brew = brewPath else {
            ytDLPInstalledByBrew = false
            ffmpegInstalledByBrew = false
            return
        }
        for name in ["yt-dlp", "ffmpeg"] {
            let result = try? await Self.run(brew, ["list", "--versions", name], allowFailure: true)
            let installed = result?.status == 0 && !(result?.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if name == "yt-dlp" { ytDLPInstalledByBrew = installed }
            else { ffmpegInstalledByBrew = installed }
        }
    }

    func install(_ name: String) async { await perform(name: name, update: false) }
    func checkAndUpdate(_ name: String) async { await perform(name: name, update: true) }

    private func perform(name: String, update: Bool) async {
        guard ["yt-dlp", "ffmpeg"].contains(name) else { return }
        if name == "yt-dlp" {
            guard !ytDLPBusy else { return }
            ytDLPBusy = true
        } else {
            guard !ffmpegBusy else { return }
            ffmpegBusy = true
        }
        defer {
            if name == "yt-dlp" { ytDLPBusy = false }
            else { ffmpegBusy = false }
        }

        guard let brew = brewPath else {
            setMessage("Homebrew is not installed.", for: name)
            showHomebrewPrompt = true
            return
        }

        setMessage("Waiting for Homebrew...", for: name)
        await brewQueue.acquire()
        defer { Task { await brewQueue.release() } }

        do {
            setMessage("Checking \(name)...", for: name)
            let listing = try await Self.run(brew, ["list", "--versions", name], allowFailure: true)
            let installedByBrew = listing.status == 0 && !listing.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let existing = name == "yt-dlp" ? VideoEngine.toolPath : VideoEngine.ffmpegPath
            let resultMessage: String

            if installedByBrew {
                if update {
                    setMessage("Checking and updating \(name)...", for: name)
                    let result = try await Self.run(brew, ["upgrade", name])
                    let output = result.output.lowercased()
                    resultMessage = output.contains("already installed") || output.contains("already up-to-date") || output.contains("not outdated")
                        ? "\(name): already up to date"
                        : "\(name): update check completed"
                } else {
                    resultMessage = "\(name): already installed via Homebrew"
                }
            } else if update {
                resultMessage = existing == nil
                    ? "\(name) is not installed via Homebrew. Use Install to add it."
                    : "\(name): found outside Homebrew. Use Install to add a Homebrew-managed version; the existing copy will be preserved."
            } else {
                setMessage("Installing \(name) with Homebrew...", for: name)
                _ = try await Self.run(brew, ["install", name])
                resultMessage = "\(name): installed via Homebrew" + (existing == nil ? "" : ". Existing non-Homebrew copy preserved.")
            }
            if name == "yt-dlp" {
                ytDLPStatus = await version(name: name, path: VideoEngine.toolPath)
            } else {
                ffmpegStatus = await version(name: name, path: VideoEngine.ffmpegPath)
            }
            let verification = try? await Self.run(brew, ["list", "--versions", name], allowFailure: true)
            let confirmed = verification?.status == 0 && !(verification?.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if name == "yt-dlp" { ytDLPInstalledByBrew = confirmed }
            else { ffmpegInstalledByBrew = confirmed }
            setMessage(resultMessage, for: name)
        } catch {
            setMessage("Failed (\(name)): \(error.localizedDescription)", for: name)
        }
    }

    private func setMessage(_ text: String, for name: String) {
        if name == "yt-dlp" { ytDLPMessage = text }
        else { ffmpegMessage = text }
        message = text
    }

    /// The official Homebrew installer is interactive and may require an admin password.
    /// macOS cannot reliably run that installer silently in a background Process.
    func installHomebrewWithConsent() {
        showHomebrewPrompt = false
        guard brewPath == nil else {
            message = "Homebrew is already installed. Click Install Dependencies."
            return
        }
        let command = #"/bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
        let script = "tell application \"Terminal\" to activate\n" +
                     "tell application \"Terminal\" to do script \"" +
                     command.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try process.run()
            message = "Complete the official Homebrew installation in Terminal, then click Install Dependencies again."
        } catch {
            message = "Could not open Homebrew installer: \(error.localizedDescription)"
        }
    }

    private func version(name: String, path: String?) async -> String {
        guard let path else { return "Not installed" }
        do {
            let result = try await Self.run(path, name == "yt-dlp" ? ["--version"] : ["-version"])
            let firstLine = result.output.split(separator: "\n").first.map(String.init) ?? "Installed"
            return String(firstLine.prefix(90))
        } catch {
            return "Installed, but unable to read version"
        }
    }

    private struct RunResult: Sendable {
        let status: Int32
        let output: String
    }

    private struct CommandFailure: LocalizedError {
        let executable: String
        let arguments: [String]
        let status: Int32
        let output: String

        var errorDescription: String? {
            let detail = String(output.suffix(1200)).trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(executable) \(arguments.joined(separator: " ")) exited with code \(status). \(detail)"
        }
    }

    nonisolated private static func run(_ path: String, _ args: [String], allowFailure: Bool = false) async throws -> RunResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
            environment["HOMEBREW_NO_ENV_HINTS"] = "1"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let result = RunResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
            if !allowFailure && result.status != 0 {
                throw CommandFailure(executable: URL(fileURLWithPath: path).lastPathComponent, arguments: args, status: result.status, output: result.output)
            }
            return result
        }.value
    }
}

// Serializes Homebrew operations while keeping each tool's controls independent.
private actor BrewOperationQueue {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !occupied {
            occupied = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().resume() }
    }
}
