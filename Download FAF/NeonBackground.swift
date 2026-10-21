import SwiftUI

struct NeonBackground: View {

    private let purple = Color(red: 0.75, green: 0.18, blue: 1.0)
    private let pink = Color(red: 1.0, green: 0.15, blue: 0.48)
    private let cyan = Color(red: 0.0, green: 0.65, blue: 1.0)

    private let animationSpeed = 0.75

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in

                let time = timeline.date.timeIntervalSinceReferenceDate

                Canvas { context, size in

                    drawBackground(
                        context: &context,
                        size: size
                    )

                    drawWave(
                        context: &context,
                        size: size,
                        time: time,
                        color: purple,
                        baseY: 0.28,
                        amplitude: 55,
                        phase: 0
                    )

                    drawWave(
                        context: &context,
                        size: size,
                        time: time,
                        color: pink,
                        baseY: 0.34,
                        amplitude: 45,
                        phase: 1.5
                    )

                    drawWave(
                        context: &context,
                        size: size,
                        time: time,
                        color: cyan,
                        baseY: 0.40,
                        amplitude: 50,
                        phase: 3.0
                    )
                }
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func drawBackground(
        context: inout GraphicsContext,
        size: CGSize
    ) {
        let rect = CGRect(origin: .zero, size: size)

        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.12, green: 0.02, blue: 0.17),
                    Color(red: 0.035, green: 0.025, blue: 0.09),
                    Color(red: 0.015, green: 0.07, blue: 0.16)
                ]),
                startPoint: .zero,
                endPoint: CGPoint(
                    x: size.width,
                    y: size.height
                )
            )
        )
    }

    private func drawWave(
        context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        color: Color,
        baseY: CGFloat,
        amplitude: CGFloat,
        phase: Double
    ) {
        var path = Path()

        let width = size.width
        let height = size.height

        let oscillation = sin(time * animationSpeed + phase)

        for x in stride(
            from: CGFloat.zero,
            through: width,
            by: 2
        ) {
            let normalizedX = Double(x / max(width, 1))

            let shape = sin(normalizedX * .pi * 3)

            let secondaryShape = sin(normalizedX * .pi * 5) * 0.15

            let movement = (shape + secondaryShape) * oscillation

            let y = height * baseY
                + amplitude * movement

            if x == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 20))

            glow.stroke(
                path,
                with: .color(color.opacity(0.35)),
                style: StrokeStyle(lineWidth: 14)
            )
        }

        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 7))

            glow.stroke(
                path,
                with: .color(color.opacity(0.65)),
                style: StrokeStyle(lineWidth: 6)
            )
        }

        context.stroke(
            path,
            with: .color(color.opacity(0.95)),
            style: StrokeStyle(
                lineWidth: 2,
                lineCap: .round,
                lineJoin: .round
            )
        )
    }
}

#Preview {
    NeonBackground()
        .frame(width: 1100, height: 700)
}
