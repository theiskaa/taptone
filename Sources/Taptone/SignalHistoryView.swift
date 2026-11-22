import SwiftUI
import TaptoneCore

struct SignalHistoryView: View {
    let samples: [ActivityHistory.Sample]
    let isFrozen: Bool
    let emptyMessage: String

    @Environment(\.colorSchemeContrast) private var contrast
    private let inset: CGFloat = 14

    var body: some View {
        VStack(spacing: 7) {
            Canvas { context, size in
                let plot = CGRect(x: inset, y: 12, width: max(0, size.width - 2 * inset), height: max(0, size.height - 24))
                drawGrid(context, in: plot)
                drawSignal(context, in: plot)
            }
            .frame(minHeight: 126)
            .background(ActivityPalette.plot, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                if samples.isEmpty {
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            HStack {
                Text("−12 s")
                Spacer()
                Text("−6 s")
                Spacer()
                Text(isFrozen ? "End" : "Now")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, inset)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input and beat history, 12 seconds")
        .accessibilityValue(samples.isEmpty ? emptyMessage : (isFrozen ? "Last session" : "Updating"))
    }

    private func drawGrid(_ context: GraphicsContext, in plot: CGRect) {
        let baseline = plot.maxY - 18
        let path = Path { path in
            path.move(to: CGPoint(x: plot.minX, y: baseline))
            path.addLine(to: CGPoint(x: plot.maxX, y: baseline))
            for index in 1...3 {
                let x = plot.minX + plot.width * CGFloat(index) / 4
                path.move(to: CGPoint(x: x, y: plot.minY))
                path.addLine(to: CGPoint(x: x, y: baseline))
            }
        }
        let opacity = contrast == .increased ? 0.45 : (samples.isEmpty ? 0.12 : 0.22)
        context.stroke(path, with: .color(.secondary.opacity(opacity)), lineWidth: 0.75)
    }

    private func drawSignal(_ context: GraphicsContext, in plot: CGRect) {
        guard let end = samples.last?.timeNs else { return }

        func xPosition(_ time: UInt64) -> CGFloat {
            let age = end - min(end, time)
            let fraction = CGFloat(min(age, ActivityHistory.durationNs)) / CGFloat(ActivityHistory.durationNs)
            return plot.maxX - plot.width * fraction
        }

        let signal = Path { path in
            var previous: UInt64?
            for sample in samples {
                let level = CGFloat(min(0, max(-60, sample.levelDBFS)))
                let point = CGPoint(x: xPosition(sample.timeNs), y: plot.minY - level / 60 * (plot.height - 18))
                if let previous, sample.timeNs - previous <= 600_000_000 { path.addLine(to: point) }
                else { path.move(to: point) }
                previous = sample.timeNs
            }
        }
        context.stroke(signal, with: .color(.primary.opacity(0.72)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))

        for sample in samples {
            guard let beat = sample.beatTimeNs, end - min(end, beat) <= ActivityHistory.durationNs else { continue }
            let box = CGRect(x: xPosition(beat) - 3, y: plot.maxY - 7, width: 6, height: 6)
            if sample.tapRequested {
                context.fill(Path(roundedRect: box, cornerRadius: 1), with: .color(ActivityPalette.pulse))
            } else {
                context.stroke(Path(ellipseIn: box), with: .color(ActivityPalette.pulse), lineWidth: 1.2)
            }
        }
    }
}
