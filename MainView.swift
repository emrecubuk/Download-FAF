import SwiftUI

struct MainView: View {
    @State private var selectedPage: AppPage? = .home

    private let background = Color(
        red: 0.035,
        green: 0.045,
        blue: 0.095
    )

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedPage)
                .background(background)
        } detail: {
            ZStack {
                background
                    .ignoresSafeArea()

                GeometryReader { geometry in
                    ZStack {
                        Circle()
                            .fill(
                                Color.purple.opacity(0.25)
                            )
                            .frame(width: 450, height: 450)
                            .blur(radius: 130)
                            .offset(
                                x: geometry.size.width * 0.25,
                                y: -geometry.size.height * 0.35
                            )

                        Circle()
                            .fill(
                                Color.blue.opacity(0.20)
                            )
                            .frame(width: 400, height: 400)
                            .blur(radius: 120)
                            .offset(
                                x: -geometry.size.width * 0.35,
                                y: geometry.size.height * 0.30
                            )

                        Circle()
                            .fill(
                                Color.pink.opacity(0.15)
                            )
                            .frame(width: 300, height: 300)
                            .blur(radius: 110)
                            .offset(
                                x: geometry.size.width * 0.40,
                                y: geometry.size.height * 0.35
                            )
                    }
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )
                    .clipped()
                }
                .allowsHitTesting(false)

                Group {
                    switch selectedPage {
                    case .home:
                        HomeView()

                    case .downloads:
                        placeholder(
                            title: "Downloads",
                            icon: "arrow.down.circle",
                            message: "Your downloads will appear here."
                        )

                    case .history:
                        placeholder(
                            title: "History",
                            icon: "clock.arrow.circlepath",
                            message: "Your download history will appear here."
                        )

                    case .settings:
                        placeholder(
                            title: "Settings",
                            icon: "gearshape",
                            message: "Customize Download FAF."
                        )

                    case nil:
                        ContentView()
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(.dark)
        .tint(
            Color(
                red: 0.68,
                green: 0.30,
                blue: 1.0
            )
        )
    }

    private func placeholder(
        title: String,
        icon: String,
        message: String
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.purple, .pink, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)

            Text(message)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
    }
}

#Preview {
    MainView()
}
