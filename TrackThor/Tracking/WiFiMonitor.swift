@preconcurrency import CoreWLAN
import Combine
import Foundation

@MainActor
final class WiFiMonitor: NSObject, ObservableObject {
    @Published private(set) var currentSSID: String?
    @Published private(set) var isOnWorkWiFi: Bool = false

  private final class EventProxy: NSObject, CWEventDelegate {
    weak var monitor: WiFiMonitor?

    init(monitor: WiFiMonitor) {
      self.monitor = monitor
    }

    private func notifyMonitor() {
      Task { @MainActor [weak monitor] in
        monitor?.poll()
      }
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
      notifyMonitor()
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
      notifyMonitor()
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
      notifyMonitor()
    }

    func modeDidChangeForWiFiInterface(withName interfaceName: String) {
      notifyMonitor()
    }

    func clientConnectionInterrupted() {
      notifyMonitor()
    }

    func clientConnectionInvalidated() {
      notifyMonitor()
    }
  }

    private let wifiClient = CWWiFiClient.shared()
    private let locationPermission = LocationPermissionManager()
    private var timer: Timer?
    private var recoveryRefreshTask: Task<Void, Never>?
    private var settingsCancellable: AnyCancellable?
    private var locationPermissionCancellable: AnyCancellable?
    private unowned let settings: AppSettings
    private lazy var eventProxy = EventProxy(monitor: self)

    init(settings: AppSettings) {
        self.settings = settings
    super.init()
        settingsCancellable = settings.$workSSIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.poll()
            }
        locationPermissionCancellable = locationPermission.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.poll()
            }
    }

    func start() {
        locationPermission.requestIfNeeded()
        wifiClient.delegate = eventProxy
        poll()
        scheduleRecoveryRefreshes()
        startMonitoringEvents()
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.poll() }
    }
  }

  func stop() {
    do {
      try wifiClient.stopMonitoringAllEvents()
    } catch {
      // Fall back to timer polling if event monitoring is unavailable.
    }
    wifiClient.delegate = nil
    recoveryRefreshTask?.cancel()
    recoveryRefreshTask = nil
    timer?.invalidate()
    timer = nil
    }

    func poll() {
        let ssid = resolvedSSID()
        currentSSID = ssid
        if let ssid {
            isOnWorkWiFi = settings.workSSIDs.contains(ssid)
        } else {
            isOnWorkWiFi = false
        }
    }

  func refreshAfterWakeOrUnlock() {
    poll()
    scheduleRecoveryRefreshes()
  }

  private func startMonitoringEvents() {
    do {
      try wifiClient.startMonitoringEvent(with: .ssidDidChange)
      try wifiClient.startMonitoringEvent(with: .linkDidChange)
      try wifiClient.startMonitoringEvent(with: .powerDidChange)
      try wifiClient.startMonitoringEvent(with: .modeDidChange)
    } catch {
      // Event monitoring requires a system capability on some setups.
      // The fallback timer remains active so tracking still works.
    }
  }

    private func scheduleRecoveryRefreshes() {
        recoveryRefreshTask?.cancel()
        recoveryRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled else { return }
      self?.poll()

      try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.poll()
        }
    }

    private func resolvedSSID() -> String? {
        if let defaultInterface = wifiClient.interface(),
           defaultInterface.powerOn(),
           defaultInterface.serviceActive(),
           defaultInterface.bssid() != nil,
           let defaultSSID = defaultInterface.ssid()
        {
            return defaultSSID
        }

        let interfaces = wifiClient.interfaces() ?? []

        if let connectedSSID = interfaces
            .first(where: { $0.serviceActive() && $0.powerOn() && $0.bssid() != nil && $0.ssid() != nil })?
            .ssid()
        {
            return connectedSSID
        }

        return nil
    }
}
