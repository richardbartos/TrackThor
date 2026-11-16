import Foundation
import Security

/// Minimal generic-password storage in the login keychain.
enum Keychain {
  static func string(service: String, account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Stores `value`, or removes the item when `value` is nil/empty.
  @discardableResult
  static func set(_ value: String?, service: String, account: String) -> Bool {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    SecItemDelete(base as CFDictionary)

    guard let value, !value.isEmpty else { return true }
    var attributes = base
    attributes[kSecValueData as String] = Data(value.utf8)
    return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
  }
}
