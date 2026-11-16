import Foundation

enum IntervalMath {
  /// Merges overlapping/touching intervals and drops empty ones. Result is sorted.
  static func union(_ intervals: [DateInterval]) -> [DateInterval] {
    let sorted = intervals.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
    var result: [DateInterval] = []
    for interval in sorted {
      if let last = result.last, interval.start <= last.end {
        result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
      } else {
        result.append(interval)
      }
    }
    return result
  }

  /// Cuts every interval down to the part inside `bound`.
  static func clip(_ intervals: [DateInterval], to bound: DateInterval) -> [DateInterval] {
    intervals.compactMap { interval in
      let start = max(interval.start, bound.start)
      let end = min(interval.end, bound.end)
      return end > start ? DateInterval(start: start, end: end) : nil
    }
  }

  /// Everything covered by `intervals` that is not covered by `removing`.
  static func subtract(_ intervals: [DateInterval], _ removing: [DateInterval]) -> [DateInterval] {
    let cuts = union(removing)
    var result: [DateInterval] = []
    for interval in union(intervals) {
      var cursor = interval.start
      for cut in cuts where cut.end > cursor && cut.start < interval.end {
        if cut.start > cursor {
          result.append(DateInterval(start: cursor, end: cut.start))
        }
        cursor = max(cursor, cut.end)
      }
      if cursor < interval.end {
        result.append(DateInterval(start: cursor, end: interval.end))
      }
    }
    return result
  }

  static func total(_ intervals: [DateInterval]) -> TimeInterval {
    intervals.reduce(0) { $0 + $1.duration }
  }

  /// Safe constructor: `DateInterval` traps when end < start.
  static func make(_ start: Date, _ end: Date) -> DateInterval {
    DateInterval(start: start, end: max(start, end))
  }
}

/// Time breakdown of one work day.
///
/// Meetings always count, even when the Mac wasn't in use (in-person meetings):
/// - they fill gaps inside the tracked span,
/// - meetings before/after the tracked span extend the day; the stretch between a meeting and
///   laptop use is a gap,
/// - overlapping meetings count once, and nothing counts beyond `limit` (now, for today).
struct DayMetrics {
  /// The whole day: from the first activity (tracked or meeting) to the last one.
  let span: DateInterval
  /// Merged meeting time.
  let meetings: [DateInterval]
  /// Visible gaps and untracked stretches that are not covered by a meeting.
  let gaps: [DateInterval]

  /// - Parameters:
  ///   - tracked: the laptop-tracked span (start → end, or → now while running).
  ///   - visibleGaps: gaps inside the tracked span that are long enough to be shown.
  ///   - limit: ignore meeting time after this (now for today, end of day otherwise).
  ///   - minimumGap: untracked stretches shorter than this count as active (the visible-gap threshold).
  init(
    tracked: DateInterval,
    visibleGaps: [DateInterval],
    meetings: [DateInterval],
    limit: Date,
    minimumGap: TimeInterval = 0
  ) {
    let meetings = IntervalMath.clip(
      IntervalMath.union(meetings),
      to: IntervalMath.make(.distantPast, limit)
    )
    let start = min(tracked.start, meetings.first?.start ?? tracked.start)
    let end = max(tracked.end, meetings.last?.end ?? tracked.end)
    let span = IntervalMath.make(start, end)

    // Stretches of the day outside laptop tracking and outside meetings; short ones count as active.
    let untracked = IntervalMath.subtract(IntervalMath.subtract([span], [tracked]), meetings)
      .filter { $0.duration >= minimumGap }
    // A meeting can cover most of a gap; what's left is held to the same visibility threshold.
    let trackedGaps = IntervalMath.subtract(IntervalMath.clip(visibleGaps, to: tracked), meetings)
      .filter { $0.duration >= minimumGap }

    self.span = span
    self.meetings = meetings
    self.gaps = IntervalMath.union(trackedGaps + untracked)
  }

  var total: TimeInterval { span.duration }
  var meetingTime: TimeInterval { IntervalMath.total(meetings) }
  var gapTime: TimeInterval { IntervalMath.total(gaps) }
  var activeTime: TimeInterval { max(0, total - gapTime) }
  /// Active time outside meetings.
  var focusTime: TimeInterval { max(0, activeTime - meetingTime) }

  /// "2h 15m · 28%" — share of the whole day (start → end).
  var meetingSummary: String { summary(meetingTime) }
  var focusSummary: String { summary(focusTime) }

  private func summary(_ time: TimeInterval) -> String {
    let duration = DurationFormatter.hoursMinutes(time)
    guard total >= 60, time > 0 else { return duration }
    return "\(duration) · \(Int((time / total * 100).rounded()))%"
  }
}
