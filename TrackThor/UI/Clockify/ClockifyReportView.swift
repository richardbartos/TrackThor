import SwiftUI

@MainActor
final class ClockifyReportModel: ObservableObject {
  @Published var month: Date
  @Published var plans: [ClockifyDayPlan] = []
  @Published private(set) var statuses: [Date: ClockifyService.DayStatus] = [:]
  @Published private(set) var isLoading = false
  @Published private(set) var hasLoaded = false
  @Published private(set) var busyDays: Set<Date> = []
  @Published private(set) var isPushingAll = false
  @Published var message: String?
  @Published var errorMessage: String?

  let service: ClockifyService

  init(service: ClockifyService) {
    self.service = service
    // Monthly reporting is usually for the previous month.
    let calendar = Calendar.current
    let thisMonth = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
    self.month = calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth
  }

  var selectedPlans: [ClockifyDayPlan] { plans.filter(\.include) }

  func shiftMonth(by offset: Int) {
    guard let shifted = Calendar.current.date(byAdding: .month, value: offset, to: month) else { return }
    month = shifted
    Task { await reload() }
  }

  func reload() async {
    hasLoaded = true
    isLoading = true
    errorMessage = nil
    message = nil
    defer { isLoading = false }

    do {
      plans = try await service.plans(forMonthContaining: month)
    } catch {
      plans = []
      errorMessage = error.localizedDescription
      return
    }

    await reloadStatuses(adjustSelection: true)
  }

  /// Days that are already in Clockify start deselected: pushed by TrackThor (re-push is a deliberate
  /// choice) or entered some other way (pushing would double them).
  private func reloadStatuses(adjustSelection: Bool) async {
    guard service.isReadyToPush else {
      statuses = [:]
      return
    }
    do {
      statuses = try await service.statuses(forMonthContaining: month)
      if adjustSelection {
        for index in plans.indices {
          let status = statuses[plans[index].date]
          if (status?.other ?? 0) > 0 || (status?.pushed ?? 0) > 0 {
            plans[index].include = false
          }
        }
      }
    } catch {
      errorMessage = "Couldn't read existing Clockify entries: \(error.localizedDescription)"
    }
  }

  func push(_ date: Date) async {
    guard let plan = plans.first(where: { $0.date == date }) else { return }
    busyDays.insert(date)
    defer { busyDays.remove(date) }
    do {
      try await service.push(plan)
      deselect(date)
      message = "Pushed \(Self.dayLabel(date))."
      errorMessage = nil
    } catch {
      errorMessage = "\(Self.dayLabel(date)): \(error.localizedDescription)"
    }
    await reloadStatuses(adjustSelection: false)
  }

  func deletePushed(_ date: Date) async {
    busyDays.insert(date)
    defer { busyDays.remove(date) }
    do {
      try await service.deletePushedEntries(for: date)
      message = "Removed TrackThor's entries for \(Self.dayLabel(date))."
      errorMessage = nil
    } catch {
      errorMessage = "\(Self.dayLabel(date)): \(error.localizedDescription)"
    }
    await reloadStatuses(adjustSelection: false)
  }

  func pushSelected() async {
    let days = selectedPlans.map(\.date)
    guard !days.isEmpty else { return }
    isPushingAll = true
    defer { isPushingAll = false }

    var failures: [String] = []
    for day in days {
      busyDays.insert(day)
      if let plan = plans.first(where: { $0.date == day }) {
        do {
          try await service.push(plan)
          deselect(day)
        } catch {
          failures.append("\(Self.dayLabel(day)): \(error.localizedDescription)")
        }
      }
      busyDays.remove(day)
    }

    if failures.isEmpty {
      message = "Pushed \(days.count) day\(days.count == 1 ? "" : "s") to Clockify."
      errorMessage = nil
    } else {
      message = "Pushed \(days.count - failures.count) of \(days.count) days."
      errorMessage = failures.joined(separator: "\n")
    }
    await reloadStatuses(adjustSelection: false)
  }

  private func deselect(_ date: Date) {
    if let index = plans.firstIndex(where: { $0.date == date }) {
      plans[index].include = false
    }
  }

