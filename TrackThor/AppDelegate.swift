import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem!
  private let popover = NSPopover()
  private var statusBarButton: NSStatusBarButton? { statusItem.button }
  private lazy var activeStatusImage: NSImage? = {
    let size = NSSize(width: 7, height: 7)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.systemGreen.setFill()
    NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
    image.unlockFocus()
    image.isTemplate = false
    return image
  }()

  private let settings = AppSettings()
  private let databaseManager = DatabaseManager.shared

  private lazy var wifiMonitor = WiFiMonitor(settings: settings)
  private lazy var screenMonitor = ScreenMonitor()
  private lazy var trackingEngine = TrackingEngine(
    settings: settings,
    database: databaseManager,
    wifiMonitor: wifiMonitor,
    screenMonitor: screenMonitor
  )

  private lazy var meetingSync = MeetingSync(settings: settings, database: databaseManager)
  private lazy var clockifyService = ClockifyService(settings: settings, database: databaseManager)
  private lazy var mainWindowController = MainWindowController(
    settings: settings,
    trackingEngine: trackingEngine,
    meetingSync: meetingSync,
    clockify: clockifyService,
    wifiMonitor: wifiMonitor,
    database: databaseManager
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    _ = databaseManager
    settings.applyLaunchAtLogin()
    // A menu bar app that switches to a regular app (Dock, Cmd-Tab) while its window is open
    // otherwise often shows the generic app icon there.
    if let icon = NSImage(named: "AppIcon") {
      NSApp.applicationIconImage = icon
    }

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    configureStatusItem()

    popover.behavior = .transient
    popover.contentSize = NSSize(width: 340, height: 420)
    configurePopoverContentIfNeeded()

    trackingEngine.onStatusChanged = { [weak self] title, isActive in
      guard let self, let button = self.statusBarButton else { return }
      button.title = title
      button.image = isActive ? self.activeStatusImage : nil
      button.imagePosition = isActive ? .imageLeading : .noImage
    }
    trackingEngine.meetingIntervalsProvider = { [weak self] in
      self?.meetingSync.todayMeetingIntervals ?? []
    }
    trackingEngine.start()
    meetingSync.start()

    Task { @MainActor in
      terminateOtherRunningInstances()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    trackingEngine.stop()
    meetingSync.stop()
  }

  @objc private func togglePopover(_ sender: Any?) {
    guard let button = statusItem.button else { return }
    if popover.isShown {
      popover.performClose(sender)
    } else {
      configurePopoverContentIfNeeded()
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func configureStatusItem() {
    guard let button = statusBarButton else { return }

    button.title = "--:--"
    button.imagePosition = .noImage
    button.action = #selector(togglePopover(_:))
    button.target = self
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
  }

  private func configurePopoverContentIfNeeded() {
    guard popover.contentViewController == nil else { return }

    let root = PopoverView(
      trackingEngine: trackingEngine,
      meetingSync: meetingSync,
      database: databaseManager,
      onOpenStats: { [weak self] in self?.open(.stats) },
      onOpenSettings: { [weak self] in self?.open(.general) },
      onOpenClockify: { [weak self] in self?.open(.clockify) },
      onQuit: { NSApp.terminate(nil) }
    )
    .environmentObject(settings)
    .frame(width: 340)

    // Size the popover to its content (the meetings line is only shown when configured).
    let controller = NSHostingController(rootView: root)
    controller.sizingOptions = [.preferredContentSize]
    popover.contentViewController = controller
  }

  func open(_ section: AppSection) {
    popover.performClose(nil)
    mainWindowController.show(section)
  }

  private func terminateOtherRunningInstances() {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

    let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    let otherInstances = NSRunningApplication
      .runningApplications(withBundleIdentifier: bundleIdentifier)
      .filter { $0.processIdentifier != currentProcessIdentifier }

    for application in otherInstances {
      if !application.terminate() {
        application.forceTerminate()
      }
    }
  }
}
