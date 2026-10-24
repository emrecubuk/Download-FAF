
import SwiftUI
import AppKit

@main
struct Download_FAFApp: App {
    init() {
        DownloadNotifications.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            ThemeRootView()
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 720, height: 300)
        .windowResizability(.contentMinSize)
    }
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
