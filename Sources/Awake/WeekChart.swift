import SwiftUI

/// One weekday in the chart.
struct WeekBar: Identifiable {
    let date: Date
    let seconds: TimeInterval
    let isToday: Bool
    let isFuture: Bool

    var id: Date { date }
}

/// Monday-Friday as five vertical bars. Full height is the 8 h target (longer
/// days are capped), with a faint dashed guide line at 8 h.
struct WeekChart: View {
    let bars: [WeekBar]

    private static let letters = ["M", "T", "W", "T", "F"]
    private let plotHeight: CGFloat = 44

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                VStack(spacing: 5) {
                    ZStack(alignment: .bottom) {
                        Color.clear
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(fill(for: bar))
                            .frame(height: barHeight(for: bar))
                    }
                    .frame(height: plotHeight)

                    Text(Self.letters[index % Self.letters.count])
                        .font(.caption2.weight(bar.isToday ? .bold : .regular))
                        .foregroundStyle(bar.isToday ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .help("\(bar.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())): \(Format.duration(bar.seconds))")
            }
        }
        .background(alignment: .top) {
            // 8 h guide, level with the top of a full bar.
            GuideLine()
                .stroke(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 1)
        }
    }

    private func barHeight(for bar: WeekBar) -> CGFloat {
        let fraction = min(bar.seconds / AwakeMath.dailyTarget, 1)
        // A small stub keeps empty days visible as a bar.
        return max(fraction * plotHeight, 3)
    }

    private func fill(for bar: WeekBar) -> AnyShapeStyle {
        if bar.seconds <= 0 { return AnyShapeStyle(.quaternary) }
        let reachedGoal = bar.seconds >= AwakeMath.dailyTarget
        if bar.isToday { return AnyShapeStyle(reachedGoal ? Color.green : Color.accentColor) }
        return AnyShapeStyle((reachedGoal ? Color.green : Color.accentColor).opacity(0.4))
    }
}

private struct GuideLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
