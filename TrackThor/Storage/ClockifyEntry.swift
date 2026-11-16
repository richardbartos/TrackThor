import Foundation
import GRDB

/// A time entry TrackThor created in Clockify. Only these are ever replaced or deleted by the app —
/// entries added in Clockify by hand are never touched.
struct ClockifyEntry: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
  var id: Int64?
  var date: Date
  var workspaceId: String
  var clockifyId: String
  var category: ClockifyCategory
  var startedAt: Date
  var endedAt: Date
  var pushedAt: Date

  static let databaseTableName = "clockify_entries"

  enum CodingKeys: String, CodingKey {
    case id
    case date
    case workspaceId = "workspace_id"
    case clockifyId = "clockify_id"
    case category
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case pushedAt = "pushed_at"
  }

  enum Columns {
    static let date = Column("date")
    static let workspaceId = Column("workspace_id")
  }

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
