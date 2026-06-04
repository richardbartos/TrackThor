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
  private var statusTask: Task<Void, Never>?
  private var midnightTimer: Timer?
  private var eventTask: Task<Void, Never>?
  private var state: TrackingState = .stopped
  private var autoTrackingSuppressed = false
  private var lastEventAt: Date?
  private let debugLog = TrackingDebugLog()
  private var lastConditionLogAt: Date?
  private var lastHeartbeatLogAt: Date?

  private let missedGapThreshold: TimeInterval = 30
  private var presenceIdleThreshold: TimeInterval {
    max(60, settings.minimumVisibleGapDuration)
  }

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
    debugLog.write("engine.start presenceIdleThreshold=\(presenceIdleThreshold)s missedGapThreshold=\(missedGapThreshold)s minimumVisibleGap=\(settings.minimumVisibleGapDuration)s log=\(debugLog.filePath)")
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

    statusTask?.cancel()
    statusTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        self?.tick()
        try? await Task.sleep(nanoseconds: 5_000_000_000)
      }
    }

    scheduleMidnightTimer(after: Date())
    enqueue(.startup(Date()))
  }

  func stop() {
    debugLog.write("engine.stop state=\(debugDescription(for: state)) day=\(debugDescription(for: todayWorkDay))")
    wifiMonitor.stop()
    screenMonitor.stop()
    statusTask?.cancel()
    midnightTimer?.invalidate()
    statusTask = nil
    midnightTimer = nil
    cancellables.removeAll()
    eventTask?.cancel()
    eventTask = nil
  }

  private func tick() {
    screenMonitor.reconcileCurrentState()
    wifiMonitor.poll()
    enqueue(.conditionsChanged(Date()))
    updateStatusTitle()
  }

  func startManualDay() {
    enqueue(.manualStart(Date()))
  }

  func stopTracking() {
    enqueue(.stop(Date()))
  }

  private func enqueue(_ event: TrackingEvent) {
    if shouldLogEvent(event) {
      debugLog.write("event.enqueue \(debugDescription(for: event)) state=\(debugDescription(for: state))")
    }
    let previousTask = eventTask
    eventTask = Task { @MainActor [weak self] in
      _ = await previousTask?.value
      guard let self else { return }
      await self.handle(event)
    }
  }

  private func handle(_ event: TrackingEvent) async {
    let eventDate = date(for: event)
    let previousState = state
    if shouldLogEvent(event) {
      debugLog.write("event.begin \(debugDescription(for: event)) state=\(debugDescription(for: state)) day=\(debugDescription(for: todayWorkDay))")
    }

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
    if previousState != state {
      debugLog.write("state.transition event=\(debugDescription(for: event)) from=\(debugDescription(for: previousState)) to=\(debugDescription(for: state)) day=\(debugDescription(for: todayWorkDay))")
    } else if shouldLogEvent(event) {
      debugLog.write("event.end \(debugDescription(for: event)) state=\(debugDescription(for: state)) day=\(debugDescription(for: todayWorkDay))")
    }
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

    debugLog.write("missed-gap.detected eventGap=\(Int(now.timeIntervalSince(lastEventAt)))s closingAt=\(debugDate(lastEventAt)) state=\(debugDescription(for: state)) day=\(debugDescription(for: todayWorkDay))")
    if await endCurrentDay(at: lastEventAt, reason: "missed-gap") {
      state = .gap(mode)
      refreshPublishedActivity()
    }
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
      let end = Self.boundedEnd(
        currentDay.lastActivityAt ?? currentDay.startedAt,
        for: currentDay,
        latest: previousDayEnd
      )
      debugLog.write("day-rollover.close previousDay=\(debugDescription(for: currentDay)) boundary=\(debugDate(dayStart)) end=\(debugDate(end))")
      _ = await endCurrentDay(at: end, reason: "day-rollover")
    }

    let snapshot = await loadSnapshot(for: now)
    applySnapshot(snapshot)
    state = snapshot.workDay.map(derivedState(for:)) ?? carriedMode
    debugLog.write("day-rollover.loaded now=\(debugDate(now)) carried=\(debugDescription(for: carriedMode)) state=\(debugDescription(for: state)) day=\(debugDescription(for: todayWorkDay))")

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
      let end = endDateForStaleActiveDay(day, at: now)
      debugLog.write("bootstrap.stale-active-close now=\(debugDate(now)) lastActivityAt=\(debugDate(lastActivityAt)) end=\(debugDate(end)) day=\(debugDescription(for: day))")
      if await endCurrentDay(at: end, reason: "bootstrap-stale-active") {
        state = .gap(mode)
      }
    }

    if case .active(let mode) = state, !conditionsMet(for: mode) {
      let end = endDateForCurrentActiveLoss(at: now)
      debugLog.write("bootstrap.conditions-false mode=\(mode.rawValue) end=\(debugDate(end)) \(conditionSnapshot())")
      if await endCurrentDay(at: end, reason: "bootstrap-conditions-false") {
        state = .gap(mode)
      }
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
      debugLog.write("stale-open-days.error \(error)")
      return
    }
  }

  private func processConditionsChanged(at now: Date) async {
    let autoConditionsMet = conditionsMet(for: .auto)
    logConditionSnapshot(reason: "conditions-changed", at: now)

    if !autoConditionsMet {
      if autoTrackingSuppressed {
        debugLog.write("auto-suppression.cleared reason=auto-conditions-false \(conditionSnapshot())")
      }
      autoTrackingSuppressed = false
    }

    switch state {
    case .active(.auto):
      if !autoConditionsMet {
        let end = endDateForCurrentActiveLoss(at: now)
        debugLog.write("active.auto.conditions-false end=\(debugDate(end)) \(conditionSnapshot())")
        if await endCurrentDay(at: end, reason: "auto-conditions-false") {
          state = .gap(.auto)
        }
      } else {
        await recordActiveHeartbeat(at: now)
      }

    case .active(.manual):
      if !conditionsMet(for: .manual) {
        let end = endDateForCurrentActiveLoss(at: now)
        debugLog.write("active.manual.conditions-false end=\(debugDate(end)) \(conditionSnapshot())")
        if await endCurrentDay(at: end, reason: "manual-conditions-false") {
          state = .gap(.manual)
        }
      } else {
        await recordActiveHeartbeat(at: now)
      }

    case .gap(.auto):
      if autoConditionsMet && !autoTrackingSuppressed {
        debugLog.write("gap.auto.resume \(conditionSnapshot())")
        await activateTracking(mode: .auto, at: now)
        state = .active(.auto)
      }

    case .gap(.manual):
      if conditionsMet(for: .manual) {
        debugLog.write("gap.manual.resume \(conditionSnapshot())")
        await activateTracking(mode: .manual, at: now)
        state = .active(.manual)
      }

    case .stopped:
      if autoConditionsMet && !autoTrackingSuppressed {
        debugLog.write("stopped.auto-start \(conditionSnapshot())")
        await activateTracking(mode: .auto, at: now)
        state = .active(.auto)
      }
    }

    refreshPublishedActivity()
    updateStatusTitle()
  }

  private func processManualStart(at now: Date) async {
    debugLog.write("manual.start state=\(debugDescription(for: state)) day=\(debugDescription(for: todayWorkDay)) \(conditionSnapshot())")
    autoTrackingSuppressed = true

    switch state {
    case .active(.manual):
      return

    case .active(.auto):
      guard await endCurrentDay(at: now, reason: "manual-start-switch") else { return }
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
    guard case .active = state else {
      debugLog.write("stop.ignored state=\(debugDescription(for: state)) day=\(debugDescription(for: todayWorkDay))")
      return
    }

    autoTrackingSuppressed = true
    debugLog.write("stop.accepted state=\(debugDescription(for: state)) day=\(debugDescription(for: todayWorkDay))")
    guard await endCurrentDay(at: now, reason: "manual-stop") else { return }
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
    debugLog.write("activate.begin mode=\(mode.rawValue) now=\(debugDate(now)) state=\(debugDescription(for: state)) day=\(debugDescription(for: todayWorkDay))")

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
          var day = newDay
          try day.insert(db)
          day.id = db.lastInsertedRowID
          return day
        }
        todayWorkDay = insertedDay
        todayGapDuration = 0
        debugLog.write("activate.created mode=\(mode.rawValue) day=\(debugDescription(for: insertedDay))")
      } catch {
        debugLog.write("activate.create.error mode=\(mode.rawValue) \(error)")
        return
      }
      return
    }

    guard existingDay.endedAt != nil else {
      if existingDay.mode == .manual && mode == .auto {
        debugLog.write("activate.ignored open-manual-day auto-request day=\(debugDescription(for: existingDay))")
        return
      }
      debugLog.write("activate.ignored already-open mode=\(mode.rawValue) day=\(debugDescription(for: existingDay))")
      return
    }

    do {
      let gapStart = existingDay.endedAt ?? now
      let gapDuration = max(0, now.timeIntervalSince(gapStart))
      let result = try await writeToDatabase { db in
        var day = try Self.resolvableDay(existingDay, in: db)
        let willInsertGap = day.id != nil && now > gapStart && gapStart > day.startedAt
        let willResetStart = gapStart <= day.startedAt

        if let workDayId = day.id, now > gapStart, gapStart > day.startedAt {
          let gap = Gap(id: nil, workDayId: workDayId, startedAt: gapStart, endedAt: now)
          try gap.insert(db)
        }
        if gapStart <= day.startedAt {
          day.startedAt = now
        }
        day.endedAt = nil
        day.lastActivityAt = now
        day.hasMixedLocations = day.hasMixedLocations || day.mode != mode
        day.mode = mode
        try day.update(db)
        return (day: day, insertedGap: willInsertGap, resetStart: willResetStart)
      }
      if let endedAt = existingDay.endedAt {
        let duration = max(0, now.timeIntervalSince(endedAt))
        if duration >= settings.minimumVisibleGapDuration {
          todayGapDuration += duration
        }
      }
      todayWorkDay = result.day
      debugLog.write("activate.reopened mode=\(mode.rawValue) gapStart=\(debugDate(gapStart)) gapDuration=\(Int(gapDuration))s insertedGap=\(result.insertedGap) resetStart=\(result.resetStart) oldDay=\(debugDescription(for: existingDay)) newDay=\(debugDescription(for: result.day))")
    } catch {
      debugLog.write("activate.reopen.error mode=\(mode.rawValue) day=\(debugDescription(for: existingDay)) \(error)")
      return
    }
  }

  @discardableResult
  private func endCurrentDay(at now: Date, reason: String = "unspecified") async -> Bool {
    guard let currentDay = todayWorkDay, currentDay.endedAt == nil else {
      debugLog.write("day.end.ignored reason=\(reason) requestedEnd=\(debugDate(now)) day=\(debugDescription(for: todayWorkDay))")
      return false
    }

    do {
      let updatedDay = try await writeToDatabase { db in
        var day = try Self.resolvableDay(currentDay, in: db)
        day.endedAt = now
        try day.update(db)
        return day
      }
      todayWorkDay = updatedDay
      debugLog.write("day.end reason=\(reason) requestedEnd=\(debugDate(now)) updated=\(debugDescription(for: updatedDay))")
      return true
    } catch {
      debugLog.write("day.end.error reason=\(reason) requestedEnd=\(debugDate(now)) day=\(debugDescription(for: currentDay)) \(error)")
      return false
    }
  }

  private func recordActiveHeartbeat(at now: Date) async {
    guard let currentDay = todayWorkDay, currentDay.endedAt == nil else { return }

    do {
      let updatedDay = try await writeToDatabase { db in
        var day = try Self.resolvableDay(currentDay, in: db)
        day.lastActivityAt = now
        try day.update(db)
        return day
      }
      todayWorkDay = updatedDay
      logHeartbeatIfNeeded(at: now, day: updatedDay)
    } catch {
      debugLog.write("heartbeat.error now=\(debugDate(now)) day=\(debugDescription(for: currentDay)) \(error)")
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

  private func endDateForStaleActiveDay(_ day: WorkDay, at now: Date) -> Date {
    guard let lastActivityAt = day.lastActivityAt else {
      return inactiveStartedAt(for: now)
    }

    if lastActivityAt <= day.startedAt {
      return inactiveStartedAt(for: now)
    }

    return Self.boundedEnd(lastActivityAt, for: day)
  }

  nonisolated private static func boundedEnd(_ date: Date, for day: WorkDay, latest: Date? = nil) -> Date {
    let latestDate = latest ?? .distantFuture
    return min(max(date, day.startedAt), latestDate)
  }

  nonisolated private static func resolvableDay(_ day: WorkDay, in db: Database) throws -> WorkDay {
    if day.id != nil {
      return day
    }

    if let persistedDay = try WorkDay
      .filter(WorkDay.Columns.date == day.date)
      .fetchOne(db)
    {
      return persistedDay
    }

    throw TrackingEngineError.missingPersistedWorkDay(date: day.date)
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
      debugLog.write("snapshot.load.error referenceDate=\(debugDate(referenceDate)) \(error)")
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
      debugLog.write("midnight.schedule.error referenceDate=\(debugDate(referenceDate))")
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
    debugLog.write("midnight.scheduled referenceDate=\(debugDate(referenceDate)) next=\(debugDate(nextMidnight))")
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

  private func shouldLogEvent(_ event: TrackingEvent) -> Bool {
    switch event {
    case .conditionsChanged:
      return false
    case .startup, .manualStart, .stop, .midnight:
      return true
    }
  }

  private func logConditionSnapshot(reason: String, at now: Date, force: Bool = false) {
    if !force,
       let lastConditionLogAt,
       now.timeIntervalSince(lastConditionLogAt) < 60
    {
      return
    }

    lastConditionLogAt = now
    debugLog.write("conditions.snapshot reason=\(reason) now=\(debugDate(now)) \(conditionSnapshot())")
  }

  private func logHeartbeatIfNeeded(at now: Date, day: WorkDay) {
    if let lastHeartbeatLogAt,
       now.timeIntervalSince(lastHeartbeatLogAt) < 300
    {
      return
    }

    lastHeartbeatLogAt = now
    debugLog.write("heartbeat.recorded now=\(debugDate(now)) day=\(debugDescription(for: day))")
  }

  private func conditionSnapshot() -> String {
    let ssid = wifiMonitor.currentSSID ?? "nil"
    return "state=\(debugDescription(for: state)) autoConditions=\(conditionsMet(for: .auto)) manualConditions=\(conditionsMet(for: .manual)) suppressed=\(autoTrackingSuppressed) wifiSSID='\(ssid)' wifiOnWork=\(wifiMonitor.isOnWorkWiFi) unlocked=\(screenMonitor.isScreenUnlocked) systemSleeping=\(screenMonitor.isSystemSleeping) displaySleeping=\(screenMonitor.isDisplaySleeping) lidClosed=\(screenMonitor.isLidClosed) idle=\(Int(screenMonitor.idleDuration))s day=\(debugDescription(for: todayWorkDay))"
  }

  private func debugDescription(for event: TrackingEvent) -> String {
    switch event {
    case .startup(let date):
      return "startup(\(debugDate(date)))"
    case .conditionsChanged(let date):
      return "conditionsChanged(\(debugDate(date)))"
    case .manualStart(let date):
      return "manualStart(\(debugDate(date)))"
    case .stop(let date):
      return "stop(\(debugDate(date)))"
    case .midnight(let date):
      return "midnight(\(debugDate(date)))"
    }
  }

  private func debugDescription(for state: TrackingState) -> String {
    switch state {
    case .stopped:
      return "stopped"
    case .active(let mode):
      return "active.\(mode.rawValue)"
    case .gap(let mode):
      return "gap.\(mode.rawValue)"
    }
  }

  private func debugDescription(for day: WorkDay?) -> String {
    guard let day else { return "nil" }
    return "id=\(day.id.map(String.init) ?? "nil") date=\(debugDate(day.date)) start=\(debugDate(day.startedAt)) end=\(debugDate(day.endedAt)) last=\(debugDate(day.lastActivityAt)) mode=\(day.mode.rawValue) mixed=\(day.hasMixedLocations)"
  }

  private func debugDate(_ date: Date?) -> String {
    guard let date else { return "nil" }
    return TrackingDebugLog.format(date)
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

private final class TrackingDebugLog {
  let filePath: String

  private let fileURL: URL
  private let fileManager = FileManager.default
  private let maxFileSize: UInt64 = 2 * 1024 * 1024

  init() {
    var directory: URL
    do {
      directory = try fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      ).appendingPathComponent("TrackThor", isDirectory: true)
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      directory = fileManager.temporaryDirectory.appendingPathComponent("TrackThor", isDirectory: true)
      try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    fileURL = directory.appendingPathComponent("tracking-debug.log")
    filePath = fileURL.path
    rotateIfNeeded()
    ensureFileExists()
  }

  func write(_ message: String) {
    rotateIfNeeded()
    ensureFileExists()

    let line = "\(Self.format(Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }

    guard let handle = try? FileHandle(forWritingTo: fileURL) else {
      try? data.write(to: fileURL, options: .atomic)
      return
    }

    handle.seekToEndOfFile()
    handle.write(data)
    try? handle.close()
  }

  static func format(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private func ensureFileExists() {
    if !fileManager.fileExists(atPath: fileURL.path) {
      fileManager.createFile(atPath: fileURL.path, contents: nil)
    }
  }

  private func rotateIfNeeded() {
    guard
      let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
      let size = attributes[.size] as? UInt64,
      size > maxFileSize
    else {
      return
    }

    let previousURL = fileURL.deletingLastPathComponent().appendingPathComponent("tracking-debug.previous.log")
    try? fileManager.removeItem(at: previousURL)
    try? fileManager.moveItem(at: fileURL, to: previousURL)
  }
}

private enum TrackingEngineError: LocalizedError {
  case missingPersistedWorkDay(date: Date)

  var errorDescription: String? {
    switch self {
    case .missingPersistedWorkDay(let date):
      return "Missing persisted work day for date \(TrackingDebugLog.format(date))"
    }
  }
}
