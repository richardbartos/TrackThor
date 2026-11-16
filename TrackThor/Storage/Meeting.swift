import Foundation
import GRDB

/// A calendar meeting, stored per local day (clipped to that day) so history stays stable
/// even if the calendar event is later edited or deleted.
struct Meeting: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
  var id: Int64?
  var date: Date
  var eventId: String
  var calendarId: String
  var title: String
  var startedAt: Date
  var endedAt: Date

  static let databaseTableName = "meetings"

  enum CodingKeys: String, CodingKey {
    case id
    case date
    case eventId = "event_id"
    case calendarId = "calendar_id"
    case title
    case startedAt = "started_at"
    case endedAt = "ended_at"
  }

  enum Columns {
    static let date = Column("date")
    static let startedAt = Column("started_at")
  }

  var interval: DateInterval { IntervalMath.make(startedAt, endedAt) }

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

/// Bookkeeping for which days have meetings stored. A day is final once it was synced after it ended;
/// final days are not re-read from the calendar (unless the calendar selection changes).
struct MeetingDay: Codable, FetchableRecord, PersistableRecord {
  var date: Date
  var syncedAt: Date
  var isFinal: Bool

  static let databaseTableName = "meeting_days"

  enum CodingKeys: String, CodingKey {
    case date
    case syncedAt = "synced_at"
    case isFinal = "is_final"
  }

  enum Columns {
    static let date = Column("date")
    static let isFinal = Column("is_final")
  }
}
