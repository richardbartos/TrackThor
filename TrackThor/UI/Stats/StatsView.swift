import Combine
import GRDB
import SwiftUI

/// Stats page: month list of recorded days on the left, the selected day on the right.
struct StatsView: View {
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject var trackingEngine: TrackingEngine
  @ObservedObject var meetingSync: MeetingSync
  let database: DatabaseManager

  @State private var workDays: [WorkDay] = []
  /// All stored meetings, keyed by day; the list needs them too (meetings extend a day).
  @State private var meetingsByDay: [String: [Meeting]] = [:]
  @State private var selectedDate: Date?
  @State private var displayedMonth: Date = StatsView.monthStart(of: Date())
  /// All recorded gaps by work day id (filtered by the visibility threshold when used).
  @State private var gapsByDay: [Int64: [Gap]] = [:]
  @State private var now = Date()
  @State private var dayPendingDeletion: WorkDay?
  @State private var reloadTask: Task<Void, Never>?
  @State private var hasLoaded = false

  private let ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

  var body: some View {
    HStack(spacing: 0) {
      dayList
        .frame(width: 280)
      Divider()
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .navigationTitle("Stats")
    .alert("Delete this day?", isPresented: deleteAlertBinding) {
      Button("Delete", role: .destructive) { deleteSelectedDay() }
      Button("Cancel", role: .cancel) { dayPendingDeletion = nil }
    } message: {
      Text("This removes the day and all its recorded gaps. Calendar meetings aren't affected.")
    }
    .onAppear {
      now = Date()
      reloadData(selectLatestIfNeeded: !hasLoaded)
      hasLoaded = true
    }
    .onDisappear {
      reloadTask?.cancel()
    }
    .onChange(of: selectedDate) { _, newValue in
      if let newValue {
        displayedMonth = Self.monthStart(of: newValue)
      }
    }
    .onChange(of: meetingSync.revision) { _, _ in reloadData(selectLatestIfNeeded: false) }
    .onChange(of: trackingEngine.todayWorkDay?.startedAt) { _, _ in reloadData(selectLatestIfNeeded: false) }
    .onChange(of: trackingEngine.todayWorkDay?.endedAt) { _, _ in reloadData(selectLatestIfNeeded: false) }
    .onChange(of: trackingEngine.todayWorkDay?.mode) { _, _ in reloadData(selectLatestIfNeeded: false) }
    .onChange(of: trackingEngine.todayWorkDay?.hasMixedLocations) { _, _ in reloadData(selectLatestIfNeeded: false) }
    .onReceive(ticker) { now = $0 }
  }

  // MARK: - Day list

  private var dayList: some View {
    VStack(spacing: 0) {
      monthHeader
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)

      Divider()

      if daysInDisplayedMonth.isEmpty {
        ContentUnavailableView(
          "No days",
          systemImage: "calendar",
          description: Text(workDays.isEmpty ? "Tracked days will appear here." : "Nothing was tracked this month.")
        )
        .frame(maxHeight: .infinity)
      } else {
        List(selection: $selectedDate) {
          ForEach(daysInDisplayedMonth, id: \.date) { day in
            dayRow(day)
              .tag(day.date)
          }
        }
        .listStyle(.inset)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var monthHeader: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 4) {
        Text(Self.monthTitle(displayedMonth))
          .font(.title3.weight(.semibold))
        Spacer()
        Button { shiftMonth(by: -1) } label: { Image(systemName: "chevron.left") }
          .disabled(!canShowPreviousMonth)
          .help("Previous month")
        Button("Today") { selectLatestDay() }
          .disabled(workDays.isEmpty)
        Button { shiftMonth(by: 1) } label: { Image(systemName: "chevron.right") }
          .disabled(!canShowNextMonth)
          .help("Next month")
      }
      .buttonStyle(.borderless)

      Text(monthSummary)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func dayRow(_ day: WorkDay) -> some View {
    let metrics = dayMetrics(for: day)
    let start = DateFormatting.timeFormatter.string(from: DateFormatting.floorToMinute(metrics.span.start))
    let end = DateFormatting.timeFormatter.string(from: DateFormatting.floorToMinute(metrics.span.end))
    let meetings = metrics.meetingTime > 0 ? "  ·  \(DurationFormatter.hoursMinutes(metrics.meetingTime)) meetings" : ""

    return VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(Self.shortDay(day.date))
          .font(.system(size: 13, weight: .semibold))
        Text(Self.modeIcon(for: day))
          .font(.caption)
        Spacer()
        Text(DurationFormatter.hoursMinutesRoundedUpToMinute(metrics.total))
          .font(.system(size: 13, weight: .medium).monospacedDigit())
      }
      Text("\(start) → \(end)\(meetings)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      TimelineBar(metrics: metrics, cornerRadius: 2)
        .frame(height: 5)
    }
    .padding(.vertical, 4)
  }

  // MARK: - Detail

  @ViewBuilder
  private var detail: some View {
    if let day = selectedDay {
      let metrics = dayMetrics(for: day)
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          dayHeader(day, metrics: metrics)
          tiles(metrics)
          timelineCard(metrics)
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
              meetingsCard(metrics).frame(minWidth: 280)
              gapsCard(metrics).frame(minWidth: 280)
            }
            VStack(spacing: 16) {
              meetingsCard(metrics)
              gapsCard(metrics)
            }
          }
        }
        .padding(24)
        .frame(maxWidth: 1100, alignment: .leading)
      }
    } else if workDays.isEmpty {
      ContentUnavailableView(
        "No recorded days yet",
        systemImage: "clock",
        description: Text("Work days appear here once TrackThor has tracked them.")
      )
    } else {
      ContentUnavailableView("Select a day", systemImage: "calendar", description: Text("Pick a day from the list."))
    }
  }

  private func dayHeader(_ day: WorkDay, metrics: DayMetrics) -> some View {
    let start = DateFormatting.timeFormatter.string(from: DateFormatting.floorToMinute(metrics.span.start))
    let end = DateFormatting.timeFormatter.string(from: DateFormatting.floorToMinute(metrics.span.end))
    let isRunning = day.endedAt == nil && Calendar.current.isDateInToday(day.date)

    return HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        Text(DateFormatting.longDayFormatter.string(from: day.date))
          .font(.system(size: 24, weight: .bold))
        HStack(spacing: 8) {
          Text("\(start) → \(end)")
            .monospacedDigit()
          Text("·")
          Text(Self.modeLabel(for: day))
          if isRunning {
            Label("Tracking now", systemImage: "circle.fill")
              .labelStyle(.titleAndIcon)
              .foregroundStyle(.green)
              .imageScale(.small)
          }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
      }

      Spacer()

      HStack(spacing: 4) {
        Button { selectAdjacentDay(offset: -1) } label: { Image(systemName: "chevron.left") }
          .disabled(previousDay == nil)
          .help("Previous day")
        Button { selectAdjacentDay(offset: 1) } label: { Image(systemName: "chevron.right") }
          .disabled(nextDay == nil)
          .help("Next day")
        Menu {
          Button("Delete Day…", role: .destructive) { dayPendingDeletion = day }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
      }
      .controlSize(.large)
    }
  }

  private func tiles(_ metrics: DayMetrics) -> some View {
    let showMeetings = meetingSync.isConfigured
    return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
      StatTile(
        title: "Total",
        value: DurationFormatter.hoursMinutesRoundedUpToMinute(metrics.total),
        detail: "Start to finish",
        systemImage: "clock",
        tint: .primary
      )
      .help("From the first activity (Mac or meeting) to the last one.")

      StatTile(
        title: "Active",
        value: DurationFormatter.hoursMinutesRoundedUpToMinute(metrics.activeTime),
        detail: metrics.gapTime > 0 ? "\(DurationFormatter.hoursMinutes(metrics.gapTime)) in gaps" : "No gaps",
        systemImage: "bolt.fill",
        tint: TimelineBar.activeColor
      )
      .help("Total minus visible gaps. Time in meetings always counts as active.")

      if showMeetings {
        StatTile(
          title: "Meetings",
          value: DurationFormatter.hoursMinutes(metrics.meetingTime),
          detail: percentDetail(metrics, metrics.meetingTime),
          systemImage: "person.2.fill",
          tint: TimelineBar.meetingColor
        )
        .help("Calendar meetings, overlaps counted once — even when you were away from the Mac.")

        StatTile(
          title: "Focus",
          value: DurationFormatter.hoursMinutes(metrics.focusTime),
          detail: percentDetail(metrics, metrics.focusTime),
          systemImage: "scope",
          tint: .orange
        )
        .help("Active time outside meetings.")
      }
    }
  }

  private func timelineCard(_ metrics: DayMetrics) -> some View {
    Card(title: "Timeline") {
      VStack(alignment: .leading, spacing: 6) {
        TimelineBar(metrics: metrics)
          .frame(height: 28)
        TimelineAxis(span: metrics.span)
          .frame(height: 14)
      }
      HStack(spacing: 16) {
        LegendDot(color: TimelineBar.activeColor, label: "Active")
        if meetingSync.isConfigured {
          LegendDot(color: TimelineBar.meetingColor, label: "Meeting")
        }
        LegendDot(color: TimelineBar.gapColor, label: "Gap")
      }
    }
  }

  private func meetingsCard(_ metrics: DayMetrics) -> some View {
    let meetings = selectedMeetings
    return Card(
      title: "Meetings",
      subtitle: meetings.isEmpty ? nil : "\(meetings.count) · \(DurationFormatter.hoursMinutes(metrics.meetingTime))"
    ) {
      if meetingSync.access != .granted {
        Label("TrackThor has no access to your calendar. Allow it in Settings → Meetings.", systemImage: "calendar.badge.exclamationmark")
          .font(.callout)
          .foregroundStyle(.orange)
      } else if !meetingSync.isConfigured {
        Text("Turn on your work calendar in Settings → Meetings to track meeting time.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else if meetings.isEmpty {
        Text("No meetings")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(meetings.enumerated()), id: \.offset) { index, meeting in
            if index > 0 { Divider() }
            meetingRow(meeting, span: metrics.span)
          }
        }
      }
    }
  }

  private func meetingRow(_ meeting: Meeting, span: DateInterval) -> some View {
    let start = DateFormatting.timeFormatter.string(from: meeting.startedAt)
    let end = DateFormatting.timeFormatter.string(from: meeting.endedAt)
    let isUpcoming = meeting.startedAt >= span.end

    return HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: 1.5)
        .fill(TimelineBar.meetingColor)
        .frame(width: 3, height: 30)
      VStack(alignment: .leading, spacing: 2) {
        Text(meeting.title)
          .lineLimit(1)
        Text(isUpcoming ? "\(start) – \(end) · upcoming" : "\(start) – \(end)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(DurationFormatter.hoursMinutes(meeting.interval.duration))
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 6)
    .opacity(isUpcoming ? 0.5 : 1)
  }

  private func gapsCard(_ metrics: DayMetrics) -> some View {
    Card(
      title: "Gaps",
      subtitle: metrics.gaps.isEmpty ? nil : "\(metrics.gaps.count) · \(DurationFormatter.hoursMinutes(metrics.gapTime))"
    ) {
      if metrics.gaps.isEmpty {
        Text("No gaps longer than \(settings.minimumVisibleGapMinutes) min")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(metrics.gaps.enumerated()), id: \.offset) { index, gap in
            if index > 0 { Divider() }
            HStack(spacing: 10) {
              RoundedRectangle(cornerRadius: 1.5)
                .fill(TimelineBar.gapColor)
                .frame(width: 3, height: 20)
              Text("\(DateFormatting.timeFormatter.string(from: gap.start)) – \(DateFormatting.timeFormatter.string(from: gap.end))")
                .monospacedDigit()
              Spacer()
              Text(DurationFormatter.hoursMinutes(gap.duration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
          }
        }
      }
    }
    .help("Gaps shorter than \(settings.minimumVisibleGapMinutes) minutes are hidden. Time covered by meetings isn't a gap.")
  }

  private func percentDetail(_ metrics: DayMetrics, _ time: TimeInterval) -> String {
    metrics.percent(time).map { "\($0)% of the day" } ?? " "
  }

  // MARK: - Derived data

  private var selectedDay: WorkDay? {
    guard let selectedDate else { return nil }
    return workDays.first { $0.date == selectedDate }
  }

  private var selectedMeetings: [Meeting] {
    guard let selectedDay, meetingSync.isConfigured else { return [] }
    return meetingsByDay[dayKey(for: selectedDay.date)] ?? []
  }

  private var daysInDisplayedMonth: [WorkDay] {
    let calendar = Calendar.current
    return workDays
      .filter { calendar.isDate($0.date, equalTo: displayedMonth, toGranularity: .month) }
      .reversed()
  }

  private var monthSummary: String {
    let days = daysInDisplayedMonth
    guard !days.isEmpty else { return "No tracked days" }
    let metrics = days.map { dayMetrics(for: $0) }
    let total = metrics.reduce(0) { $0 + $1.total }
    var summary = "\(days.count) day\(days.count == 1 ? "" : "s") · \(DurationFormatter.hoursMinutes(total))"
    if meetingSync.isConfigured, total > 0 {
      let meetings = metrics.reduce(0) { $0 + $1.meetingTime }
      summary += " · \(Int((meetings / total * 100).rounded()))% meetings"
    }
    return summary
  }

  private var canShowPreviousMonth: Bool {
    guard let first = workDays.first?.date else { return false }
    return displayedMonth > Self.monthStart(of: first)
  }

  private var canShowNextMonth: Bool {
    displayedMonth < Self.monthStart(of: Date())
  }

  private var selectedDayIndex: Int? {
    guard let selectedDate else { return nil }
    return workDays.firstIndex { $0.date == selectedDate }
  }

  private var previousDay: WorkDay? {
    guard let index = selectedDayIndex, index > 0 else { return nil }
    return workDays[index - 1]
  }

  private var nextDay: WorkDay? {
    guard let index = selectedDayIndex, index < workDays.count - 1 else { return nil }
    return workDays[index + 1]
  }

  private func visibleGaps(for day: WorkDay) -> [Gap] {
    guard let id = day.id else { return [] }
    let threshold = settings.minimumVisibleGapDuration
    return (gapsByDay[id] ?? []).filter { $0.endedAt.timeIntervalSince($0.startedAt) >= threshold }
  }

  private func dayMetrics(for day: WorkDay) -> DayMetrics {
    let dayStart = Calendar.current.startOfDay(for: day.date)
    let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? now
    let dayMeetings = meetingSync.isConfigured ? (meetingsByDay[dayKey(for: day.date)] ?? []) : []
    return DayMetrics(
      tracked: IntervalMath.make(DateFormatting.floorToMinute(day.startedAt), effectiveEnd(for: day)),
      visibleGaps: visibleGaps(for: day).map(\.interval),
      meetings: dayMeetings.map(\.interval),
      limit: min(now, dayEnd),
      minimumGap: settings.minimumVisibleGapDuration
    )
  }

  private func effectiveEnd(for day: WorkDay) -> Date {
    if let endedAt = day.endedAt {
      return endedAt
    }
    let calendar = Calendar.current
    if calendar.startOfDay(for: day.date) < calendar.startOfDay(for: now),
       let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day.date))?.addingTimeInterval(-1)
    {
      return dayEnd
    }
    return now
  }

  // MARK: - Actions

  private func shiftMonth(by offset: Int) {
    guard let month = Calendar.current.date(byAdding: .month, value: offset, to: displayedMonth) else { return }
    displayedMonth = month
    let calendar = Calendar.current
    if let latest = workDays.last(where: { calendar.isDate($0.date, equalTo: month, toGranularity: .month) }) {
      selectedDate = latest.date
    }
  }

  private func selectLatestDay() {
    selectedDate = workDays.last?.date
    if let selectedDate {
      displayedMonth = Self.monthStart(of: selectedDate)
    }
  }

  private func selectAdjacentDay(offset: Int) {
    guard let index = selectedDayIndex, workDays.indices.contains(index + offset) else { return }
    selectedDate = workDays[index + offset].date
  }

  private func reloadData(selectLatestIfNeeded: Bool) {
    let dbQueue = database.dbQueue

    reloadTask?.cancel()
    reloadTask = Task {
      do {
        let (loadedDays, loadedMeetings, loadedGaps) = try await Task.detached(priority: .utility) {
          try dbQueue.read { db in
            let days = try WorkDay.order(WorkDay.Columns.date.asc).fetchAll(db)
            let meetings = try Meeting.meetingsOnly.order(Meeting.Columns.startedAt.asc).fetchAll(db)
            let gaps = try Gap.order(Gap.Columns.startedAt.asc).fetchAll(db)
            return (days, meetings, gaps)
          }
        }.value

        guard !Task.isCancelled else { return }
        workDays = loadedDays
        meetingsByDay = Dictionary(grouping: loadedMeetings) { dayKey(for: $0.date) }
        gapsByDay = Dictionary(grouping: loadedGaps, by: \.workDayId)

        let selectionStillExists = selectedDate.map { date in loadedDays.contains { $0.date == date } } ?? false
        if selectLatestIfNeeded || !selectionStillExists {
          selectLatestDay()
        }
      } catch {
        guard !Task.isCancelled else { return }
        workDays = []
        gapsByDay = [:]
        selectedDate = nil
      }
    }
  }

  private var deleteAlertBinding: Binding<Bool> {
    Binding(
      get: { dayPendingDeletion != nil },
      set: { if !$0 { dayPendingDeletion = nil } }
    )
  }

  private func deleteSelectedDay() {
    guard let day = dayPendingDeletion, let id = day.id else { return }
    let dbQueue = database.dbQueue
    dayPendingDeletion = nil

    reloadTask?.cancel()
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

      // The engine caches today's record; let it drop the deleted row instead of writing to it.
      trackingEngine.reloadAfterExternalChange()
      if selectedDate == day.date {
        selectedDate = nil
      }
      reloadData(selectLatestIfNeeded: false)
    }
  }

  // MARK: - Formatting

  private func dayKey(for date: Date) -> String {
    DateFormatting.dayKeyFormatter.string(from: Calendar.current.startOfDay(for: date))
  }

  private static func monthStart(of date: Date) -> Date {
    Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
  }

  private static func monthTitle(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("LLLL yyyy")
    return formatter.string(from: date)
  }

  private static func shortDay(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEE d")
    return formatter.string(from: date)
  }

  private static func modeIcon(for day: WorkDay) -> String {
    if day.hasMixedLocations { return "🔀" }
    return day.mode == .manual ? "🏠" : "🏢"
  }

  private static func modeLabel(for day: WorkDay) -> String {
    if day.hasMixedLocations { return "🔀 Home + Office" }
    return day.mode == .manual ? "🏠 Home" : "🏢 Office"
  }
}
