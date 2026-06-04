import GRDB
import SwiftUI

struct StatsView: View {
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject var trackingEngine: TrackingEngine
  let database: DatabaseManager

  @State private var workDays: [WorkDay] = []
  @State private var selectedDate: Date?
  @State private var gaps: [Gap] = []
  @State private var now: Date = Date()
  @State private var dayPendingDeletion: WorkDay?
  @State private var reloadTask: Task<Void, Never>?
  @State private var gapsTask: Task<Void, Never>?

  private let ticker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

  var body: some View {
    ScrollView {
      HStack(alignment: .top, spacing: 20) {
        statsCard {
          calendarPanel
        }
        .frame(width: 300)

        statsCard {
          VStack(alignment: .leading, spacing: 14) {
            header

            if let day = selectedDay {
              let effectiveEndRaw = effectiveEnd(for: day)
              let endDisplay = DateFormatting.floorToMinute(effectiveEndRaw)

              VStack(alignment: .leading, spacing: 12) {
                statsSection(
                  title: "Duration",
                  detail: "Total is start to finish. Active subtracts visible gaps."
                ) {
                  VStack(spacing: 6) {
                    durationRow(
                      label: "Total time",
                      value: totalDurationText(for: day, endRaw: effectiveEndRaw),
                      isEmphasized: true
                    )
                    durationRow(
                      label: "Active sessions",
                      value: activeDurationText(for: day, endRaw: effectiveEndRaw)
                    )
                  }
                }

                statsSection(
                  title: "Summary",
                  detail: "Overview for the selected work day."
                ) {
                  HStack(alignment: .top) {
                    Text(summaryLine(for: day, endDisplay: endDisplay, endRaw: effectiveEndRaw))
                      .font(.system(size: 15, weight: .semibold))

                    Spacer()

                    Button("Delete Day", role: .destructive) {
                      dayPendingDeletion = day
                    }
                  }
                }

                statsSection(
                  title: "Timeline",
                  detail: "Green segments are active work. Gray segments are visible gaps."
                ) {
                  TimelineBar(
                    startedAt: day.startedAt,
                    endedAt: effectiveEndRaw,
                    gaps: gaps
                  )
                  .frame(height: 22)
                  .padding(10)
                  .background(Color.white.opacity(0.72))
                  .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                  .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                      .stroke(Color.black.opacity(0.05), lineWidth: 1)
                  )

                  HStack(spacing: 14) {
                    Label("Active", systemImage: "square.fill")
                      .labelStyle(.titleOnly)
                      .foregroundStyle(.green)
                    Label("Gap", systemImage: "square.fill")
                      .labelStyle(.titleOnly)
                      .foregroundStyle(.gray)
                  }
                  .font(.caption)
                }

                statsSection(
                  title: "Gaps",
                  detail: "Only gaps longer than the configured threshold are shown."
                ) {
                  if gaps.isEmpty {
                    emptyRow("No visible gaps")
                  } else {
                    VStack(spacing: 6) {
                      ForEach(gaps) { gap in
                        let s = DateFormatting.timeFormatter.string(from: gap.startedAt)
                        let e = DateFormatting.timeFormatter.string(from: gap.endedAt)
                        let d = DurationFormatter.hoursMinutes(gap.endedAt.timeIntervalSince(gap.startedAt))
                        HStack {
                          Text("\(s) – \(e)")
                          Spacer()
                          Text(d)
                            .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 13))
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .background(Color.white.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                          RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.black.opacity(0.05), lineWidth: 1)
                        )
                      }
                    }
                  }
                }
              }
            } else if workDays.isEmpty {
              emptyState(
                title: "No recorded days yet.",
                detail: "Tracked work days will appear here once TrackThor records them."
              )
            } else {
              emptyState(
                title: "No data for \(selectedDateLabel).",
                detail: "Pick a highlighted work day from the calendar to view its summary."
              )
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(windowBackground)
    .alert("Delete This Day?", isPresented: deleteAlertBinding) {
      Button("Delete", role: .destructive) { deleteSelectedDay() }
      Button("Cancel", role: .cancel) { dayPendingDeletion = nil }
    } message: {
      Text("This removes the selected day and all recorded gaps for it.")
    }
    .onAppear { reloadData(selectLatestIfNeeded: true) }
    .onDisappear {
      reloadTask?.cancel()
      gapsTask?.cancel()
      reloadTask = nil
      gapsTask = nil
    }
    .onChange(of: selectedDate) { _ in loadGaps() }
    .onChange(of: trackingEngine.todayWorkDay?.startedAt) { _ in reloadData(selectLatestIfNeeded: false) }
    .onChange(of: trackingEngine.todayWorkDay?.endedAt) { _ in reloadData(selectLatestIfNeeded: false) }
    .onChange(of: trackingEngine.todayWorkDay?.mode) { _ in reloadData(selectLatestIfNeeded: false) }
    .onChange(of: trackingEngine.todayWorkDay?.hasMixedLocations) { _ in reloadData(selectLatestIfNeeded: false) }
    .onReceive(ticker) { t in
      now = t
    }
  }

  private var calendarPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Calendar")
          .font(.system(size: 17, weight: .semibold))
        Text("Jump directly to any recorded day.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let bounds = dateBounds {
        DatePicker(
          "Recorded Day",
          selection: selectedDateBinding,
          in: bounds,
          displayedComponents: [.date]
        )
        .datePickerStyle(.graphical)
        .labelsHidden()
        .focusable(false)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
      } else {
        emptyRow("No recorded days yet.")
      }

      if !workDays.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("Recorded Days")
            .font(.system(size: 13, weight: .semibold))
          Text("Quick picks for recent activity.")
            .font(.caption)
            .foregroundStyle(.secondary)

          ScrollView {
            VStack(spacing: 8) {
              ForEach(workDays.reversed()) { day in
                Button {
                  selectedDate = day.date
                } label: {
                  HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                      Text(DateFormatting.longDayFormatter.string(from: day.date))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                      Text(dayRailDetail(for: day))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if dayKey(for: day.date) == dayKey(for: selectedDate ?? day.date) {
                      Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.blue)
                    }
                  }
                  .padding(.vertical, 9)
                  .padding(.horizontal, 10)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .background(dayRailBackground(for: day))
                  .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                  .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                      .stroke(dayRailBorderColor(for: day), lineWidth: 1)
                  )
                }
                .buttonStyle(.plain)
              }
            }
            .padding(1)
          }
          .frame(maxHeight: 260)
        }
      }

      if !availableDateKeys.isEmpty {
        Text("Recorded days are available between \(dateRangeLabel).")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 2)
      }
    }
  }

  private var header: some View {
    HStack {
      Button("←") { selectAdjacentDay(offset: -1) }
        .disabled(previousDay == nil)
      Button("→") { selectAdjacentDay(offset: 1) }
        .disabled(nextDay == nil)

      Spacer()

      Text(selectedDay.map { DateFormatting.longDayFormatter.string(from: $0.date) } ?? "Stats")
        .font(.system(size: 16, weight: .semibold))

      Spacer()

      Button("Latest") { selectLatestDay() }
        .disabled(workDays.isEmpty)
    }
  }

  private func statsCard<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      content()
    }
    .padding(14)
    .background(cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(Color.black.opacity(0.06), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.04), radius: 10, y: 4)
  }

  private func statsSection<Content: View>(
    title: String,
    detail: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 13, weight: .semibold))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      content()
    }
  }

  private func emptyState(title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.system(size: 16, weight: .semibold))
      Text(detail)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.white.opacity(0.72))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.black.opacity(0.05), lineWidth: 1)
    )
  }

  private func emptyRow(_ text: String) -> some View {
    Text(text)
      .foregroundStyle(.secondary)
      .padding(.vertical, 10)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.white.opacity(0.72))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color.black.opacity(0.05), lineWidth: 1)
      )
  }

  private func durationRow(label: String, value: String, isEmphasized: Bool = false) -> some View {
    HStack {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .fontWeight(isEmphasized ? .semibold : .regular)
    }
    .font(.system(size: 13))
    .padding(.vertical, 7)
    .padding(.horizontal, 10)
    .background(Color.white.opacity(0.72))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.black.opacity(0.05), lineWidth: 1)
    )
  }

  private func dayRailDetail(for day: WorkDay) -> String {
    let end = effectiveEnd(for: day)
    let duration = totalDurationText(for: day, endRaw: end)
    let start = DateFormatting.timeFormatter.string(from: DateFormatting.floorToMinute(day.startedAt))
    let finish = DateFormatting.timeFormatter.string(from: DateFormatting.floorToMinute(end))
    return "\(start) → \(finish)  •  \(duration)"
  }

  private func dayRailBackground(for day: WorkDay) -> Color {
    if dayKey(for: day.date) == dayKey(for: selectedDate ?? day.date) {
      return Color(red: 0.89, green: 0.94, blue: 1.0)
    }
    return Color.white.opacity(0.74)
  }

  private func dayRailBorderColor(for day: WorkDay) -> Color {
    if dayKey(for: day.date) == dayKey(for: selectedDate ?? day.date) {
      return Color.blue.opacity(0.35)
    }
    return Color.black.opacity(0.05)
  }

  private var windowBackground: some View {
    LinearGradient(
      colors: [
        Color(red: 0.96, green: 0.97, blue: 0.99),
        Color(red: 0.93, green: 0.95, blue: 0.98)
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private var cardBackground: some View {
    LinearGradient(
      colors: [
        Color.white.opacity(0.92),
        Color(red: 0.95, green: 0.97, blue: 1.0)
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private var selectedDay: WorkDay? {
    guard let selectedDate else { return nil }
    let key = dayKey(for: selectedDate)
    return workDays.first { dayKey(for: $0.date) == key }
  }

  private var selectedDateBinding: Binding<Date> {
    Binding(
      get: { normalizedDay(selectedDate ?? workDays.last?.date ?? Date()) },
      set: { selectedDate = normalizedDay($0) }
    )
  }

  private var availableDateKeys: Set<String> {
    Set(workDays.map { dayKey(for: $0.date) })
  }

  private var dateBounds: ClosedRange<Date>? {
    guard let first = workDays.first?.date, let last = workDays.last?.date else { return nil }
    return normalizedDay(first)...normalizedDay(last)
  }

  private var selectedDateLabel: String {
    DateFormatting.longDayFormatter.string(from: normalizedDay(selectedDate ?? Date()))
  }

  private var dateRangeLabel: String {
    guard let first = workDays.first?.date, let last = workDays.last?.date else { return "" }
    let start = DateFormatting.longDayFormatter.string(from: first)
    let end = DateFormatting.longDayFormatter.string(from: last)
    return start == end ? start : "\(start) and \(end)"
  }

  private var selectedDayIndex: Int? {
    guard let selectedDay else { return nil }
    return workDays.firstIndex { dayKey(for: $0.date) == dayKey(for: selectedDay.date) }
  }

  private var previousDay: WorkDay? {
    guard let index = selectedDayIndex, index > 0 else { return nil }
    return workDays[index - 1]
  }

  private var nextDay: WorkDay? {
    guard let index = selectedDayIndex, index < workDays.count - 1 else { return nil }
    return workDays[index + 1]
  }

  private func summaryLine(for day: WorkDay, endDisplay: Date, endRaw: Date) -> String {
    let start = DateFormatting.timeFormatter.string(from: DateFormatting.floorToMinute(day.startedAt))
    let end = DateFormatting.timeFormatter.string(from: endDisplay)
    let mode: String
    if day.hasMixedLocations {
      mode = "🔀 Home + Office"
    } else {
      mode = day.mode == .manual ? "🏠 Home" : "🏢 Office"
    }
    return "\(start) → \(end)  ·  \(mode)"
  }

  private func totalDurationText(for day: WorkDay, endRaw: Date) -> String {
    let spanSeconds = max(0, endRaw.timeIntervalSince(DateFormatting.floorToMinute(day.startedAt)))
    return DurationFormatter.hoursMinutesRoundedUpToMinute(spanSeconds)
  }

  private func activeDurationText(for day: WorkDay, endRaw: Date) -> String {
    let gapDuration = gaps.reduce(into: 0) { total, gap in
      total += gap.endedAt.timeIntervalSince(gap.startedAt)
    }
    let spanSeconds = max(0, endRaw.timeIntervalSince(DateFormatting.floorToMinute(day.startedAt)) - gapDuration)
    return DurationFormatter.hoursMinutesRoundedUpToMinute(spanSeconds)
  }

  private func effectiveEnd(for day: WorkDay) -> Date {
    if let endedAt = day.endedAt {
      return endedAt
    }

    let today = normalizedDay(now)
    if normalizedDay(day.date) < today,
       let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: normalizedDay(day.date))?
        .addingTimeInterval(-1)
    {
      return dayEnd
    }

    return now
  }

  private func reloadData(selectLatestIfNeeded: Bool) {
    let previousSelectionKey = selectedDate.map(dayKey(for:))
    let dbQueue = database.dbQueue

    reloadTask?.cancel()
    reloadTask = Task {
      do {
        let loadedDays = try await Task.detached(priority: .utility) {
          try dbQueue.read { db in
            try WorkDay.order(WorkDay.Columns.date.asc).fetchAll(db)
          }
        }.value

        guard !Task.isCancelled else { return }
        workDays = loadedDays

        if workDays.isEmpty {
          selectedDate = nil
          gaps = []
          return
        }

        if let previousSelectionKey,
           let preservedDay = workDays.first(where: { dayKey(for: $0.date) == previousSelectionKey })
        {
          selectedDate = preservedDay.date
        } else if selectLatestIfNeeded || selectedDate == nil {
          selectedDate = workDays.last?.date
        }

        loadGaps()
      } catch {
        guard !Task.isCancelled else { return }
        workDays = []
        gaps = []
        selectedDate = nil
      }
    }
  }

  private var deleteAlertBinding: Binding<Bool> {
    Binding(
      get: { dayPendingDeletion != nil },
      set: { isPresented in
        if !isPresented {
          dayPendingDeletion = nil
        }
      }
    )
  }

  private func deleteSelectedDay() {
    guard let day = dayPendingDeletion, let id = day.id else { return }

    let deletedKey = dayKey(for: day.date)
    let dbQueue = database.dbQueue
    dayPendingDeletion = nil

    reloadTask?.cancel()
    gapsTask?.cancel()
    reloadTask = Task {
      do {
        try await Task.detached(priority: .utility) {
          try dbQueue.write { db in
            _ = try WorkDay.deleteOne(db, key: id)
          }
        }.value
      } catch {
        return
      }

      guard !Task.isCancelled else { return }
      await MainActor.run {
        reloadData(selectLatestIfNeeded: false)
        if selectedDate.map(dayKey(for:)) == deletedKey {
          selectedDate = workDays.last?.date
          loadGaps()
        }
      }
    }
  }

  private func loadGaps() {
    guard let day = selectedDay, let id = day.id else {
      gaps = []
      return
    }

    let dbQueue = database.dbQueue
    let visibleGapThreshold = settings.minimumVisibleGapDuration

    gapsTask?.cancel()
    gapsTask = Task {
      do {
        let loadedGaps = try await Task.detached(priority: .utility) {
          try dbQueue.read { db in
            try Gap
              .filter(Gap.Columns.workDayId == id)
              .order(Gap.Columns.startedAt.asc)
              .fetchAll(db)
              .filter { $0.endedAt.timeIntervalSince($0.startedAt) >= visibleGapThreshold }
          }
        }.value
        guard !Task.isCancelled else { return }
        gaps = loadedGaps
      } catch {
        guard !Task.isCancelled else { return }
        gaps = []
      }
    }
  }

  private func selectAdjacentDay(offset: Int) {
    guard let index = selectedDayIndex else { return }
    let nextIndex = index + offset
    guard workDays.indices.contains(nextIndex) else { return }
    selectedDate = workDays[nextIndex].date
  }

  private func selectLatestDay() {
    selectedDate = workDays.last?.date
  }

  private func normalizedDay(_ date: Date) -> Date {
    Calendar.current.startOfDay(for: date)
  }

  private func dayKey(for date: Date) -> String {
    DateFormatting.dayKeyFormatter.string(from: normalizedDay(date))
  }
}
