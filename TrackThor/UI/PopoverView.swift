import Combine
import GRDB
import SwiftUI

struct PopoverView: View {
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject var trackingEngine: TrackingEngine
  @ObservedObject var meetingSync: MeetingSync
  let database: DatabaseManager
  let onOpenStats: () -> Void
  let onOpenSettings: () -> Void
  let onOpenClockify: () -> Void
  let onQuit: () -> Void

  @State private var history: [WorkDay] = []
  @State private var weekMeetings: [String: [Meeting]] = [:]
  @State private var now: Date = Date()
  @State private var reloadTask: Task<Void, Never>?

  private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(spacing: 14) {
      TodayView(trackingEngine: trackingEngine, meetingSync: meetingSync, now: now)

      Divider()

      HistoryView(
        history: history,
        meetingsByDay: weekMeetings,
        showMeetings: meetingSync.isConfigured,
        now: now
      )

      Divider()

      HStack(spacing: 6) {
        PopoverActionButton(title: "Stats", systemImage: "chart.bar.xaxis", action: onOpenStats)
        PopoverActionButton(title: "Clockify", systemImage: "paperplane", action: onOpenClockify)
        PopoverActionButton(title: "Settings", systemImage: "gearshape", action: onOpenSettings)
        PopoverActionButton(title: nil, systemImage: "power", action: onQuit)
          .frame(width: 44)
          .help("Quit TrackThor")
      }
    }
    .padding(14)
    .onAppear {
      now = Date()
      reloadHistory()
    }
    .onDisappear {
      reloadTask?.cancel()
      reloadTask = nil
    }
    .onChange(of: trackingEngine.todayWorkDay?.endedAt) { _, _ in reloadHistory() }
    .onChange(of: trackingEngine.todayWorkDay?.startedAt) { _, _ in reloadHistory() }
    .onChange(of: trackingEngine.todayWorkDay?.mode) { _, _ in reloadHistory() }
    .onChange(of: trackingEngine.todayWorkDay?.hasMixedLocations) { _, _ in reloadHistory() }
    .onChange(of: meetingSync.revision) { _, _ in reloadHistory() }
    .onReceive(ticker) { t in
      now = t
    }
  }

  private func reloadHistory() {
    reloadTask?.cancel()
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let weekday = calendar.component(.weekday, from: today)
    let daysFromMonday = (weekday + 5) % 7
    let start = calendar.date(byAdding: .day, value: -daysFromMonday, to: today)!
    let end = calendar.date(byAdding: .day, value: 6, to: start)!
    let dbQueue = database.dbQueue

    reloadTask = Task {
      do {
        let (days, meetings) = try await Task.detached(priority: .utility) {
          try dbQueue.read { db in
            let days = try WorkDay
              .filter((WorkDay.Columns.date >= start) && (WorkDay.Columns.date <= end))
              .order(WorkDay.Columns.date.desc)
              .fetchAll(db)
            let meetings = try Meeting.meetingsOnly
              .filter((Meeting.Columns.date >= start) && (Meeting.Columns.date <= end))
              .fetchAll(db)
            return (days, meetings)
          }
        }.value

        guard !Task.isCancelled else { return }
        history = days
        weekMeetings = Dictionary(grouping: meetings) { DateFormatting.dayKeyFormatter.string(from: $0.date) }
      } catch {
        guard !Task.isCancelled else { return }
        history = []
        weekMeetings = [:]
      }
    }
  }
}

/// Tile-style button for the popover footer: icon above a short label, subtle hover and press states.
private struct PopoverActionButton: View {
  let title: String?
  let systemImage: String
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      VStack(spacing: 3) {
        Image(systemName: systemImage)
          .font(.system(size: 14, weight: .medium))
          .frame(height: 17)
        if let title {
          Text(title)
            .font(.system(size: 11, weight: .medium))
        }
      }
      .frame(maxWidth: .infinity, minHeight: 42)
      .contentShape(Rectangle())
    }
    .buttonStyle(PopoverTileStyle(isHovered: isHovered))
    .onHover { isHovered = $0 }
  }
}

private struct PopoverTileStyle: ButtonStyle {
  let isHovered: Bool

  func makeBody(configuration: ButtonStyleConfiguration) -> some View {
    configuration.label
      .foregroundStyle(isHovered ? Color.primary : Color.secondary)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : isHovered ? 0.09 : 0.045))
      )
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.easeOut(duration: 0.12), value: isHovered)
  }
}
