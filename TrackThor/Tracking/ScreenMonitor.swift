import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

@MainActor
final class ScreenMonitor: NSObject, ObservableObject {
  private static let lockScreenBundleIDs: Set<String> = [
    "com.apple.loginwindow",
    "com.apple.ScreenSaver.Engine"
  ]

  @Published private(set) var isScreenUnlocked: Bool = true
  @Published private(set) var isSystemSleeping: Bool = false
  @Published private(set) var isDisplaySleeping: Bool = false
  @Published private(set) var isLidClosed: Bool = false
  /// An external (non built-in) display is connected and not asleep.
  @Published private(set) var hasAwakeExternalDisplay: Bool = false
  @Published private(set) var idleDuration: TimeInterval = 0

  /// A closed lid only counts as "not working" when there's no awake external display (clamshell mode).
  /// Clamshell still has to pass every other check (system awake, unlocked, display awake, not idle).
  var isLidBlockingWork: Bool {
    isLidClosed && !hasAwakeExternalDisplay
  }

  private var workspaceObservers: [NSObjectProtocol] = []
  private var verificationTimer: Timer?

  func start() {
    stop()

    let dnc = DistributedNotificationCenter.default()
    dnc.addObserver(
      self,
      selector: #selector(handleScreenLocked),
      name: Notification.Name("com.apple.screenIsLocked"),
      object: nil,
      suspensionBehavior: .deliverImmediately
    )
    dnc.addObserver(
      self,
      selector: #selector(handleScreenUnlocked),
      name: Notification.Name("com.apple.screenIsUnlocked"),
      object: nil,
      suspensionBehavior: .deliverImmediately
    )

    let nc = NSWorkspace.shared.notificationCenter
    workspaceObservers.append(
      nc.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.reconcileCurrentState()
        }
      }
    )
    workspaceObservers.append(
      nc.addObserver(
        forName: NSWorkspace.willSleepNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.isSystemSleeping = true
          self?.isDisplaySleeping = true
        }
      }
    )
    workspaceObservers.append(
      nc.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.isSystemSleeping = false
          self?.reconcileCurrentState()
        }
      }
    )
    workspaceObservers.append(
      nc.addObserver(
        forName: NSWorkspace.screensDidSleepNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.isDisplaySleeping = true
        }
      }
    )
    workspaceObservers.append(
      nc.addObserver(
        forName: NSWorkspace.screensDidWakeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.isDisplaySleeping = false
          self?.reconcileCurrentState()
        }
      }
    )
    workspaceObservers.append(
      nc.addObserver(
        forName: NSWorkspace.sessionDidBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.isScreenUnlocked = true
          self?.isDisplaySleeping = false
          self?.reconcileCurrentState()
        }
      }
    )
    workspaceObservers.append(
      nc.addObserver(
        forName: NSWorkspace.sessionDidResignActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.isScreenUnlocked = false
        }
      }
    )

    reconcileCurrentState()

    verificationTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.reconcileCurrentState()
      }
    }
  }

  func stop() {
    let dnc = DistributedNotificationCenter.default()
    dnc.removeObserver(self, name: Notification.Name("com.apple.screenIsLocked"), object: nil)
    dnc.removeObserver(self, name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)

    let nc = NSWorkspace.shared.notificationCenter
    for observer in workspaceObservers {
      nc.removeObserver(observer)
    }
    workspaceObservers.removeAll()

    verificationTimer?.invalidate()
    verificationTimer = nil
  }

  @objc private func handleScreenLocked() {
    isScreenUnlocked = false
    isDisplaySleeping = true
  }

  @objc private func handleScreenUnlocked() {
    isScreenUnlocked = true
    isDisplaySleeping = false
    reconcileCurrentState()
  }

  func reconcileCurrentState() {
    var resolvedUnlocked = true
    var resolvedDisplaySleeping = isDisplaySleeping
    var sessionOnConsole: Bool?
    var sessionLoginDone: Bool?
    let lidClosed = readLidClosedState()
    let displays = readDisplayState()
    let lidBlocksWork = lidClosed && !displays.externalAwake
    let idleDuration = readIdleDuration()

    // Every display asleep means nobody can be using the Mac, regardless of lid state.
    if isSystemSleeping || lidBlocksWork || !displays.anyAwake {
      resolvedDisplaySleeping = true
    } else {
      resolvedDisplaySleeping = false
    }

    if resolvedDisplaySleeping {
      resolvedUnlocked = false
    }

    if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
      sessionOnConsole = boolValue(for: "kCGSessionOnConsoleKey", in: session)
      sessionLoginDone = boolValue(for: "kCGSessionLoginDoneKey", in: session)

      if let locked = boolValue(for: "CGSSessionScreenIsLocked", in: session) {
        resolvedUnlocked = !locked
        if locked {
          resolvedDisplaySleeping = true
        }
      }
      if let loginDone = sessionLoginDone, !loginDone {
        resolvedUnlocked = false
        resolvedDisplaySleeping = true
      }
      if let onConsole = sessionOnConsole, !onConsole {
        resolvedUnlocked = false
      }
    }

    if let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
      if Self.lockScreenBundleIDs.contains(frontmostBundleID) {
        resolvedUnlocked = false
        resolvedDisplaySleeping = true
      }

      if frontmostBundleID == "com.apple.ScreenSaver.Engine" {
        resolvedDisplaySleeping = true
      }
    }

    isScreenUnlocked = resolvedUnlocked
    isDisplaySleeping = resolvedDisplaySleeping
    isLidClosed = lidClosed
    hasAwakeExternalDisplay = displays.externalAwake
    self.idleDuration = idleDuration
  }

  /// Reads the online displays (including sleeping ones) and reports whether any display is awake
  /// and whether an awake external display is present. Fails open (`anyAwake = true`) if the list
  /// can't be read, so a CoreGraphics hiccup never blocks tracking on its own; the other checks remain.
  private func readDisplayState() -> (anyAwake: Bool, externalAwake: Bool) {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
      return (anyAwake: true, externalAwake: false)
    }

    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
      return (anyAwake: true, externalAwake: false)
    }

    var anyAwake = false
    var externalAwake = false
    for display in displays.prefix(Int(count)) where CGDisplayIsAsleep(display) == 0 {
      anyAwake = true
      if CGDisplayIsBuiltin(display) == 0 {
        externalAwake = true
      }
    }
    return (anyAwake: anyAwake, externalAwake: externalAwake)
  }

  private func boolValue(for key: String, in dictionary: [String: Any]) -> Bool? {
    if let value = dictionary[key] as? Bool {
      return value
    }
    if let value = dictionary[key] as? NSNumber {
      return value.boolValue
    }
    return nil
  }

  private func readLidClosedState() -> Bool {
    let rootDomain = IORegistryEntryFromPath(kIOMainPortDefault, "\(kIOServicePlane):/IOResources/IOPMrootDomain")
    guard rootDomain != MACH_PORT_NULL else { return false }
    defer { IOObjectRelease(rootDomain) }

    guard let property = IORegistryEntryCreateCFProperty(
      rootDomain,
      "AppleClamshellClosed" as CFString,
      kCFAllocatorDefault,
      0
    )?.takeRetainedValue() else {
      return false
    }

    if let isClosed = property as? Bool {
      return isClosed
    }
    if let isClosed = property as? NSNumber {
      return isClosed.boolValue
    }
    return false
  }

  private func readIdleDuration() -> TimeInterval {
    guard let matching = IOServiceMatching("IOHIDSystem") else { return 0 }

    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != MACH_PORT_NULL else { return 0 }
    defer { IOObjectRelease(service) }

    guard let property = IORegistryEntryCreateCFProperty(
      service,
      "HIDIdleTime" as CFString,
      kCFAllocatorDefault,
      0
    )?.takeRetainedValue() else {
      return 0
    }

    let nanoseconds: UInt64?
    if let value = property as? NSNumber {
      nanoseconds = value.uint64Value
    } else if let value = property as? UInt64 {
      nanoseconds = value
    } else {
      nanoseconds = nil
    }

    guard let nanoseconds else { return 0 }
    return TimeInterval(nanoseconds) / 1_000_000_000
  }
}
