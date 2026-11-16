import SwiftUI

/// Day timeline: active work, meetings and gaps inside one rounded track.
struct TimelineBar: View {
  let metrics: DayMetrics
  var cornerRadius: CGFloat = 6

  static let activeColor = Color.green
  static let gapColor = Color.gray
  static let meetingColor = Color.indigo

  var body: some View {
    Canvas { context, size in
      let span = metrics.span
      let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: cornerRadius, style: .continuous)
      context.fill(track, with: .color(Self.gapColor.opacity(0.18)))
      guard span.duration > 0 else { return }

      context.clip(to: track)
      for segment in segments() {
        let x = CGFloat(segment.interval.start.timeIntervalSince(span.start) / span.duration) * size.width
        let width = CGFloat(segment.interval.duration / span.duration) * size.width
        context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(segment.color))
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
    return active.map { Segment(interval: $0, color: Self.activeColor) }
      + metrics.gaps.map { Segment(interval: $0, color: Self.gapColor) }
      + metrics.meetings.map { Segment(interval: $0, color: Self.meetingColor) }
  }
}
