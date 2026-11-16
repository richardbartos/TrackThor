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

      HStack {
        Button("📊 Stats") { onOpenStats() }
        Button("⚙ Settings") { onOpenSettings() }
        Spacer()
        Button("Quit") { onQuit() }
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
    .onChange(of: trackingEngine.todayWorkDay?.endedAt) { _ in reloadHistory() }
    .onChange(of: trackingEngine.todayWorkDay?.startedAt) { _ in reloadHistory() }
    .onChange(of: trackingEngine.todayWorkDay?.mode) { _ in reloadHistory() }
    .onChange(of: trackingEngine.todayWorkDay?.hasMixedLocations) { _ in reloadHistory() }
    .onChange(of: meetingSync.revision) { _ in reloadHistory() }
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
            let meetings = try Meeting
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
