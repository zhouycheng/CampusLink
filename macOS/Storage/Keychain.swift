import Foundation
import Security

struct LoginDetails: Codable { var account: String, password: String }

struct Profile: Codable, Identifiable, Equatable {
  var id = UUID()
  var name: String
  var account: String
  var password: String
}

struct Vault {
  var service = "CampusLink.macOS.KashiUniversity.v1"
  private var key: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "campus-login", kSecAttrSynchronizable as String: false,
    ]
  }
  struct Failure: LocalizedError {
    let code: OSStatus
    var errorDescription: String? { "钥匙串操作失败（\(code)）。" }
  }
  private func readData() throws -> Data? {
    var query = key
    query[kSecReturnData as String] = true
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else { throw Failure(code: status) }
    return data
  }
  func profiles() throws -> [Profile] {
    guard let data = try readData() else { return [] }
    if let profiles = try? JSONDecoder().decode([Profile].self, from: data) { return profiles }
    let old = try JSONDecoder().decode(LoginDetails.self, from: data)
    let profiles = [Profile(name: old.account, account: old.account, password: old.password)]
    try save(profiles)
    return profiles
  }
  func save(_ profiles: [Profile]) throws {
    let data = try JSONEncoder().encode(profiles)
    let attrs: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    var status = SecItemUpdate(key as CFDictionary, attrs as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(key.merging(attrs) { _, value in value } as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw Failure(code: status) }
  }
  func forget() throws {
    let status = SecItemDelete(key as CFDictionary)
    guard [errSecSuccess, errSecItemNotFound].contains(status) else { throw Failure(code: status) }
  }
}
