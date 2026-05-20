import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem!
  private let popover = NSPopover()
  private var statusBarButton: NSStatusBarButton? { statusItem.button }
  private var settingsWindow: NSWindow?
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

  private lazy var statsWindowController = StatsWindowController(
    trackingEngine: trackingEngine,
    database: databaseManager,
    settings: settings
  )

  func applicationWillFinishLaunching(_ notification: Notification) {
    terminateOtherRunningInstances()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    _ = databaseManager

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusBarButton?.title = "--:--"
    statusBarButton?.imagePosition = .noImage
    statusBarButton?.action = #selector(togglePopover(_:))
    statusBarButton?.target = self

    popover.behavior = .transient
    popover.contentSize = NSSize(width: 340, height: 420)

    let root = PopoverView(
      trackingEngine: trackingEngine,
      database: databaseManager,
      onOpenStats: { [weak self] in self?.openStats() },
      onOpenSettings: { [weak self] in self?.openSettings() },
      onQuit: { NSApp.terminate(nil) }
    )
    .environmentObject(settings)

    popover.contentViewController = NSHostingController(rootView: root)

    trackingEngine.onStatusChanged = { [weak self] title, isActive in
      guard let self, let button = self.statusBarButton else { return }
      button.title = title
      button.image = isActive ? self.activeStatusImage : nil
      button.imagePosition = isActive ? .imageLeading : .noImage
    }
    trackingEngine.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    trackingEngine.stop()
  }

  @objc private func togglePopover(_ sender: Any?) {
    guard let button = statusItem.button else { return }
    if popover.isShown {
      popover.performClose(sender)
    } else {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func openStats() {
    settingsWindow?.orderOut(nil)
    statsWindowController.show()
  }

  private func openSettings() {
    statsWindowController.hide()
    if let settingsWindow {
      settingsWindow.makeKeyAndOrderFront(nil)
      settingsWindow.orderFrontRegardless()
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Settings"
    window.center()
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: SettingsView(wifiMonitor: wifiMonitor).environmentObject(settings))
    settingsWindow = window
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
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