  static func dayLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
    return formatter.string(from: date)
  }
}

struct ClockifyReportView: View {
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject var model: ClockifyReportModel
  @ObservedObject var service: ClockifyService
  let onOpenSettings: () -> Void

  @State private var confirmPushAll = false

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.horizontal, 18)
        .padding(.vertical, 14)

      Divider()

      content

      Divider()

      footer
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
    .navigationTitle("Clockify Report")
    // Keep edits when switching pages; only load the first time (Reload button for later).
    .task {
      if !model.hasLoaded {
        await model.reload()
      }
    }
    .confirmationDialog(
      "Push \(model.selectedPlans.count) day\(model.selectedPlans.count == 1 ? "" : "s") to Clockify?",
      isPresented: $confirmPushAll
    ) {
      Button("Push to Clockify") {
        Task { await model.pushSelected() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Days that were pushed before are replaced. Entries you added in Clockify yourself are never changed.")
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      Button { model.shiftMonth(by: -1) } label: { Image(systemName: "chevron.left") }
      Text(monthTitle)
        .font(.system(size: 17, weight: .semibold))
        .frame(minWidth: 160)
      Button { model.shiftMonth(by: 1) } label: { Image(systemName: "chevron.right") }
        .disabled(isCurrentOrFutureMonth)

      Spacer()

      if !service.isReadyToPush {
        Label("Set up Clockify in Settings to push", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .font(.caption)
        Button("Set Up Clockify", action: onOpenSettings)
      }

      Button {
        Task { await model.reload() }
      } label: {
        Label("Reload", systemImage: "arrow.clockwise")
      }
      .disabled(model.isLoading || model.isPushingAll)
    }
  }

  // MARK: - Days

  @ViewBuilder
  private var content: some View {
    if model.isLoading && model.plans.isEmpty {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.plans.isEmpty {
      VStack(spacing: 6) {
        Text("No finished work days in \(monthTitle).")
          .font(.headline)
        Text("Only days that are over are reported; today is left out.")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        LazyVStack(spacing: 10) {
          ForEach($model.plans) { $plan in
            dayRow($plan)
          }
        }
        .padding(16)
      }
    }
  }

  private func dayRow(_ plan: Binding<ClockifyDayPlan>) -> some View {
    let day = plan.wrappedValue
    let status = model.statuses[day.date]
    let isBusy = model.busyDays.contains(day.date)

    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Toggle("", isOn: plan.include)
          .labelsHidden()
          .toggleStyle(.checkbox)

        Text(ClockifyReportModel.dayLabel(day.date))
          .font(.system(size: 14, weight: .semibold))
          .frame(width: 96, alignment: .leading)

        Text("Worked \(time(day.actualStart)) → \(time(day.actualEnd)) · reported \(time(day.start)) → \(time(day.end))")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)

        Spacer()

        statusBadges(day: day, status: status)
      }

      HStack(spacing: 16) {
        minutesStepper("MEETING", minutes: plan.meetingMinutes, color: .purple)
        minutesStepper("R&D", minutes: plan.workMinutes, color: .blue)

        Toggle("Lunch −30m", isOn: Binding(
          get: { plan.wrappedValue.deductLunch },
          set: { plan.wrappedValue.setDeductLunch($0) }
        ))
        .toggleStyle(.checkbox)
        .help(day.lunchCoveredByOutOfOffice ? "OOO already covers lunch time (11:00–14:00)." : "30 minutes lunch is deducted every day.")

        Spacer()

        Text("Total \(DurationFormatter.hoursMinutes(fromMinutes: day.totalMinutes))")
          .font(.system(size: 13, weight: .semibold))
      }

      HStack(spacing: 14) {
        Text(entriesSummary(day))
          .font(.caption)
          .foregroundStyle(.secondary)

        Spacer()

        if day.isEdited {
          Button("Reset") { plan.wrappedValue.resetEdits() }
            .buttonStyle(.borderless)
        }
        if isBusy {
          ProgressView().controlSize(.small)
        }
        Button("Delete pushed") {
          Task { await model.deletePushed(day.date) }
        }
        .disabled(isBusy || model.isPushingAll || (status?.pushed ?? 0) == 0)

        Button("Push this day") {
          Task { await model.push(day.date) }
        }
        .disabled(isBusy || model.isPushingAll || !service.isReadyToPush || day.entries.isEmpty)
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.primary.opacity(day.include ? 0.12 : 0.05), lineWidth: 1)
    )
    .opacity(day.include ? 1 : 0.6)
  }

  @ViewBuilder
  private func statusBadges(day: ClockifyDayPlan, status: ClockifyService.DayStatus?) -> some View {
    HStack(spacing: 6) {
      if day.isWholeDayOutOfOffice {
        badge("Whole day OOO — skipped", color: .orange)
      } else if day.oooMinutes > 0 {
        badge("OOO −\(DurationFormatter.hoursMinutes(fromMinutes: day.oooMinutes))", color: .orange)
      }
      if day.gapTime >= 60 {
        badge("Gaps \(DurationFormatter.hoursMinutes(day.gapTime))", color: .gray)
      }
      if let status, status.other > 0 {
        badge("\(status.other) other entr\(status.other == 1 ? "y" : "ies") in Clockify", color: .red)
      }
      if let status, status.pushed > 0 {
        badge("Pushed", color: .green)
      }
      if day.isEdited {
        badge("Edited", color: .blue)
      }
    }
  }

  private func badge(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.system(size: 11, weight: .medium))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Capsule().fill(color.opacity(0.15)))
      .foregroundStyle(color)
  }

  private func minutesStepper(_ label: String, minutes: Binding<Int>, color: Color) -> some View {
    Stepper(value: minutes, in: 0...(24 * 60), step: 15) {
      HStack(spacing: 6) {
        Circle().fill(color).frame(width: 8, height: 8)
        Text(label)
          .font(.system(size: 12, weight: .semibold))
        Text(DurationFormatter.hoursMinutes(fromMinutes: minutes.wrappedValue))
          .font(.system(size: 13).monospacedDigit())
          .frame(minWidth: 52, alignment: .leading)
      }
    }
  }

  private func entriesSummary(_ day: ClockifyDayPlan) -> String {
    let parts = day.entries.map { entry in
      let name = entry.category == .meeting
        ? service.projectName(settings.clockifyMeetingProjectId)
        : service.projectName(settings.clockifyWorkProjectId)
      let fallback = entry.category == .meeting ? "MEETING" : "R&D"
      return "\(name == "—" ? fallback : name)  \(time(entry.start))–\(time(entry.end))"
    }
    return parts.isEmpty ? "Nothing to push" : parts.joined(separator: "   ·   ")
  }

  // MARK: - Footer

  private var footer: some View {
    let selected = model.selectedPlans
    let meeting = selected.reduce(0) { $0 + $1.meetingMinutes }
    let work = selected.reduce(0) { $0 + $1.workMinutes }

    return HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text("\(selected.count) of \(model.plans.count) days selected · MEETING \(DurationFormatter.hoursMinutes(fromMinutes: meeting)) · R&D \(DurationFormatter.hoursMinutes(fromMinutes: work)) · Total \(DurationFormatter.hoursMinutes(fromMinutes: meeting + work))")
          .font(.system(size: 12, weight: .medium))
        if let error = model.errorMessage {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(3)
        } else if let message = model.message {
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("Rounded to 15 min · lunch −30m unless OOO covers it · OOO time removed. Use “Push this day” to test.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer()

      if model.isPushingAll {
        ProgressView().controlSize(.small)
      }
      Button("Push \(selected.count) day\(selected.count == 1 ? "" : "s")") {
        confirmPushAll = true
      }
      .buttonStyle(.borderedProminent)
      .disabled(selected.isEmpty || model.isPushingAll || !service.isReadyToPush)
    }
  }

  // MARK: - Formatting

  private var monthTitle: String {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("LLLL yyyy")
    return formatter.string(from: model.month)
  }

  private var isCurrentOrFutureMonth: Bool {
    let calendar = Calendar.current
    let thisMonth = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
    return model.month >= thisMonth
  }

  private func time(_ date: Date) -> String {
    DateFormatting.timeFormatter.string(from: date)
  }
}
