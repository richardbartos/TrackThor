import Combine
import Foundation
import GRDB

@MainActor
final class TrackingEngine: ObservableObject {
  struct TodayStatus {
    var workDay: WorkDay?
    var isActive: Bool
    var mode: WorkDay.Mode?
  }

  private enum TrackingState: Equatable {
    case stopped
    case active(WorkDay.Mode)
    case gap(WorkDay.Mode)
  }

  private enum TrackingEvent {
    case startup(Date)
    case conditionsChanged(Date)
    case manualStart(Date)
    case stop(Date)
    case midnight(Date)
  }

  struct DaySnapshot: Sendable {
    var workDay: WorkDay?
    var gapDuration: TimeInterval
  }

  @Published private(set) var todayWorkDay: WorkDay?
  @Published private(set) var isManualActive: Bool = false
  @Published private(set) var isAutoActive: Bool = false
  @Published private(set) var todayGapDuration: TimeInterval = 0

  var onStatusChanged: ((String, Bool) -> Void)?

  private let database: DatabaseManager
  private let settings: AppSettings
  private let wifiMonitor: WiFiMonitor
  private let screenMonitor: ScreenMonitor

  private let locationPermission = LocationPermissionManager()
  private var cancellables: Set<AnyCancellable> = []
  private var statusTimer: Timer?
  private var midnightTimer: Timer?
  private var eventTask: Task<Void, Never>?
  private var state: TrackingState = .stopped
  private var autoTrackingSuppressed = false
  private var lastEventAt: Date?

  private let presenceIdleThreshold: TimeInterval = 60
  private let missedGapThreshold: TimeInterval = 30

  init(
    settings: AppSettings,
    database: DatabaseManager,
    wifiMonitor: WiFiMonitor,
    screenMonitor: ScreenMonitor
  ) {
    self.database = database
    self.settings = settings
    self.wifiMonitor = wifiMonitor
    self.screenMonitor = screenMonitor
  }

  func start() {
    locationPermission.requestIfNeeded()

    wifiMonitor.start()
    screenMonitor.start()

    cancellables.removeAll()
    wifiMonitor.$isOnWorkWiFi
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.enqueue(.conditionsChanged(Date()))
      }
      .store(in: &cancellables)
    screenMonitor.$isScreenUnlocked
      .receive(on: DispatchQueue.main)
      .sink { [weak self] isUnlocked in
        if isUnlocked {
          self?.wifiMonitor.refreshAfterWakeOrUnlock()
        }
        self?.enqueue(.conditionsChanged(Date()))
      }
      .store(in: &cancellables)
    screenMonitor.$isSystemSleeping
      .receive(on: DispatchQueue.main)
      .sink { [weak self] isSleeping in
        if !isSleeping {
          self?.wifiMonitor.refreshAfterWakeOrUnlock()
        }
        self?.enqueue(.conditionsChanged(Date()))
      }
      .store(in: &cancellables)
    screenMonitor.$isDisplaySleeping
      .receive(on: DispatchQueue.main)
      .sink { [weak self] isDisplaySleeping in
        if !isDisplaySleeping {
          self?.wifiMonitor.refreshAfterWakeOrUnlock()
        }
        self?.enqueue(.conditionsChanged(Date()))
      }
      .store(in: &cancellables)
    screenMonitor.$isLidClosed
      .receive(on: DispatchQueue.main)
      .sink { [weak self] isLidClosed in
        if !isLidClosed {
          self?.wifiMonitor.refreshAfterWakeOrUnlock()
        }
        self?.enqueue(.conditionsChanged(Date()))
      }
      .store(in: &cancellables)

