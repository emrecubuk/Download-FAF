
import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case home = "Home"
    case downloads = "Downloads"
    case history = "History"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: "house"
        case .downloads: "arrow.down.circle"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: AppPage?

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                ForEach(AppPage.allCases) { page in
                    Label(page.rawValue, systemImage: page.icon)
                        .tag(page)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Download AF")
        .frame(minWidth: 180)
    }
}
