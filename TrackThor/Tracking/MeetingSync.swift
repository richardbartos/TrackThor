import AppKit
import Combine
import EventKit
import Foundation
import GRDB

/// Reads meetings from the macOS Calendar (EventKit — includes Google accounts added in
/// System Settings → Internet Accounts) and stores a per-day snapshot in SQLite.
///
/// Sync rules:
/// - Today is re-read on every sync (startup, every 5 minutes, calendar changes).
/// - Every tracked day that isn't final yet is read once more after it has ended and then frozen,
///   so later edits/deletions in the calendar don't rewrite history.
/// - Changing the calendar selection drops the snapshots and rebuilds all tracked days.
@MainActor
final class MeetingSync: ObservableObject {
  struct CalendarOption: Identifiable, Equatable {
    let id: String
    let title: String
    let sourceTitle: String
    let color: NSColor
  }

  enum Access {
    case notDetermined
    case granted
    case denied
  }

  @Published private(set) var access: Access
  @Published private(set) var calendars: [CalendarOption] = []
  @Published private(set) var todayMeetings: [Meeting] = []
  /// Incremented after every write so views can reload stored meetings.
  @Published private(set) var revision = 0

  private let store = EKEventStore()
  private let settings: AppSettings
  private let database: DatabaseManager
  private var cancellables: Set<AnyCancellable> = []
  private var timer: Timer?
  private var syncChain: Task<Void, Never>?
  /// A history rebuild was requested (rules or calendar selection changed) but hasn't completed yet.
  /// Kept until a rebuild actually succeeds — at launch EventKit may not have loaded the calendars yet,
  /// and that first sync bails out without touching the database.
  private var rebuildPending =
    UserDefaults.standard.integer(forKey: MeetingSync.rulesVersionKey) != MeetingSync.rulesVersion

  private static let syncInterval: TimeInterval = 5 * 60

  /// Bump whenever `isMeeting` changes, so frozen history is recalculated once with the new rules.
  private static let rulesVersion = 4
  private static let rulesVersionKey = "meetingRulesVersion"

  /// Events whose title contains one of these (case/diacritics-insensitive) are never meetings.
  private static let ignoredTitleWords = ["placeholder", "reminder"]

  init(settings: AppSettings, database: DatabaseManager) {
    self.settings = settings
    self.database = database
    self.access = Self.currentAccess()
  }

  /// Calendar access granted and at least one calendar selected.
  var isConfigured: Bool {
    access == .granted && !settings.meetingCalendarIDs.isEmpty
  }

  /// Today's meetings as intervals, or [] when meeting tracking is off.
  var todayMeetingIntervals: [DateInterval] {
    guard isConfigured else { return [] }
    let today = Calendar.current.startOfDay(for: Date())
    return todayMeetings.filter { $0.date == today }.map(\.interval)
  }

