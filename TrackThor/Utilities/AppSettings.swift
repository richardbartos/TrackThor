import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
  private enum Keys {
    static let workSSIDs = "workSSIDs"
    static let dailyGoalMinutes = "dailyGoalMinutes"
    static let legacyDailyGoalHours = "dailyGoalHours"
    static let minimumVisibleGapMinutes = "minimumVisibleGapMinutes"
    static let launchAtLogin = "launchAtLogin"
  }

  @Published var workSSIDs: [String] {
    didSet { UserDefaults.standard.set(workSSIDs, forKey: Keys.workSSIDs) }
  }

  @Published var dailyGoalMinutes: Int {
    didSet { UserDefaults.standard.set(dailyGoalMinutes, forKey: Keys.dailyGoalMinutes) }
  }

  @Published var launchAtLogin: Bool {
    didSet { UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin) }
  }

  @Published var minimumVisibleGapMinutes: Int {
    didSet { UserDefaults.standard.set(minimumVisibleGapMinutes, forKey: Keys.minimumVisibleGapMinutes) }
  }

  init() {
    self.workSSIDs = UserDefaults.standard.stringArray(forKey: Keys.workSSIDs) ?? []
    if let storedGoalMinutes = UserDefaults.standard.object(forKey: Keys.dailyGoalMinutes) as? Int {
      self.dailyGoalMinutes = storedGoalMinutes
    } else if let legacyGoalHours = UserDefaults.standard.object(forKey: Keys.legacyDailyGoalHours) as? Int {
      self.dailyGoalMinutes = legacyGoalHours * 60
    } else {
      self.dailyGoalMinutes = 8 * 60
    }
    if let storedMinimumGap = UserDefaults.standard.object(forKey: Keys.minimumVisibleGapMinutes) as? Int {
      self.minimumVisibleGapMinutes = max(1, storedMinimumGap)
    } else {
      self.minimumVisibleGapMinutes = 5
    }
    let storedLogin = UserDefaults.standard.object(forKey: Keys.launchAtLogin) as? Bool
    self.launchAtLogin = storedLogin ?? true
  }

  var dailyGoalHoursComponent: Int {
    get { dailyGoalMinutes / 60 }
    set { dailyGoalMinutes = (newValue * 60) + dailyGoalMinuteComponent }
  }

  var dailyGoalMinuteComponent: Int {
    get { dailyGoalMinutes % 60 }
    set { dailyGoalMinutes = (dailyGoalHoursComponent * 60) + newValue }
  }

  var minimumVisibleGapDuration: TimeInterval {
    TimeInterval(max(1, minimumVisibleGapMinutes) * 60)
  }
}
