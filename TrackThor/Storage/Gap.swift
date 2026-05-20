import Foundation
import GRDB

struct Gap: Codable, FetchableRecord, PersistableRecord, Identifiable {
  var id: Int64?
  var workDayId: Int64
  var startedAt: Date
  var endedAt: Date

  static let databaseTableName = "gaps"

  enum CodingKeys: String, CodingKey {
    case id
    case workDayId = "work_day_id"
    case startedAt = "started_at"
    case endedAt = "ended_at"
  }

  enum Columns {
    static let id = Column("id")
    static let workDayId = Column("work_day_id")
    static let startedAt = Column("started_at")
    static let endedAt = Column("ended_at")
  }

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

