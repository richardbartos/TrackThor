import AppKit
import SwiftUI

enum AppSection: String, Hashable, CaseIterable, Identifiable {
  case stats
  case clockify
  case general
  case wifi
  case meetings
  case clockifyAccount

  var id: String { rawValue }

  var title: String {
    switch self {
    case .stats: return "Stats"
    case .clockify: return "Clockify Report"
    case .general: return "General"
    case .wifi: return "Office Wi‑Fi"
    case .meetings: return "Meetings"
    case .clockifyAccount: return "Clockify Account"
    }
  }

  var systemImage: String {
    switch self {
    case .stats: return "chart.bar.xaxis"
    case .clockify: return "paperplane"
    case .general: return "gearshape"
    case .wifi: return "wifi"
    case .meetings: return "calendar"
    case .clockifyAccount: return "person.crop.circle.badge.checkmark"
    }
  }
}

@MainActor
final class AppNavigation: ObservableObject {
  @Published var section: AppSection? = .stats
}

/// The single app window: sidebar navigation between stats, the Clockify report and settings.
struct MainView: View {
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject var navigation: AppNavigation
  @ObservedObject var trackingEngine: TrackingEngine
  @ObservedObject var meetingSync: MeetingSync
  @ObservedObject var clockify: ClockifyService
  @ObservedObject var clockifyReport: ClockifyReportModel
  let wifiMonitor: WiFiMonitor
  let database: DatabaseManager
  let bringToFront: () -> Void

  var body: some View {
    NavigationSplitView {
      List(selection: $navigation.section) {
        Section("Activity") {
          row(.stats)
          row(.clockify)
        }
        Section("Settings") {
          row(.general)
          row(.wifi, needsAttention: settings.workSSIDs.isEmpty)
          row(.meetings, needsAttention: !meetingSync.isConfigured)
          row(.clockifyAccount, needsAttention: !clockify.isReadyToPush)
        }
      }
      .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
    } detail: {
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      settings.refreshLaunchAtLoginStatus()
      meetingSync.refreshAccess()
    }
  }

  /// The tag must be the outermost modifier, otherwise List selection ignores the row.
  private func row(_ section: AppSection, needsAttention: Bool = false) -> some View {
    Label(section.title, systemImage: section.systemImage)
      .badge(needsAttention ? Text(Image(systemName: "exclamationmark.circle.fill")).foregroundStyle(.orange) : nil)
      .tag(section)
  }

  @ViewBuilder
  private var detail: some View {
    switch navigation.section ?? .stats {
    case .stats:
      StatsView(trackingEngine: trackingEngine, meetingSync: meetingSync, database: database)
    case .clockify:
      ClockifyReportView(
        model: clockifyReport,
        service: clockify,
        onOpenSettings: { navigation.section = .clockifyAccount }
      )
    case .general:
      GeneralSettingsView()
    case .wifi:
      WiFiSettingsView(wifiMonitor: wifiMonitor)
    case .meetings:
      MeetingsSettingsView(meetingSync: meetingSync, bringToFront: bringToFront)
    case .clockifyAccount:
      ClockifySettingsView(clockify: clockify)
    }
  }
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
  private let navigation = AppNavigation()
  private var window: NSWindow!

  private static let frameName = "TrackThorMainWindow"

  init(
    settings: AppSettings,
    trackingEngine: TrackingEngine,
    meetingSync: MeetingSync,
    clockify: ClockifyService,
    wifiMonitor: WiFiMonitor,
    database: DatabaseManager
  ) {
    super.init()

    let root = MainView(
      navigation: navigation,
      trackingEngine: trackingEngine,
      meetingSync: meetingSync,
      clockify: clockify,
      clockifyReport: ClockifyReportModel(service: clockify),
      wifiMonitor: wifiMonitor,
      database: database,
      bringToFront: { [weak self] in self?.bringToFront() }
    )
    .environmentObject(settings)

    let controller = NSHostingController(rootView: root)
    // Let SwiftUI provide the toolbar (sidebar toggle) and the window title.
    controller.sceneBridgingOptions = [.toolbars, .title]
    // The window decides its own size; SwiftUI doesn't resize it.
    controller.sizingOptions = []

    let window = NSWindow(contentViewController: controller)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.minSize = NSSize(width: 900, height: 580)
    window.isReleasedWhenClosed = false
    window.delegate = self
    if !window.setFrameUsingName(Self.frameName) {
      window.setContentSize(NSSize(width: 1180, height: 780))
      window.center()
    }
    window.setFrameAutosaveName(Self.frameName)
    self.window = window
  }

  func show(_ section: AppSection) {
    navigation.section = section
    bringToFront()
  }

  /// While the window is open TrackThor behaves like a regular app (Dock icon, Cmd-Tab), so it's easy
  /// to switch back to; closing it returns to menu-bar-only.
  func bringToFront() {
    NSApp.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}
