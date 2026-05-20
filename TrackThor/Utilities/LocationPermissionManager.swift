import CoreLocation
import Foundation

@MainActor
final class LocationPermissionManager: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
  @Published private(set) var status: CLAuthorizationStatus = .notDetermined

  private let manager = CLLocationManager()

  override init() {
    super.init()
    manager.delegate = self
    status = manager.authorizationStatus
  }

  func requestIfNeeded() {
    status = manager.authorizationStatus
    if status == .notDetermined {
      manager.requestWhenInUseAuthorization()
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    status = manager.authorizationStatus
  }
}

