import Foundation

enum DateFormatting {
  static let dayKeyFormatter: DateFormatter = {
    let df = DateFormatter()
    df.calendar = Calendar(identifier: .gregorian)
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    df.dateFormat = "yyyy-MM-dd"
    return df
  }()

  static let timeFormatter: DateFormatter = {
    let df = DateFormatter()
    df.calendar = Calendar(identifier: .gregorian)
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    df.dateFormat = "H:mm"
    return df
  }()

  static let longDayFormatter: DateFormatter = {
    let df = DateFormatter()
    df.calendar = Calendar.current
    df.locale = Locale.current
    df.timeZone = TimeZone.current
    df.dateStyle = .full
    df.timeStyle = .none
    return df
  }()

  static func floorToMinute(_ date: Date) -> Date {
    let interval = floor(date.timeIntervalSinceReferenceDate / 60) * 60
    return Date(timeIntervalSinceReferenceDate: interval)
  }

  static func ceilToMinute(_ date: Date) -> Date {
    let interval = ceil(date.timeIntervalSinceReferenceDate / 60) * 60
    return Date(timeIntervalSinceReferenceDate: interval)
  }
}

