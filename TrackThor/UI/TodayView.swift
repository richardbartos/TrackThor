import SwiftUI

struct TodayView: View {
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject var trackingEngine: TrackingEngine
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

      Text(goalLine)
        .font(.caption)
        .foregroundStyle(.secondary)

      if showStartManual {
        Button("▶ Start Manual Day") {
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

  private var showStartManual: Bool {
    trackingEngine.todayWorkDay?.mode != .manual || trackingEngine.todayWorkDay?.endedAt != nil || trackingEngine.todayWorkDay == nil
  }

  private var showStopManual: Bool {
    trackingEngine.todayWorkDay?.endedAt == nil && trackingEngine.todayWorkDay != nil
  }

  private var todayLine: String {
    guard let day = trackingEngine.todayWorkDay else { return "—" }
    let startDisplay = DateFormatting.floorToMinute(day.startedAt)
    let endRaw = day.endedAt ?? now
    let endDisplay = DateFormatting.floorToMinute(endRaw)
    let start = DateFormatting.timeFormatter.string(from: startDisplay)
    let end = DateFormatting.timeFormatter.string(from: endDisplay)
    // Duration rounds up, but displayed end time never goes into the future.
    let span = max(0, endRaw.timeIntervalSince(startDisplay) - trackingEngine.todayGapDuration)
    let duration = DurationFormatter.hoursMinutesRoundedUpToMinute(span)
    return "\(prefix(for: day))\(start) → \(end)  ·  \(duration)"
  }

  private var goalLine: String {
    guard let day = trackingEngine.todayWorkDay else { return "" }
    let startDisplay = DateFormatting.floorToMinute(day.startedAt)
    let endRaw = day.endedAt ?? now
    let span = max(0, endRaw.timeIntervalSince(startDisplay) - trackingEngine.todayGapDuration)
    let duration = DurationFormatter.hoursMinutesRoundedUpToMinute(span)
    let goal = "\(DurationFormatter.hoursMinutes(fromMinutes: settings.dailyGoalMinutes)) goal"
    return "\(duration) / \(goal)"
  }

  private func prefix(for day: WorkDay) -> String {
    if day.hasMixedLocations { return "🔀 " }
    switch day.mode {
    case .manual: return "🏠 "
    case .auto: return ""
    }
  }
}
