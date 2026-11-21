import Security
import XCTest

@testable import CampusLinkCore

final class VaultTests: XCTestCase {
  func testMigrationAndGroupLifecycle() throws {
    let vault = Vault(service: "CampusLink.Tests." + UUID().uuidString)
    defer { try? vault.forget() }
    XCTAssertTrue(try vault.profiles().isEmpty)
    let item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: vault.service, kSecAttrAccount as String: "campus-login",
      kSecValueData as String: Data(#"{"account":"A","password":"test-1"}"#.utf8),
    ]
    XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
    var first = try XCTUnwrap(vault.profiles().first)
    XCTAssertEqual(first.name, "A")
    XCTAssertEqual(first.password, "test-1")
    XCTAssertEqual(try vault.profiles().first?.id, first.id)
    first.name = "宿舍"
    let second = Profile(name: "实验室", account: "B", password: "test-2")
    try vault.save([first, second])
    XCTAssertEqual(try vault.profiles(), [first, second])
    try vault.save([second])
    XCTAssertEqual(try vault.profiles(), [second])
    try vault.save([])
    XCTAssertTrue(try vault.profiles().isEmpty)
  }
}
