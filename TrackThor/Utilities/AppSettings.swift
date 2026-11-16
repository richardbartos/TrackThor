import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
  private enum Keys {
    static let workSSIDs = "workSSIDs"
    static let minimumVisibleGapMinutes = "minimumVisibleGapMinutes"
    static let launchAtLogin = "launchAtLogin"
  }

  @Published var workSSIDs: [String] {
    didSet { UserDefaults.standard.set(workSSIDs, forKey: Keys.workSSIDs) }
  }

  @Published var launchAtLogin: Bool {
    didSet {
      UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
      applyLaunchAtLogin()
    }
  }

  @Published var minimumVisibleGapMinutes: Int {
    didSet { UserDefaults.standard.set(minimumVisibleGapMinutes, forKey: Keys.minimumVisibleGapMinutes) }
  }

  /// Mirrors `SMAppService.mainApp.status` so the UI can explain when macOS blocks the login item.
  @Published private(set) var launchAtLoginStatus: SMAppService.Status = SMAppService.mainApp.status

  init() {
    self.workSSIDs = UserDefaults.standard.stringArray(forKey: Keys.workSSIDs) ?? []
    if let storedMinimumGap = UserDefaults.standard.object(forKey: Keys.minimumVisibleGapMinutes) as? Int {
      self.minimumVisibleGapMinutes = max(1, storedMinimumGap)
    } else {
      self.minimumVisibleGapMinutes = 5
    }
    let storedLogin = UserDefaults.standard.object(forKey: Keys.launchAtLogin) as? Bool
    self.launchAtLogin = storedLogin ?? true
  }

  var minimumVisibleGapDuration: TimeInterval {
    TimeInterval(max(1, minimumVisibleGapMinutes) * 60)
  }

  /// Makes the system login item match the stored preference. `didSet` doesn't run during `init`,
  /// so this must also be called once at app launch — otherwise the default (`true`) is never registered.
  func applyLaunchAtLogin() {
    let service = SMAppService.mainApp
    do {
      switch (launchAtLogin, service.status) {
      case (true, .notRegistered), (true, .notFound):
        try service.register()
      case (false, .enabled), (false, .requiresApproval):
        try service.unregister()
      default:
        // Already in the desired state, or the user disabled it in System Settings (.requiresApproval) —
        // re-registering can't override that, so leave it and surface the status in Settings instead.
        break
      }
    } catch {
      NSLog("TrackThor: failed to update login item (enabled=\(launchAtLogin)): \(error)")
    }
    launchAtLoginStatus = service.status
  }

  func refreshLaunchAtLoginStatus() {
    launchAtLoginStatus = SMAppService.mainApp.status
  }
}