  func start() {
    cancellables.removeAll()

    NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: store)
      .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.reloadCalendars()
        self?.sync()
      }
      .store(in: &cancellables)

    settings.$meetingCalendarIDs
      .dropFirst()
      .removeDuplicates()
      .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.sync(rebuildHistory: true)
      }
      .store(in: &cancellables)

    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: Self.syncInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.sync() }
    }

    reloadCalendars()
    sync()

    // Calendars were picked before but permission is undecided — e.g. a rebuilt debug app that
    // macOS treats as new. Ask again right away instead of silently not tracking meetings.
    if access == .notDetermined && !settings.meetingCalendarIDs.isEmpty {
      Task { await requestAccess() }
    }
  }

  func stop() {
    cancellables.removeAll()
    timer?.invalidate()
    timer = nil
  }

  func requestAccess() async {
    do {
      _ = try await store.requestFullAccessToEvents()
    } catch {
      NSLog("TrackThor: calendar access request failed: \(error)")
    }
    access = Self.currentAccess()
    reloadCalendars()
    sync()
  }

  /// Re-checks permission (it can change in System Settings while the app runs).
  func refreshAccess() {
    let newAccess = Self.currentAccess()
    guard newAccess != access else { return }
    access = newAccess
    reloadCalendars()
    sync()
  }

  func reloadCalendars() {
    guard access == .granted else {
      calendars = []
      return
    }
    calendars = store.calendars(for: .event)
      .map {
        CalendarOption(
          id: $0.calendarIdentifier,
          title: $0.title,
          sourceTitle: $0.source?.title ?? "Other",
          color: $0.color ?? .systemGray
        )
      }
      .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
  }

  /// Queues a sync; syncs never run concurrently.
  func sync(rebuildHistory: Bool = false) {
    let previous = syncChain
    syncChain = Task { [weak self] in
      _ = await previous?.value
      await self?.performSync(rebuildHistory: rebuildHistory)
    }
  }

  // MARK: - Sync

  private func performSync(rebuildHistory requested: Bool) async {
    if requested {
      rebuildPending = true
    }
    let rebuildHistory = rebuildPending
    access = Self.currentAccess()
    let dbQueue = database.dbQueue
    let selectedIDs = Set(settings.meetingCalendarIDs)

    do {
      if selectedIDs.isEmpty {
        // Nothing selected: meeting tracking is off, drop stored meetings.
        try await Self.write(dbQueue) { db in
          _ = try Meeting.deleteAll(db)
          _ = try MeetingDay.deleteAll(db)
        }
        finishSync(today: [])
        return
      }

      // Without access (or if the selected calendars disappeared) keep the stored history as is.
      let selectedCalendars = access == .granted
        ? store.calendars(for: .event).filter { selectedIDs.contains($0.calendarIdentifier) }
        : []
      guard !selectedCalendars.isEmpty else {
        finishSync(today: try await loadStoredToday(dbQueue))
        return
      }

      let calendar = Calendar.current
      let now = Date()
      let today = calendar.startOfDay(for: now)

      let pendingDays: [Date] = try await Self.write(dbQueue) { db in
        if rebuildHistory {
          _ = try MeetingDay.deleteAll(db)
        }
        let finalDays = Set(try MeetingDay.filter(MeetingDay.Columns.isFinal == true).fetchAll(db).map(\.date))
        return try WorkDay.fetchAll(db).map(\.date).filter { !finalDays.contains($0) }
      }

      var days = Set(pendingDays.filter { $0 <= today })
      days.insert(today)
      let sortedDays = days.sorted()

      guard
        let rangeStart = sortedDays.first,
        let lastDay = sortedDays.last,
        let rangeEnd = calendar.date(byAdding: .day, value: 1, to: lastDay)
      else { return }

      let events = fetchEvents(from: rangeStart, to: rangeEnd, in: selectedCalendars)
        .compactMap { event in Self.kind(of: event).map { (event, $0) } }

      var meetingsByDay: [Date: [Meeting]] = [:]
      for day in sortedDays {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
        meetingsByDay[day] = Self.meetings(from: events, day: day, dayEnd: dayEnd)
      }

      let snapshot = meetingsByDay
      try await Self.write(dbQueue) { db in
        if rebuildHistory {
          _ = try Meeting.deleteAll(db)
        }
        for (day, meetings) in snapshot {
          _ = try Meeting.filter(Meeting.Columns.date == day).deleteAll(db)
          for meeting in meetings {
            try meeting.insert(db)
          }
          try MeetingDay(date: day, syncedAt: now, isFinal: day < today).save(db)
        }
      }

      if rebuildHistory {
        rebuildPending = false
        UserDefaults.standard.set(Self.rulesVersion, forKey: Self.rulesVersionKey)
      }
      finishSync(today: try await loadStoredToday(dbQueue))
    } catch {
      NSLog("TrackThor: meeting sync failed: \(error)")
    }
  }

  private func finishSync(today: [Meeting]) {
    todayMeetings = today
    revision += 1
  }

  private func loadStoredToday(_ dbQueue: DatabaseQueue) async throws -> [Meeting] {
    let today = Calendar.current.startOfDay(for: Date())
    return try await Task.detached(priority: .utility) {
      try dbQueue.read { db in
        try Meeting.meetingsOnly
          .filter(Meeting.Columns.date == today)
          .order(Meeting.Columns.startedAt.asc)
          .fetchAll(db)
      }
    }.value
  }

  /// EventKit limits a single predicate to a few years, so long backfills are fetched in chunks.
  private func fetchEvents(from start: Date, to end: Date, in calendars: [EKCalendar]) -> [EKEvent] {
    let calendar = Calendar.current
    var events: [EKEvent] = []
    var chunkStart = start
    while chunkStart < end {
      let chunkEnd = min(end, calendar.date(byAdding: .day, value: 365, to: chunkStart) ?? end)
      let predicate = store.predicateForEvents(withStart: chunkStart, end: chunkEnd, calendars: calendars)
      events.append(contentsOf: store.events(matching: predicate))
      chunkStart = chunkEnd
    }
    return events
  }

  /// A meeting is a timed, non-cancelled event with at least one other person that you haven't declined.
  /// Placeholders and reminders (by title) never count.
  /// Out-of-office events ("OOO" as a word in the title) are stored separately; they never count
  /// as meetings and are taken out of the day when reporting to Clockify.
  private static func kind(of event: EKEvent) -> Meeting.Kind? {
    guard event.status != .canceled, event.endDate > event.startDate else { return nil }
    if (event.title ?? "").range(of: #"\bOOO\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
      return .outOfOffice
    }
    return isMeeting(event) ? .meeting : nil
  }

  private static func isMeeting(_ event: EKEvent) -> Bool {
    guard !event.isAllDay, event.status != .canceled, event.endDate > event.startDate else { return false }

    let title = event.title ?? ""
    if ignoredTitleWords.contains(where: { title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
      return false
    }

    guard let attendees = event.attendees, !attendees.isEmpty else { return false }

    // "Me" = attendees flagged as the current user, plus the calendar's own address (Google names
    // the primary calendar after the account email), in case the flag isn't set.
    var myEmails = Set(attendees.filter(\.isCurrentUser).compactMap(email(of:)))
    if let calendarTitle = event.calendar?.title, calendarTitle.contains("@") {
      myEmails.insert(calendarTitle.lowercased())
    }
    let isMe: (EKParticipant) -> Bool = { participant in
      participant.isCurrentUser || email(of: participant).map(myEmails.contains) == true
    }

    // Rooms and resources (meeting rooms, projectors) aren't people.
    let otherPeople = attendees.filter { participant in
      participant.participantType != .room && participant.participantType != .resource && !isMe(participant)
    }
    guard !otherPeople.isEmpty else { return false }

    if attendees.contains(where: { isMe($0) && $0.participantStatus == .declined }) {
      return false
    }
    return true
  }

  private static func email(of participant: EKParticipant) -> String? {
    let url = participant.url.absoluteString
    guard url.lowercased().hasPrefix("mailto:") else { return nil }
    return String(url.dropFirst("mailto:".count)).removingPercentEncoding?.lowercased()
  }

  /// Meetings overlapping one day, clipped to it. The same event in two selected calendars is kept once.
  private static func meetings(from events: [(EKEvent, Meeting.Kind)], day: Date, dayEnd: Date) -> [Meeting] {
    var seen: Set<String> = []
    var result: [Meeting] = []

    for (event, kind) in events {
      let start = max(event.startDate, day)
      let end = min(event.endDate, dayEnd)
      guard end > start else { continue }

      let eventId = event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier
      let key = "\(eventId)|\(event.startDate.timeIntervalSinceReferenceDate)"
      guard seen.insert(key).inserted else { continue }

      result.append(
        Meeting(
          id: nil,
          date: day,
          eventId: eventId,
          calendarId: event.calendar.calendarIdentifier,
          title: event.title ?? "Untitled",
          startedAt: start,
          endedAt: end,
          kind: kind
        )
      )
    }
    return result.sorted { $0.startedAt < $1.startedAt }
  }

  private static func currentAccess() -> Access {
    let status = EKEventStore.authorizationStatus(for: .event)
    switch status {
    case .notDetermined:
      return .notDetermined
    case .fullAccess:
      return .granted
    default:
      // .denied, .restricted, and .writeOnly (can't read events).
      return .denied
    }
  }

  private static func write<T: Sendable>(
    _ dbQueue: DatabaseQueue,
    _ block: @escaping @Sendable (Database) throws -> T
  ) async throws -> T {
    try await Task.detached(priority: .utility) {
      try dbQueue.write { db in try block(db) }
    }.value
  }
}
