import Foundation

enum ClockifyCategory: String, Codable, Sendable {
  /// Total meeting time of the day.
  case meeting
  /// Everything else ("R&D").
  case work
}

struct ClockifyPlannedEntry: Equatable, Sendable {
  let category: ClockifyCategory
  let start: Date
  let end: Date
}

/// One work day prepared for Clockify: a MEETING block followed directly by a work (R&D) block,
/// starting at the day's rounded start. All values are whole quarter hours.
struct ClockifyDayPlan: Identifiable, Sendable {
  /// Local start of the day (same value as `WorkDay.date`).
  let date: Date
  var id: Date { date }

  /// Actual day (tracked span extended by meetings), before rounding.
  let actualStart: Date
  let actualEnd: Date
  /// Rounded to the nearest 15 minutes.
  let start: Date
  let end: Date
  /// Informational: visible gaps not covered by meetings.
  let gapTime: TimeInterval
  /// Out-of-office time inside the day (rounded), already taken out.
  let oooMinutes: Int
  /// The whole working day is covered by out-of-office events — skipped by default.
  let isWholeDayOutOfOffice: Bool
  /// An OOO event covers ≥ 30 minutes of the lunch window, so lunch isn't deducted again.
  let lunchCoveredByOutOfOffice: Bool

  // Editable in the review.
  var include: Bool
  var deductLunch: Bool
  var meetingMinutes: Int
  var workMinutes: Int

  let suggestedMeetingMinutes: Int
  let suggestedWorkMinutes: Int
  let suggestedDeductLunch: Bool

  var totalMinutes: Int { meetingMinutes + workMinutes }

  var isEdited: Bool {
    meetingMinutes != suggestedMeetingMinutes
      || workMinutes != suggestedWorkMinutes
      || deductLunch != suggestedDeductLunch
  }

  /// MEETING first, then work, back to back from the rounded start. Empty blocks are left out.
  var entries: [ClockifyPlannedEntry] {
    var result: [ClockifyPlannedEntry] = []
    var cursor = start
    for (category, minutes) in [(ClockifyCategory.meeting, meetingMinutes), (.work, workMinutes)] where minutes > 0 {
      let end = cursor.addingTimeInterval(TimeInterval(minutes * 60))
      result.append(ClockifyPlannedEntry(category: category, start: cursor, end: end))
      cursor = end
    }
    return result
  }

  /// Toggling lunch moves 30 minutes in or out of the work block.
  mutating func setDeductLunch(_ deduct: Bool) {
    guard deduct != deductLunch else { return }
    deductLunch = deduct
    if deduct {
      workMinutes = max(0, workMinutes - ClockifyPlanner.lunchMinutes)
    } else {
      workMinutes += ClockifyPlanner.lunchMinutes
    }
  }

  mutating func resetEdits() {
    meetingMinutes = suggestedMeetingMinutes
    workMinutes = suggestedWorkMinutes
    deductLunch = suggestedDeductLunch
  }
}

/// Clockify reporting rules:
/// - day = start → end (tracked time extended by meetings), each rounded to the nearest 15 minutes,
/// - meetings are summed (overlaps once) and rounded to 15 minutes,
/// - out-of-office events ("OOO" in the title) are taken out; a fully OOO day is skipped,
/// - 30 minutes lunch is deducted every day, unless OOO already covers ≥ 30 min of 11:00–14:00,
/// - the rest is R&D.
enum ClockifyPlanner {
  static let quarterHour: TimeInterval = 15 * 60
  static let lunchMinutes = 30
  static let lunchWindowHours = (start: 11, end: 14)

  static func roundToQuarterHour(_ date: Date) -> Date {
    let quarters = (date.timeIntervalSinceReferenceDate / quarterHour).rounded()
    return Date(timeIntervalSinceReferenceDate: quarters * quarterHour)
  }

  static func roundedMinutes(_ duration: TimeInterval) -> Int {
    Int((max(0, duration) / quarterHour).rounded()) * 15
  }

  static func plan(
    day: WorkDay,
    visibleGaps: [DateInterval],
    events: [Meeting],
    minimumGap: TimeInterval,
    now: Date,
    calendar: Calendar = .current
  ) -> ClockifyDayPlan {
    let dayStart = day.date
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
    let trackedEnd = day.endedAt ?? day.lastActivityAt ?? day.startedAt

    let meetings = events.filter { $0.kind == .meeting }.map(\.interval)
    let outOfOffice = IntervalMath.union(events.filter { $0.kind == .outOfOffice }.map(\.interval))

    let metrics = DayMetrics(
      tracked: IntervalMath.make(DateFormatting.floorToMinute(day.startedAt), min(trackedEnd, dayEnd)),
      visibleGaps: visibleGaps,
      meetings: meetings,
      limit: min(now, dayEnd),
      minimumGap: minimumGap
    )
    let span = metrics.span

    let isWholeDayOutOfOffice = !outOfOffice.isEmpty
      && IntervalMath.subtract([span], outOfOffice).isEmpty
    let oooTime = IntervalMath.total(IntervalMath.clip(outOfOffice, to: span))
    let meetingTime = IntervalMath.total(IntervalMath.subtract(metrics.meetings, outOfOffice))

    let lunchWindow = IntervalMath.make(
      calendar.date(bySettingHour: lunchWindowHours.start, minute: 0, second: 0, of: dayStart) ?? dayStart,
      calendar.date(bySettingHour: lunchWindowHours.end, minute: 0, second: 0, of: dayStart) ?? dayStart
    )
    let oooDuringLunch = IntervalMath.total(IntervalMath.clip(outOfOffice, to: lunchWindow))
    let lunchCovered = oooDuringLunch >= TimeInterval(lunchMinutes * 60)

    let start = roundToQuarterHour(span.start)
    let end = max(start, roundToQuarterHour(span.end))
    let totalMinutes = Int(end.timeIntervalSince(start) / 60)
    let oooMinutes = min(totalMinutes, roundedMinutes(oooTime))
    let deductLunch = !lunchCovered

    let available = max(0, totalMinutes - oooMinutes - (deductLunch ? lunchMinutes : 0))
    let meetingMinutes = min(roundedMinutes(meetingTime), available)
    let workMinutes = available - meetingMinutes

    return ClockifyDayPlan(
      date: dayStart,
      actualStart: span.start,
      actualEnd: span.end,
      start: start,
      end: end,
      gapTime: metrics.gapTime,
      oooMinutes: oooMinutes,
      isWholeDayOutOfOffice: isWholeDayOutOfOffice,
      lunchCoveredByOutOfOffice: lunchCovered,
      include: !isWholeDayOutOfOffice && available > 0,
      deductLunch: deductLunch,
      meetingMinutes: meetingMinutes,
      workMinutes: workMinutes,
      suggestedMeetingMinutes: meetingMinutes,
      suggestedWorkMinutes: workMinutes,
      suggestedDeductLunch: deductLunch
    )
  }
}
