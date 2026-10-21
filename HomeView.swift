import SwiftUI

struct HomeView: View {

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                NeonBackground()

                ViewThatFits(in: .vertical) {
                    homeContent
                        .frame(
                            maxWidth: .infinity,
                            alignment: .topLeading
                        )

                    ScrollView {
                        homeContent
                    }
                }
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .top
                )
            }
        }
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        GeometryReader { geometry in
            ZStack {
                Color(
                    red: 0.025,
                    green: 0.025,
                    blue: 0.065
                )

                Circle()
                    .fill(
                        Color.purple.opacity(0.45)
                    )
                    .frame(width: 500, height: 500)
                    .blur(radius: 160)
                    .offset(
                        x: -geometry.size.width * 0.35,
                        y: -geometry.size.height * 0.4
                    )

                Circle()
                    .fill(
                        Color.pink.opacity(0.35)
                    )
                    .frame(width: 450, height: 450)
                    .blur(radius: 150)
                    .offset(
                        x: geometry.size.width * 0.35,
                        y: -geometry.size.height * 0.4
                    )

                Circle()
                    .fill(
                        Color.blue.opacity(0.35)
                    )
                    .frame(width: 500, height: 500)
                    .blur(radius: 170)
                    .offset(
                        x: geometry.size.width * 0.35,
                        y: geometry.size.height * 0.3
                    )

                Circle()
                    .fill(
                        Color.indigo.opacity(0.25)
                    )
                    .frame(width: 400, height: 400)
                    .blur(radius: 150)
                    .offset(
                        x: -geometry.size.width * 0.3,
                        y: geometry.size.height * 0.35
                    )
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height
            )
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var homeContent: some View {
        ContentView()
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

#Preview {
    HomeView()
}
