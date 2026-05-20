import Foundation
import GRDB

struct WorkDay: Codable, FetchableRecord, PersistableRecord, Identifiable {
  enum Mode: String, Codable {
    case auto
    case manual
  }

  var id: Int64?
  var date: Date
  var startedAt: Date
  var endedAt: Date?
  var mode: Mode
  var hasMixedLocations: Bool

  static let databaseTableName = "work_days"

  enum CodingKeys: String, CodingKey {
    case id
    case date
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case mode
    case hasMixedLocations = "has_mixed_locations"
  }

  enum Columns {
    static let id = Column("id")
    static let date = Column("date")
    static let startedAt = Column("started_at")
    static let endedAt = Column("ended_at")
    static let mode = Column("mode")
    static let hasMixedLocations = Column("has_mixed_locations")
  }

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
