import AppKit
import SwiftUI

final class StatsWindowController {
  private let panel: NSPanel

  init(trackingEngine: TrackingEngine, database: DatabaseManager, settings: AppSettings) {
    let view = StatsView(trackingEngine: trackingEngine, database: database)
      .environmentObject(settings)
      .frame(minWidth: 640, minHeight: 360)

    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    panel.title = "Stats"
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = false
    panel.level = .normal
    panel.center()
    panel.contentView = NSHostingView(rootView: view)
  }

  func show() {
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func hide() {
    panel.orderOut(nil)
  }
}
