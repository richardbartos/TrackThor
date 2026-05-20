import GRDB
import SwiftUI

struct PopoverView: View {
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject var trackingEngine: TrackingEngine
  let database: DatabaseManager
  let onOpenStats: () -> Void
  let onOpenSettings: () -> Void
  let onQuit: () -> Void

  @State private var history: [WorkDay] = []
  @State private var gapDurations: [Int64: TimeInterval] = [:]
  @State private var now: Date = Date()
  @State private var reloadTask: Task<Void, Never>?

  private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(spacing: 14) {
      TodayView(trackingEngine: trackingEngine, now: now)

      Divider()

      HistoryView(history: history, gapDurations: gapDurations, now: now)

      Divider()

      HStack {
        Button("📊 Stats") { onOpenStats() }
        Button("⚙ Settings") { onOpenSettings() }
        Spacer()
        Button("Quit") { onQuit() }
      }
    }
    .padding(14)
    .onAppear { reloadHistory() }
    .onDisappear {
      reloadTask?.cancel()
      reloadTask = nil
    }
    .onChange(of: trackingEngine.todayWorkDay?.endedAt) { _ in reloadHistory() }
    .onChange(of: trackingEngine.todayWorkDay?.startedAt) { _ in reloadHistory() }
    .onChange(of: trackingEngine.todayWorkDay?.mode) { _ in reloadHistory() }
    .onChange(of: trackingEngine.todayWorkDay?.hasMixedLocations) { _ in reloadHistory() }
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
    let visibleGapThreshold = settings.minimumVisibleGapDuration
    let dbQueue = database.dbQueue

    reloadTask = Task {
      do {
        let result = try await Task.detached(priority: .utility) {
          try dbQueue.read { db in
            let days = try WorkDay
              .filter((WorkDay.Columns.date >= start) && (WorkDay.Columns.date <= end))
              .order(WorkDay.Columns.date.desc)
              .fetchAll(db)
            let ids = days.compactMap(\.id)
            let gaps = ids.isEmpty ? [] : try Gap
              .filter(ids.contains(Gap.Columns.workDayId))
              .fetchAll(db)
            let durations = gaps.reduce(into: [Int64: TimeInterval]()) { totals, gap in
              let duration = gap.endedAt.timeIntervalSince(gap.startedAt)
              if duration >= visibleGapThreshold {
                totals[gap.workDayId, default: 0] += duration
              }
            }
            return (days, durations)
          }
        }.value

        guard !Task.isCancelled else { return }
        history = result.0
        gapDurations = result.1
      } catch {
        guard !Task.isCancelled else { return }
        history = []
        gapDurations = [:]
      }
    }
  }
}
