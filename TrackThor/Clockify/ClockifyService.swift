import Foundation
import GRDB

/// Clockify connection (API key in the Keychain, workspace, projects) and pushing of day plans.
@MainActor
final class ClockifyService: ObservableObject {
  /// What's already in Clockify for a day.
  struct DayStatus: Sendable {
    /// Entries TrackThor created that still exist.
    var pushed = 0
    /// Entries added some other way (by hand, timer, …).
    var other = 0
  }

  @Published private(set) var hasAPIKey: Bool
  @Published private(set) var user: ClockifyUser?
  @Published private(set) var workspaces: [ClockifyWorkspace] = []
  @Published private(set) var projects: [ClockifyProject] = []
  @Published private(set) var isConnecting = false
  @Published private(set) var connectionError: String?

  private let settings: AppSettings
  private let database: DatabaseManager

  private static let keychainService = "TrackThor.Clockify"
  private static let keychainAccount = "apiKey"

  init(settings: AppSettings, database: DatabaseManager) {
    self.settings = settings
    self.database = database
    self.hasAPIKey = Keychain.string(service: Self.keychainService, account: Self.keychainAccount) != nil
  }

  var isReadyToPush: Bool {
    hasAPIKey
      && !settings.clockifyWorkspaceId.isEmpty
      && !settings.clockifyMeetingProjectId.isEmpty
      && !settings.clockifyWorkProjectId.isEmpty
  }

  func projectName(_ id: String) -> String {
    projects.first { $0.id == id }?.displayName ?? "—"
  }

  // MARK: - Connection

  func saveAPIKey(_ key: String) async {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    Keychain.set(trimmed, service: Self.keychainService, account: Self.keychainAccount)
    hasAPIKey = !trimmed.isEmpty
    user = nil
    workspaces = []
    projects = []
    if hasAPIKey {
      await connect()
    } else {
      connectionError = nil
    }
  }

  /// Verifies the key, loads workspaces and the selected workspace's projects.
  func connect() async {
    guard hasAPIKey else { return }
    isConnecting = true
    defer { isConnecting = false }

    do {
      let client = try makeClient()
      let user = try await client.currentUser()
      let workspaces = try await client.workspaces()
      self.user = user
      self.workspaces = workspaces.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

      if settings.clockifyWorkspaceId.isEmpty || !workspaces.contains(where: { $0.id == settings.clockifyWorkspaceId }) {
        settings.clockifyWorkspaceId = user.activeWorkspace ?? user.defaultWorkspace ?? workspaces.first?.id ?? ""
      }
      connectionError = nil
      await loadProjects()
    } catch {
      self.user = nil
      connectionError = error.localizedDescription
    }
  }

  func loadProjects() async {
    let workspaceId = settings.clockifyWorkspaceId
    guard hasAPIKey, !workspaceId.isEmpty else {
      projects = []
      return
    }
    do {
      let loaded = try await makeClient().projects(workspaceId: workspaceId)
      guard workspaceId == settings.clockifyWorkspaceId else { return }
      projects = loaded.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
      connectionError = nil
    } catch {
      connectionError = error.localizedDescription
    }
  }

  // MARK: - Report

  /// Day plans for every tracked day in `month` that is already over (today and later are left out).
  func plans(forMonthContaining month: Date) async throws -> [ClockifyDayPlan] {
    let calendar = Calendar.current
    let range = monthRange(containing: month)
    let today = calendar.startOfDay(for: Date())
    let end = min(range.end, today)
    guard range.start < end else { return [] }

    let minimumGap = settings.minimumVisibleGapDuration
    let dbQueue = database.dbQueue
    let (days, gaps, events) = try await Task.detached(priority: .utility) {
      try dbQueue.read { db in
        let days = try WorkDay
          .filter(WorkDay.Columns.date >= range.start && WorkDay.Columns.date < end)
          .order(WorkDay.Columns.date.asc)
          .fetchAll(db)
        let ids = days.compactMap(\.id)
        let gaps = try Gap.filter(ids.contains(Gap.Columns.workDayId)).fetchAll(db)
        let events = try Meeting
          .filter(Meeting.Columns.date >= range.start && Meeting.Columns.date < end)
          .fetchAll(db)
        return (days, gaps, events)
      }
    }.value

    let gapsByDay = Dictionary(grouping: gaps, by: \.workDayId)
    let eventsByDay = Dictionary(grouping: events, by: \.date)
    let now = Date()

    return days.map { day in
      let visibleGaps = (day.id.flatMap { gapsByDay[$0] } ?? [])
        .filter { $0.endedAt.timeIntervalSince($0.startedAt) >= minimumGap }
        .map(\.interval)
      return ClockifyPlanner.plan(
        day: day,
        visibleGaps: visibleGaps,
        events: eventsByDay[day.date] ?? [],
        minimumGap: minimumGap,
        now: now
      )
    }
  }