    statusTimer?.invalidate()
    statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.screenMonitor.reconcileCurrentState()
        self?.wifiMonitor.poll()
        self?.enqueue(.conditionsChanged(Date()))
        self?.updateStatusTitle()
      }
    }

    scheduleMidnightTimer(after: Date())
    enqueue(.startup(Date()))
  }

  func stop() {
    wifiMonitor.stop()
    screenMonitor.stop()
    statusTimer?.invalidate()
    midnightTimer?.invalidate()
    statusTimer = nil
    midnightTimer = nil
    cancellables.removeAll()
    eventTask?.cancel()
    eventTask = nil
  }

  func startManualDay() {
    enqueue(.manualStart(Date()))
  }

  func stopTracking() {
    enqueue(.stop(Date()))
  }

  private func enqueue(_ event: TrackingEvent) {
    let previousTask = eventTask
    eventTask = Task { @MainActor [weak self] in
      _ = await previousTask?.value
      guard let self else { return }
      await self.handle(event)
    }
  }

  private func handle(_ event: TrackingEvent) async {
    let eventDate = date(for: event)
    await reconcileMissedGapIfNeeded(at: eventDate)

    switch event {
    case .startup(let now):
      await advanceToCurrentDayIfNeeded(at: now)
      await bootstrap(at: now)
    case .conditionsChanged(let now):
      await advanceToCurrentDayIfNeeded(at: now)
      await processConditionsChanged(at: now)
    case .manualStart(let now):
      await advanceToCurrentDayIfNeeded(at: now)
      await processManualStart(at: now)
    case .stop(let now):
      await advanceToCurrentDayIfNeeded(at: now)
      await processStop(at: now)
    case .midnight(let boundary):
      await processMidnight(at: boundary)
    }

    lastEventAt = eventDate
  }

  private func date(for event: TrackingEvent) -> Date {
    switch event {
    case .startup(let now),
         .conditionsChanged(let now),
         .manualStart(let now),
         .stop(let now),
         .midnight(let now):
      return now
    }
  }

  private func reconcileMissedGapIfNeeded(at now: Date) async {
    guard let lastEventAt else { return }
    guard now.timeIntervalSince(lastEventAt) > missedGapThreshold else { return }
    guard case .active(let mode) = state else { return }

    await endCurrentDay(at: lastEventAt)
    state = .gap(mode)
    refreshPublishedActivity()
  }

  private func advanceToCurrentDayIfNeeded(at now: Date) async {
    let calendar = Calendar.current
    let dayStart = calendar.startOfDay(for: now)

    guard let currentDay = todayWorkDay, currentDay.date < dayStart else {
      scheduleMidnightTimer(after: now)
      return
    }

    let carriedMode = carriedModeAcrossDayBoundary(from: state)
    let previousDayEnd = dayStart.addingTimeInterval(-1)
    autoTrackingSuppressed = false

    if currentDay.endedAt == nil {
      await endCurrentDay(at: previousDayEnd)
    }

    let snapshot = await loadSnapshot(for: now)
    applySnapshot(snapshot)
    state = snapshot.workDay.map(derivedState(for:)) ?? carriedMode

    scheduleMidnightTimer(after: now)
  }

  private func bootstrap(at now: Date) async {
    await reconcileStaleOpenDays(at: now)
    applySnapshot(await loadSnapshot(for: now))
    state = derivedState(for: todayWorkDay)

    if case .active(let mode) = state,
       let day = todayWorkDay,
       let lastActivityAt = day.lastActivityAt,
       now.timeIntervalSince(lastActivityAt) > missedGapThreshold
    {
      await endCurrentDay(at: Self.boundedEnd(lastActivityAt, for: day))
      state = .gap(mode)
    }

    if case .active(let mode) = state, !conditionsMet(for: mode) {
      await endCurrentDay(at: endDateForCurrentActiveLoss(at: now))
      state = .gap(mode)
    }

    await processConditionsChanged(at: now)
    scheduleMidnightTimer(after: now)
  }

  private func reconcileStaleOpenDays(at now: Date) async {
    let calendar = Calendar.current
    let currentDayStart = calendar.startOfDay(for: now)

    do {
      try await writeToDatabase { db in
        let staleDays = try WorkDay
          .filter(WorkDay.Columns.endedAt == nil && WorkDay.Columns.date < currentDayStart)
          .fetchAll(db)

        for var day in staleDays {
          guard let nextDayStart = calendar.date(byAdding: .day, value: 1, to: day.date) else {
            continue
          }

          let dayEnd = nextDayStart.addingTimeInterval(-1)
          day.endedAt = Self.boundedEnd(day.lastActivityAt ?? day.startedAt, for: day, latest: dayEnd)
          try day.update(db)
        }
      }
    } catch {
      return
    }
  }

  private func processConditionsChanged(at now: Date) async {
    let autoConditionsMet = conditionsMet(for: .auto)

    if !autoConditionsMet {
      autoTrackingSuppressed = false
    }

    switch state {
    case .active(.auto):
      if !autoConditionsMet {
        await endCurrentDay(at: endDateForCurrentActiveLoss(at: now))
        state = .gap(.auto)
      } else {
        await recordActiveHeartbeat(at: now)
      }

    case .active(.manual):
      if !conditionsMet(for: .manual) {
        await endCurrentDay(at: endDateForCurrentActiveLoss(at: now))
        state = .gap(.manual)
      } else {
        await recordActiveHeartbeat(at: now)
      }

    case .gap(.auto):
      if autoConditionsMet && !autoTrackingSuppressed {
        await activateTracking(mode: .auto, at: now)
        state = .active(.auto)
      }

    case .gap(.manual):
      if conditionsMet(for: .manual) {
        await activateTracking(mode: .manual, at: now)
        state = .active(.manual)
      }

    case .stopped:
      if autoConditionsMet && !autoTrackingSuppressed {
        await activateTracking(mode: .auto, at: now)
        state = .active(.auto)
      }
    }

    refreshPublishedActivity()
    updateStatusTitle()
  }

  private func processManualStart(at now: Date) async {
    autoTrackingSuppressed = true

    switch state {
    case .active(.manual):
      return

    case .active(.auto):
      await endCurrentDay(at: now)
      await activateTracking(mode: .manual, at: now)
      state = .active(.manual)
      refreshPublishedActivity()
      updateStatusTitle()
      return

    case .gap, .stopped:
      await activateTracking(mode: .manual, at: now)
      state = .active(.manual)
      refreshPublishedActivity()
      updateStatusTitle()
    }
  }

  private func processStop(at now: Date) async {
    guard case .active = state else { return }

    autoTrackingSuppressed = true
    await endCurrentDay(at: now)
    state = .stopped
    refreshPublishedActivity()
    updateStatusTitle()
  }

  private func processMidnight(at boundary: Date) async {
    await advanceToCurrentDayIfNeeded(at: boundary)
    scheduleMidnightTimer(after: boundary)
    await processConditionsChanged(at: boundary)
  }

  private func activateTracking(mode: WorkDay.Mode, at now: Date) async {
    let calendar = Calendar.current
    let dayStart = calendar.startOfDay(for: now)

    if todayWorkDay?.date != dayStart {
      applySnapshot(await loadSnapshot(for: now))
    }

    guard let existingDay = todayWorkDay else {
      let newDay = WorkDay(
        id: nil,
        date: dayStart,
        startedAt: now,
        endedAt: nil,
        lastActivityAt: now,
        mode: mode,
        hasMixedLocations: false
      )

      do {
      let insertedDay = try await writeToDatabase { db in
          let day = newDay
          try day.insert(db)
          return day
        }
        todayWorkDay = insertedDay
        todayGapDuration = 0
      } catch {
        return
      }
      return
    }

    guard existingDay.endedAt != nil else {
      if existingDay.mode == .manual && mode == .auto {
        return
      }
      return
    }

    do {
      let reopened = try await writeToDatabase { db in
        var day = existingDay
        let gapStart = day.endedAt ?? now
        if let workDayId = day.id, now > gapStart {
          let gap = Gap(id: nil, workDayId: workDayId, startedAt: gapStart, endedAt: now)
          try gap.insert(db)
        }
        day.endedAt = nil
        day.lastActivityAt = now
        day.hasMixedLocations = day.hasMixedLocations || day.mode != mode
        day.mode = mode
        try day.update(db)
        return day
      }
      if let endedAt = existingDay.endedAt {
        let duration = max(0, now.timeIntervalSince(endedAt))
        if duration >= settings.minimumVisibleGapDuration {
          todayGapDuration += duration
        }
      }
      todayWorkDay = reopened
    } catch {
      return
    }
  }

  private func endCurrentDay(at now: Date) async {
    guard let currentDay = todayWorkDay, currentDay.endedAt == nil else { return }

    do {
      let updatedDay = try await writeToDatabase { db in
        var day = currentDay
        day.endedAt = now
        try day.update(db)
        return day
      }
      todayWorkDay = updatedDay
    } catch {
      return
    }
  }

  private func recordActiveHeartbeat(at now: Date) async {
    guard let currentDay = todayWorkDay, currentDay.endedAt == nil else { return }

    do {
      let updatedDay = try await writeToDatabase { db in
        var day = currentDay
        day.lastActivityAt = now
        try day.update(db)
        return day
      }
      todayWorkDay = updatedDay
    } catch {
      return
    }
  }

  private func inactiveStartedAt(for now: Date) -> Date {
    guard screenMonitor.idleDuration >= presenceIdleThreshold else { return now }
    let thresholdCrossedAt = now
      .addingTimeInterval(-screenMonitor.idleDuration)
      .addingTimeInterval(presenceIdleThreshold)
    return min(now, thresholdCrossedAt)
  }

  private func endDateForCurrentActiveLoss(at now: Date) -> Date {
    guard
      let day = todayWorkDay,
      let lastActivityAt = day.lastActivityAt,
      now.timeIntervalSince(lastActivityAt) > missedGapThreshold
    else {
      return inactiveStartedAt(for: now)
    }

    return Self.boundedEnd(lastActivityAt, for: day)
  }

  nonisolated private static func boundedEnd(_ date: Date, for day: WorkDay, latest: Date? = nil) -> Date {
    let latestDate = latest ?? .distantFuture
    return min(max(date, day.startedAt), latestDate)
  }

  private func loadSnapshot(for referenceDate: Date) async -> DaySnapshot {
    let dayStart = Calendar.current.startOfDay(for: referenceDate)
    let visibleGapThreshold = settings.minimumVisibleGapDuration

    do {
      return try await readFromDatabase { db in
        let day = try WorkDay.filter(WorkDay.Columns.date == dayStart).fetchOne(db)
        guard let day, let workDayId = day.id else {
          return DaySnapshot(workDay: day, gapDuration: 0)
        }

        let gaps = try Gap
          .filter(Gap.Columns.workDayId == workDayId)
          .fetchAll(db)
        let totalGapDuration = gaps.reduce(into: 0) { total, gap in
          let duration = gap.endedAt.timeIntervalSince(gap.startedAt)
          if duration >= visibleGapThreshold {
            total += duration
          }
        }
        return DaySnapshot(workDay: day, gapDuration: totalGapDuration)
      }
    } catch {
      return DaySnapshot(workDay: nil, gapDuration: 0)
    }
  }

  private func applySnapshot(_ snapshot: DaySnapshot) {
    todayWorkDay = snapshot.workDay
    todayGapDuration = snapshot.gapDuration
    refreshPublishedActivity()
  }

  private func derivedState(for day: WorkDay?) -> TrackingState {
    guard let day else { return .stopped }
    if day.endedAt == nil {
      return .active(day.mode)
    }
    if day.mode == .auto {
      return .gap(.auto)
    }
    return .stopped
  }

  private func carriedModeAcrossDayBoundary(from state: TrackingState) -> TrackingState {
    switch state {
    case .active(let mode), .gap(let mode):
      return .gap(mode)
    case .stopped:
      return .stopped
    }
  }

  private func refreshPublishedActivity() {
    if let day = todayWorkDay, day.endedAt == nil {
      isManualActive = (day.mode == .manual)
      isAutoActive = (day.mode == .auto)
    } else {
      isManualActive = false
      isAutoActive = false
    }
  }

  private func conditionsMet(for mode: WorkDay.Mode) -> Bool {
    let isPresent = screenMonitor.idleDuration < presenceIdleThreshold

    switch mode {
    case .manual:
      return screenMonitor.isScreenUnlocked && !screenMonitor.isSystemSleeping && !screenMonitor.isDisplaySleeping && !screenMonitor.isLidClosed && isPresent
    case .auto:
      return screenMonitor.isScreenUnlocked && !screenMonitor.isSystemSleeping && !screenMonitor.isDisplaySleeping && !screenMonitor.isLidClosed && wifiMonitor.isOnWorkWiFi && isPresent
    }
  }

  private func scheduleMidnightTimer(after referenceDate: Date) {
    midnightTimer?.invalidate()

    let calendar = Calendar.current
    guard let nextMidnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: referenceDate)) else {
      return
    }

    midnightTimer = Timer(fire: nextMidnight, interval: 0, repeats: false) { [weak self] _ in
      Task { @MainActor in
        self?.enqueue(.midnight(nextMidnight))
      }
    }

    if let midnightTimer {
      RunLoop.main.add(midnightTimer, forMode: .common)
    }
  }

  private func updateStatusTitle() {
    let title: String
    if let day = todayWorkDay {
      let start = DateFormatting.timeFormatter.string(from: DateFormatting.floorToMinute(day.startedAt))
      if let end = day.endedAt {
        let endString = DateFormatting.timeFormatter.string(from: DateFormatting.floorToMinute(end))
        title = prefix(for: day) + "\(start) → \(endString)"
      } else {
        let endString = DateFormatting.timeFormatter.string(from: DateFormatting.floorToMinute(Date()))
        title = prefix(for: day) + "\(start) → \(endString)"
      }
    } else {
      title = "--:--"
    }

    onStatusChanged?(title, isTrackingActive)
  }

  private var isTrackingActive: Bool {
    isManualActive || isAutoActive
  }

  private func prefix(for day: WorkDay) -> String {
    if day.hasMixedLocations {
      return "🔀 "
    }

    switch day.mode {
    case .manual:
      return "🏠 "
    case .auto:
      return ""
    }
  }

  private func readFromDatabase<T: Sendable>(
    _ block: @escaping @Sendable (Database) throws -> T
  ) async throws -> T {
    let dbQueue = database.dbQueue
    return try await Task.detached(priority: .utility) {
      try dbQueue.read { db in
        try block(db)
      }
    }.value
  }

  private func writeToDatabase<T: Sendable>(
    _ block: @escaping @Sendable (Database) throws -> T
  ) async throws -> T {
    let dbQueue = database.dbQueue
    return try await Task.detached(priority: .utility) {
      try dbQueue.write { db in
        try block(db)
      }
    }.value
  }
}
