import AppKit
import SwiftUI

final class StatsWindowController {
  private let panel: NSPanel

  init(trackingEngine: TrackingEngine, database: DatabaseManager, settings: AppSettings) {
    let view = StatsView(trackingEngine: trackingEngine, database: database)
      .environmentObject(settings)
      .frame(minWidth: 860, minHeight: 560)

    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    panel.title = "Stats"
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = false
    panel.hidesOnDeactivate = false
    panel.level = .normal
    panel.center()
    panel.contentView = NSHostingView(rootView: view)
  }

  func show() {
    panel.makeKeyAndOrderFront(nil)
    panel.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
  }

  func hide() {
    panel.orderOut(nil)
  }
}