  /// What already exists in Clockify for each day of the month, split into TrackThor's and others.
  func statuses(forMonthContaining month: Date) async throws -> [Date: DayStatus] {
    let workspaceId = try requireWorkspace()
    let client = try makeClient()
    let userId = try await currentUserId(client)
    let range = monthRange(containing: month)

    let remote = try await client.timeEntries(workspaceId: workspaceId, userId: userId, from: range.start, to: range.end)
    let ours = Set(try await storedEntries(in: range).map(\.clockifyId))

    let calendar = Calendar.current
    var statuses: [Date: DayStatus] = [:]
    for entry in remote {
      let day = calendar.startOfDay(for: entry.timeInterval.start)
      if ours.contains(entry.id) {
        statuses[day, default: DayStatus()].pushed += 1
      } else {
        statuses[day, default: DayStatus()].other += 1
      }
    }
    return statuses
  }

  /// Replaces TrackThor's entries for the day with the plan's entries.
  func push(_ plan: ClockifyDayPlan) async throws {
    let workspaceId = try requireWorkspace()
    guard !settings.clockifyMeetingProjectId.isEmpty else { throw ClockifyError.notConfigured("pick the meeting project") }
    guard !settings.clockifyWorkProjectId.isEmpty else { throw ClockifyError.notConfigured("pick the R&D project") }
    let client = try makeClient()

    try await deletePushedEntries(for: plan.date)

    for entry in plan.entries {
      let projectId = entry.category == .meeting ? settings.clockifyMeetingProjectId : settings.clockifyWorkProjectId
      let created = try await client.createTimeEntry(
        workspaceId: workspaceId,
        ClockifyNewTimeEntry(
          start: ClockifyClient.timestamp(entry.start),
          end: ClockifyClient.timestamp(entry.end),
          billable: settings.clockifyBillable,
          description: nil,
          projectId: projectId
        )
      )
      // Recorded one by one, so a failure halfway still leaves a correct record of what exists.
      try await record(ClockifyEntry(
        id: nil,
        date: plan.date,
        workspaceId: workspaceId,
        clockifyId: created.id,
        category: entry.category,
        startedAt: entry.start,
        endedAt: entry.end,
        pushedAt: Date()
      ))
    }
  }

  /// Deletes only entries TrackThor created for this day.
  func deletePushedEntries(for date: Date) async throws {
    let client = try makeClient()
    let dbQueue = database.dbQueue
    let entries = try await Task.detached(priority: .utility) {
      try dbQueue.read { db in
        try ClockifyEntry.filter(ClockifyEntry.Columns.date == date).fetchAll(db)
      }
    }.value

    for entry in entries {
      try await client.deleteTimeEntry(workspaceId: entry.workspaceId, id: entry.clockifyId)
      let rowId = entry.id
      try await Task.detached(priority: .utility) {
        try dbQueue.write { db in
          _ = try ClockifyEntry.deleteOne(db, key: rowId)
        }
      }.value
    }
  }

  // MARK: - Helpers

  func monthRange(containing date: Date) -> DateInterval {
    Calendar.current.dateInterval(of: .month, for: date) ?? IntervalMath.make(date, date)
  }

  private func makeClient() throws -> ClockifyClient {
    guard let key = Keychain.string(service: Self.keychainService, account: Self.keychainAccount), !key.isEmpty else {
      throw ClockifyError.missingAPIKey
    }
    return ClockifyClient(apiKey: key, region: settings.clockifyRegion)
  }

  private func requireWorkspace() throws -> String {
    guard !settings.clockifyWorkspaceId.isEmpty else { throw ClockifyError.notConfigured("pick a workspace") }
    return settings.clockifyWorkspaceId
  }

  private func currentUserId(_ client: ClockifyClient) async throws -> String {
    if let user { return user.id }
    let loaded = try await client.currentUser()
    user = loaded
    return loaded.id
  }

  private func storedEntries(in range: DateInterval) async throws -> [ClockifyEntry] {
    let dbQueue = database.dbQueue
    return try await Task.detached(priority: .utility) {
      try dbQueue.read { db in
        try ClockifyEntry
          .filter(ClockifyEntry.Columns.date >= range.start && ClockifyEntry.Columns.date < range.end)
          .fetchAll(db)
      }
    }.value
  }

  private func record(_ entry: ClockifyEntry) async throws {
    let dbQueue = database.dbQueue
    try await Task.detached(priority: .utility) {
      try dbQueue.write { db in
        try entry.insert(db)
      }
    }.value
  }
}
