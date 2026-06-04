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
  @State private var now: Date = Date()
  @State private var reloadTask: Task<Void, Never>?

  private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(spacing: 14) {
      TodayView(trackingEngine: trackingEngine, now: now)

      Divider()

      HistoryView(history: history, now: now)

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
    let dbQueue = database.dbQueue

    reloadTask = Task {
      do {
        let days = try await Task.detached(priority: .utility) {
          try dbQueue.read { db in
            try WorkDay
              .filter((WorkDay.Columns.date >= start) && (WorkDay.Columns.date <= end))
              .order(WorkDay.Columns.date.desc)
              .fetchAll(db)
          }
        }.value

        guard !Task.isCancelled else { return }
        history = days
      } catch {
        guard !Task.isCancelled else { return }
        history = []
      }
    }
  }
}
