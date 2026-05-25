import Foundation
import GRDB

final class DatabaseManager {
  static let shared = DatabaseManager()

  let dbQueue: DatabaseQueue

  private init() {
    let fm = FileManager.default
    let baseURL = try! fm.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let appDir = baseURL.appendingPathComponent("TrackThor", isDirectory: true)
    try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
    let dbURL = appDir.appendingPathComponent("trackthor.db")

    dbQueue = try! DatabaseQueue(path: dbURL.path)
    try! migrator.migrate(dbQueue)
  }

  private var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("createWorkDaysAndGaps") { db in
      try db.create(table: "work_days", ifNotExists: true) { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("date", .date).notNull().unique()
        t.column("started_at", .datetime).notNull()
        t.column("ended_at", .datetime)
        t.column("mode", .text).notNull()
      }
      try db.create(table: "gaps", ifNotExists: true) { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("work_day_id", .integer).notNull().indexed().references("work_days", onDelete: .cascade)
        t.column("started_at", .datetime).notNull()
        t.column("ended_at", .datetime).notNull()
      }
    }
    migrator.registerMigration("addHasMixedLocationsToWorkDays") { db in
      try db.alter(table: "work_days") { t in
        t.add(column: "has_mixed_locations", .boolean).notNull().defaults(to: false)
      }
    }
    migrator.registerMigration("addLastActivityAtToWorkDays") { db in
      try db.alter(table: "work_days") { t in
        t.add(column: "last_activity_at", .datetime)
      }
      try db.execute(sql: """
        UPDATE work_days
        SET last_activity_at = COALESCE(ended_at, CURRENT_TIMESTAMP)
        WHERE last_activity_at IS NULL
        """)
    }
    return migrator
  }
}
