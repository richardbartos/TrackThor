import CoreLocation
import ServiceManagement
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  @StateObject private var location = LocationPermissionManager()

  let wifiMonitor: WiFiMonitor

  @State private var newSSID: String = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        networkCard
        gapCard
        launchCard
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(windowBackground)
    .onAppear {
      location.requestIfNeeded()
    }
  }

  private var networkCard: some View {
    settingsCard(title: "Work Wi-Fi", subtitle: "Track automatically whenever one of these SSIDs is active.") {
      VStack(alignment: .leading, spacing: 12) {
        settingGroup(title: "Add Network", detail: "Add the office Wi-Fi names that should trigger automatic tracking.") {
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
              TextField("Add SSID", text: $newSSID)
                .textFieldStyle(.roundedBorder)
              Button("Add") { addSSID() }
                .buttonStyle(.borderedProminent)
                .disabled(newSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 10) {
              Button("Use Current Network") {
                location.requestIfNeeded()
                wifiMonitor.poll()
                if let ssid = wifiMonitor.currentSSID {
                  newSSID = ssid
                  addSSID()
                }
              }
              .buttonStyle(.bordered)
              .disabled(!(location.status == .authorizedAlways || location.status == .authorized))

              if let currentSSID = wifiMonitor.currentSSID {
                Text("Current: \(currentSSID)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

        if settings.workSSIDs.isEmpty {
          settingsHint("Add at least one work SSID to enable office auto tracking.")
        } else {
          settingGroup(title: "Tracked Networks", detail: "\(settings.workSSIDs.count) saved network\(settings.workSSIDs.count == 1 ? "" : "s").") {
            VStack(spacing: 6) {
            ForEach(settings.workSSIDs, id: \.self) { ssid in
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(ssid)
                    .font(.system(size: 14, weight: .medium))
                  Text("Tracked network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remove", role: .destructive) {
                  removeSSID(ssid)
                }
                .buttonStyle(.borderless)
              }
              .padding(.vertical, 7)
              .padding(.horizontal, 10)
              .background(Color.white.opacity(0.72))
              .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .stroke(Color.black.opacity(0.05), lineWidth: 1)
              )
            }
          }
          }
        }

        if location.status == .denied || location.status == .restricted {
          settingsHint("Location permission is required to read the current Wi-Fi network name on macOS 13+.")
        }
      }
    }
  }

  private var launchCard: some View {
    settingsCard(title: "App Behavior", subtitle: "Control how TrackThor starts with macOS.") {
      settingGroup(title: "Startup", detail: "Keep TrackThor available right after login.") {
        Toggle("Launch at login", isOn: $settings.launchAtLogin)
          .toggleStyle(.switch)
          .onChange(of: settings.launchAtLogin) { enabled in
            setLaunchAtLogin(enabled)
          }
      }
    }
  }

  private var gapCard: some View {
    settingsCard(title: "Gap Display", subtitle: "Hide short gaps from summaries and stats.") {
      VStack(alignment: .leading, spacing: 12) {
        settingGroup(title: "Visibility Threshold", detail: "Short interruptions under this limit stay hidden in the UI.") {
          stepperCard(title: "Minimum gap", valueText: "\(settings.minimumVisibleGapMinutes) min") {
            Stepper("", value: minimumVisibleGapMinutesBinding, in: 1...30)
              .labelsHidden()
          }
        }

        settingsHint("Gaps shorter than \(settings.minimumVisibleGapMinutes) minute\(settings.minimumVisibleGapMinutes == 1 ? "" : "s") won’t be shown or subtracted in the UI.")
      }
    }
  }

  private func settingsCard<Content: View>(
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 17, weight: .semibold))
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      content()
    }
    .padding(14)
    .background(cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(Color.black.opacity(0.06), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.04), radius: 10, y: 4)
  }

  private func stepperCard<Content: View>(
    title: String,
    valueText: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Text(valueText)
          .font(.system(size: 20, weight: .semibold))
        Spacer()
        content()
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.white.opacity(0.76))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.black.opacity(0.05), lineWidth: 1)
    )
  }

  private func settingGroup<Content: View>(
    title: String,
    detail: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 13, weight: .semibold))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      content()
    }
  }

  private func settingsHint(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 2)
  }

  private var windowBackground: some View {
    LinearGradient(
      colors: [
        Color(red: 0.96, green: 0.97, blue: 0.99),
        Color(red: 0.93, green: 0.95, blue: 0.98)
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private var cardBackground: some View {
    LinearGradient(
      colors: [
        Color.white.opacity(0.92),
        Color(red: 0.95, green: 0.97, blue: 1.0)
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private func addSSID() {
    let trimmed = newSSID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if !settings.workSSIDs.contains(trimmed) {
      settings.workSSIDs.append(trimmed)
      settings.workSSIDs.sort()
    }
    newSSID = ""
  }

  private func removeSSID(_ ssid: String) {
    settings.workSSIDs.removeAll { $0 == ssid }
  }

  private func setLaunchAtLogin(_ enabled: Bool) {
    guard #available(macOS 13.0, *) else { return }
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      // best-effort; keep toggle value stored
    }
  }

  private var minimumVisibleGapMinutesBinding: Binding<Int> {
    Binding(
      get: { settings.minimumVisibleGapMinutes },
      set: { settings.minimumVisibleGapMinutes = $0 }
    )
  }
}
