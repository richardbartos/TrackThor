import Foundation

enum DurationFormatter {
  static func hoursMinutes(_ seconds: TimeInterval) -> String {
    let clamped = max(0, Int(seconds.rounded()))
    let h = clamped / 3600
    let m = (clamped % 3600) / 60
    if h <= 0 {
      return "\(m)m"
    }
    return "\(h)h \(m)m"
  }

  /// Rounds up to the next whole minute (minimum 1 minute if seconds > 0).
  static func hoursMinutesRoundedUpToMinute(_ seconds: TimeInterval) -> String {
    let s = max(0, seconds)
    if s == 0 { return "0m" }
    let rounded = ceil(s / 60) * 60
    return hoursMinutes(rounded)
  }

  static func hoursMinutes(fromMinutes minutes: Int) -> String {
    hoursMinutes(TimeInterval(max(0, minutes) * 60))
  }
}
