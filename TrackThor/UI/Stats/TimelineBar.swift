import SwiftUI

struct TimelineBar: View {
  let metrics: DayMetrics

  static let activeColor = Color.green
  static let gapColor = Color.gray
  static let meetingColor = Color.indigo

  var body: some View {
    Canvas { context, size in
      let span = metrics.span
      let total = max(1, span.duration)

      for segment in segments() {
        let x = CGFloat(segment.interval.start.timeIntervalSince(span.start) / total) * size.width
        let width = CGFloat(segment.interval.duration / total) * size.width
        let rect = CGRect(x: x, y: 0, width: width, height: size.height)
        context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(segment.color))
      }
    }
  }

  private struct Segment {
    let interval: DateInterval
    let color: Color
  }

  /// Meetings take precedence over gaps (they fill them); everything else in the span is active.
  private func segments() -> [Segment] {
    let active = IntervalMath.subtract([metrics.span], metrics.meetings + metrics.gaps)
    let all = active.map { Segment(interval: $0, color: Self.activeColor) }
      + metrics.gaps.map { Segment(interval: $0, color: Self.gapColor) }
      + metrics.meetings.map { Segment(interval: $0, color: Self.meetingColor) }
    return all.sorted { $0.interval.start < $1.interval.start }
  }
}
