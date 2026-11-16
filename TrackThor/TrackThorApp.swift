import SwiftUI

@main
struct TrackThorApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    // The app UI lives in the menu bar popover and the main window (see AppDelegate).
    Settings {
      EmptyView()
    }
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { appDelegate.open(.general) }
          .keyboardShortcut(",", modifiers: .command)
      }
    }
  }
}
