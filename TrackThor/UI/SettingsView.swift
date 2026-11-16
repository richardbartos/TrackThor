import AppKit
import CoreLocation
import ServiceManagement
import SwiftUI

// MARK: - General

struct GeneralSettingsView: View {
  @EnvironmentObject private var settings: AppSettings

  var body: some View {
    Form {
      Section {
        Toggle("Launch at login", isOn: $settings.launchAtLogin)
        if settings.launchAtLogin && settings.launchAtLoginStatus == .requiresApproval {
          LabeledContent {
            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
          } label: {
            Label("TrackThor is turned off in Login Items", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
        }
      } header: {
        Text("Startup")
      }

      Section {
        Stepper(value: $settings.minimumVisibleGapMinutes, in: 1...30) {
          LabeledContent("Minimum gap", value: "\(settings.minimumVisibleGapMinutes) min")
        }
      } header: {
        Text("Gaps")
      } footer: {
        Text("Breaks shorter than this aren't shown or subtracted, and you count as away after this long without keyboard or mouse input (at least 1 minute).")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("General")
    .onAppear { settings.refreshLaunchAtLoginStatus() }
  }
}

// MARK: - Office Wi-Fi

struct WiFiSettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject var wifiMonitor: WiFiMonitor
  @StateObject private var location = LocationPermissionManager()
  @State private var newSSID = ""

  var body: some View {
    Form {
      Section {
        if settings.workSSIDs.isEmpty {
          Text("No office networks yet — add one below.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(settings.workSSIDs, id: \.self) { ssid in
            HStack {
              Label(ssid, systemImage: "wifi")
              Spacer()
              if ssid == wifiMonitor.currentSSID {
                Text("Connected")
                  .font(.caption)
                  .foregroundStyle(.green)
              }
              Button {
                settings.workSSIDs.removeAll { $0 == ssid }
              } label: {
                Image(systemName: "minus.circle.fill")
                  .foregroundStyle(.red)
              }
              .buttonStyle(.borderless)
              .help("Remove \(ssid)")
            }
          }
        }
      } header: {
        Text("Office networks")
      } footer: {
        Text("TrackThor tracks automatically while you're on one of these networks and using the Mac.")
      }

      Section("Add network") {
        HStack {
          TextField("Network name", text: $newSSID, prompt: Text("Wi‑Fi name (SSID)"))
            .labelsHidden()
            .onSubmit { add(newSSID) }
          Button("Add") { add(newSSID) }
            .disabled(newSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        if !hasLocationAccess {
          LabeledContent {
            Button(location.status == .notDetermined ? "Allow" : "Open Privacy Settings") {
              if location.status == .notDetermined {
                location.requestIfNeeded()
              } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
              }
            }
          } label: {
            Label("Location access is needed to read the Wi‑Fi name", systemImage: "location.slash")
              .foregroundStyle(.orange)
          }
        } else if let current = wifiMonitor.currentSSID {
          if settings.workSSIDs.contains(current) {
            LabeledContent("Current network", value: "\(current) (already added)")
          } else {
            LabeledContent("Current network") {
              Button("Add “\(current)”") { add(current) }
            }
          }
        } else {
          LabeledContent("Current network", value: "Not connected")
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Office Wi‑Fi")
    .onAppear {
      location.requestIfNeeded()
      wifiMonitor.poll()
    }
  }

  private var hasLocationAccess: Bool {
    location.status == .authorizedAlways || location.status == .authorized
  }

  private func add(_ ssid: String) {
    let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if !settings.workSSIDs.contains(trimmed) {
      settings.workSSIDs.append(trimmed)
      settings.workSSIDs.sort()
    }
    newSSID = ""
  }
}

// MARK: - Meetings

struct MeetingsSettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject var meetingSync: MeetingSync
  /// The permission prompt deactivates the app (it's a menu bar app), so the window must be brought back.
  let bringToFront: () -> Void

  var body: some View {
    Form {
      switch meetingSync.access {
      case .notDetermined:
        Section {
          LabeledContent {
            Button("Allow Calendar Access") {
              Task {
                await meetingSync.requestAccess()
                bringToFront()
              }
            }
            .buttonStyle(.borderedProminent)
          } label: {
            Text("TrackThor reads meetings from the macOS Calendar app.")
          }
        } header: {
          Text("Calendar access")
        } footer: {
          Text("Add Google or other accounts in System Settings → Internet Accounts.")
        }

      case .denied:
        Section("Calendar access") {
          LabeledContent {
            Button("Open Privacy Settings") {
              if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
              }
            }
          } label: {
            Label("Calendar access is turned off", systemImage: "calendar.badge.exclamationmark")
              .foregroundStyle(.orange)
          }
        }

      case .granted:
        if meetingSync.calendars.isEmpty {
          Section("Calendars") {
            Text("No calendars found. Add your account in System Settings → Internet Accounts.")
              .foregroundStyle(.secondary)
          }
        } else {
          ForEach(calendarSources, id: \.self) { source in
            Section(source) {
              ForEach(meetingSync.calendars.filter { $0.sourceTitle == source }) { calendar in
                Toggle(isOn: selection(calendar.id)) {
                  HStack(spacing: 8) {
                    Circle()
                      .fill(Color(nsColor: calendar.color))
                      .frame(width: 10, height: 10)
                    Text(calendar.title)
                  }
                }
              }
            }
          }
        }

        Section {
          LabeledContent("Counts as a meeting", value: "Timed events with at least one other person")
          LabeledContent("Ignored", value: "Declined, all-day, “placeholder”, “reminder”")
          LabeledContent("Out of office", value: "Events with “OOO” in the title")
        } header: {
          Text("Rules")
        } footer: {
          Text(settings.meetingCalendarIDs.isEmpty
            ? "Turn on your work calendar to start tracking meetings."
            : "Meetings count even when you're away from the Mac. Changing the selection recalculates past days.")
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Meetings")
    .onAppear { meetingSync.refreshAccess() }
  }

  private var calendarSources: [String] {
    var seen: [String] = []
    for calendar in meetingSync.calendars where !seen.contains(calendar.sourceTitle) {
      seen.append(calendar.sourceTitle)
    }
    return seen
  }

  private func selection(_ id: String) -> Binding<Bool> {
    Binding(
      get: { settings.meetingCalendarIDs.contains(id) },
      set: { isOn in
        var ids = settings.meetingCalendarIDs.filter { $0 != id }
        if isOn { ids.append(id) }
        settings.meetingCalendarIDs = ids.sorted()
      }
    )
  }
}

// MARK: - Clockify account

struct ClockifySettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject var clockify: ClockifyService
  @State private var keyInput = ""

  var body: some View {
    Form {
      Section {
        HStack {
          SecureField(
            "API key",
            text: $keyInput,
            prompt: Text(clockify.hasAPIKey ? "Saved — paste a new key to replace it" : "Paste your API key")
          )
          .onSubmit(saveKey)
          Button("Save", action: saveKey)
            .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        if clockify.hasAPIKey {
          LabeledContent("Status") {
            HStack(spacing: 8) {
              connectionStatus
              Button("Test") { Task { await clockify.connect() } }
                .disabled(clockify.isConnecting)
              Button("Remove Key", role: .destructive) { Task { await clockify.saveAPIKey("") } }
            }
          }
        }
      } header: {
        Text("Account")
      } footer: {
        Text("Generate a key in Clockify → Profile Settings. It's stored in your macOS Keychain.")
      }

      Section("Workspace") {
        Picker("Data region", selection: $settings.clockifyRegion) {
          ForEach(ClockifyRegion.allCases) { region in
            Text(region.title).tag(region)
          }
        }
        .onChange(of: settings.clockifyRegion) { _, _ in
          Task { await clockify.connect() }
        }

        if !clockify.workspaces.isEmpty {
          Picker("Workspace", selection: $settings.clockifyWorkspaceId) {
            ForEach(clockify.workspaces) { workspace in
              Text(workspace.name).tag(workspace.id)
            }
          }
          .onChange(of: settings.clockifyWorkspaceId) { _, _ in
            settings.clockifyMeetingProjectId = ""
            settings.clockifyWorkProjectId = ""
            Task { await clockify.loadProjects() }
          }
        }
      }

      if !clockify.workspaces.isEmpty {
        Section {
          projectPicker("Meetings", selection: $settings.clockifyMeetingProjectId)
          projectPicker("Rest of the day", selection: $settings.clockifyWorkProjectId)
          Toggle("Billable", isOn: $settings.clockifyBillable)
        } header: {
          Text("Projects")
        } footer: {
          Text("Each day becomes a meeting entry followed directly by an entry for the rest of the day.")
        }
      }

      Section("Reporting rules") {
        LabeledContent("Rounding", value: "Nearest 15 minutes")
        LabeledContent("Lunch", value: "−30 min daily, unless OOO covers 11:00–14:00")
        LabeledContent("Out of office", value: "Removed; whole-day OOO days are skipped")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Clockify Account")
    .onAppear {
      if clockify.hasAPIKey && clockify.user == nil && !clockify.isConnecting {
        Task { await clockify.connect() }
      }
    }
  }

  @ViewBuilder
  private var connectionStatus: some View {
    if clockify.isConnecting {
      ProgressView().controlSize(.small)
    } else if let user = clockify.user {
      Label(user.name ?? user.email ?? "Connected", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    } else if let error = clockify.connectionError {
      Label(error, systemImage: "xmark.octagon.fill")
        .foregroundStyle(.red)
        .lineLimit(2)
    } else {
      Text("Not checked").foregroundStyle(.secondary)
    }
  }

  private func projectPicker(_ title: String, selection: Binding<String>) -> some View {
    Picker(title, selection: selection) {
      Text("Choose a project…").tag("")
      ForEach(clockify.projects) { project in
        Text(project.displayName).tag(project.id)
      }
    }
  }

  private func saveKey() {
    let key = keyInput
    guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    keyInput = ""
    Task { await clockify.saveAPIKey(key) }
  }
}
