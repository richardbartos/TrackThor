import SwiftUI

struct TodayView: View {
  @ObservedObject var trackingEngine: TrackingEngine
  @ObservedObject var meetingSync: MeetingSync
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("TODAY")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(alignment: .firstTextBaseline) {
        Text(todayLine)
          .font(.system(size: 18, weight: .semibold, design: .default))

        Spacer()

        Circle()
          .fill(trackingEngine.todayWorkDay?.endedAt == nil && trackingEngine.todayWorkDay != nil ? Color.green : Color.gray)
          .frame(width: 10, height: 10)
      }

      if let meetingLine {
        Label(meetingLine, systemImage: "person.2.fill")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }

      if showStartHomeOffice {
        Button("▶ Start Home Office") {
          trackingEngine.startManualDay()
        }
      }

      if showStopManual {
        Button("■ Stop") {
          trackingEngine.stopTracking()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var showStartHomeOffice: Bool {
    !isAutoActive && !isManualActive
  }

  private var showStopManual: Bool {
    isManualActive
  }

  private var isAutoActive: Bool {
    trackingEngine.todayWorkDay?.mode == .auto && trackingEngine.todayWorkDay?.endedAt == nil
  }

  private var isManualActive: Bool {
    trackingEngine.todayWorkDay?.mode == .manual && trackingEngine.todayWorkDay?.endedAt == nil
  }

  /// Today so far: tracked time extended by meetings (future meetings aren't counted yet).
  private var metrics: DayMetrics? {
    guard let day = trackingEngine.todayWorkDay else { return nil }
    return DayMetrics(
      tracked: IntervalMath.make(DateFormatting.floorToMinute(day.startedAt), day.endedAt ?? now),
      visibleGaps: [],
      meetings: meetingSync.todayMeetingIntervals,
      limit: now
    )
  }

  private var meetingLine: String? {
    guard meetingSync.isConfigured, let metrics else { return nil }
    return "Meetings \(metrics.meetingSummary)"
  }

  private var todayLine: String {
    guard let day = trackingEngine.todayWorkDay, let metrics else { return "—" }
    let start = DateFormatting.timeFormatter.string(from: DateFormatting.floorToMinute(metrics.span.start))
    let end = DateFormatting.timeFormatter.string(from: DateFormatting.floorToMinute(metrics.span.end))
    // Duration rounds up, but displayed end time never goes into the future.
    let duration = DurationFormatter.hoursMinutesRoundedUpToMinute(metrics.total)
    return "\(prefix(for: day))\(start) → \(end)  ·  \(duration)"
  }

  private func prefix(for day: WorkDay) -> String {
    if day.hasMixedLocations { return "🔀 " }
    switch day.mode {
    case .manual: return "🏠 "
    case .auto: return ""
    }
  }
}
