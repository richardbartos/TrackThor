import SwiftUI

struct HistoryView: View {
  let history: [WorkDay]
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("THIS WEEK")
        .font(.caption)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 6) {
        ForEach(rows, id: \.dateKey) { row in
          HStack {
            Text(row.label)
              .frame(width: 44, alignment: .leading)
            Text(row.detail)
              .foregroundStyle(row.isEmpty ? .secondary : .primary)
            Spacer()
            Text(row.modeIcon)
              .foregroundStyle(.secondary)
          }
          .font(.system(size: 12, weight: .regular, design: .default))
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var rows: [Row] {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let weekday = cal.component(.weekday, from: today)
    let daysFromMonday = (weekday + 5) % 7
    let start = cal.date(byAdding: .day, value: -daysFromMonday, to: today)!

    let byDate: [String: WorkDay] = Dictionary(
      uniqueKeysWithValues: history.map { (DateFormatting.dayKeyFormatter.string(from: $0.date), $0) }
    )

    return (0..<7).compactMap { offset in
      let date = cal.date(byAdding: .day, value: offset, to: start)!
      let key = DateFormatting.dayKeyFormatter.string(from: date)
      let wd = byDate[key]
      let label = cal.shortWeekdaySymbols[cal.component(.weekday, from: date) - 1]
      if let wd {
        let startT = DateFormatting.timeFormatter.string(from: wd.startedAt)
        let spanEnd = effectiveEnd(for: wd)
        let endT = DateFormatting.timeFormatter.string(from: spanEnd)
        let duration = DurationFormatter.hoursMinutesRoundedUpToMinute(
          max(0, spanEnd.timeIntervalSince(DateFormatting.floorToMinute(wd.startedAt)))
        )
        let modeIcon: String
        if wd.hasMixedLocations {
          modeIcon = "🔀"
        } else {
          modeIcon = wd.mode == .manual ? "🏠" : "🏢"
        }
        return Row(dateKey: key, label: label, detail: "\(startT) → \(endT)  \(duration)", modeIcon: modeIcon, isEmpty: false)
      } else {
        return Row(dateKey: key, label: label, detail: "—", modeIcon: "", isEmpty: true)
      }
    }
  }

  struct Row {
    let dateKey: String
    let label: String
    let detail: String
    let modeIcon: String
    let isEmpty: Bool
  }

  private func effectiveEnd(for day: WorkDay) -> Date {
    if let endedAt = day.endedAt {
      return endedAt
    }

    let today = Calendar.current.startOfDay(for: now)
    if day.date < today,
       let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: day.date)?
        .addingTimeInterval(-1)
    {
      return dayEnd
    }

    return now
  }
}
