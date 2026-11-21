import XCTest

@testable import CampusLinkCore

@MainActor final class ConnectionModelTests: XCTestCase {
  let a = Profile(name: "A", account: "a", password: "dummy-a")
  let b = Profile(name: "B", account: "b", password: "dummy-b")

  func waitUntil(_ condition: @escaping () -> Bool) async throws {
    for _ in 0..<400 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Operation failed to settle")
  }

  func testSwitchAndFailureBoundaries() async throws {
    for mode in ["success", "uncertain", "refused"] {
      var uid = "a"
      var mutations = [GatewayOperation]()
      var portal = Portal { _, op, q in
        switch op {
        case .status: return "campusLogin({\"result\":\(uid.isEmpty ? 0 : 1),\"uid\":\"\(uid)\"})"
        case .page: return "v46ip='192.0.2.1';"
        case .config: return #"campusLogin({"code":1,"data":{"login_method":1}})"#
        case .logout:
          mutations.append(op)
          if mode == "uncertain" { throw PortalError.network(1) }
          uid = ""
          return #"campusLogin({"result":1})"#
        case .login:
          mutations.append(op)
          XCTAssertEqual(q["user_account"], "b")
          if mode == "refused" { return #"campusLogin({"result":0})"# }
          uid = "b"
          return #"campusLogin({"result":1})"#
        default: throw PortalError.response
        }
      }
      portal.pause = { _ in }
      let suite = "CampusLink.Tests." + UUID().uuidString
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let model = ConnectionModel(portal: portal, defaults: defaults)
      model.profiles = [a, b]
      model.refresh()
      try await waitUntil { !model.checking }
      model.selected = b.id
      XCTAssertTrue(mutations.isEmpty)
      model.disconnect(switchTo: b)
      model.disconnect(switchTo: b)
      try await waitUntil { !model.busy }
      XCTAssertEqual(mutations, mode == "uncertain" ? [.logout] : [.logout, .login])
      XCTAssertEqual(
        model.state, mode == "success" ? .online("b") : mode == "refused" ? .offline : .online("a"))
    }
  }

  func testStartupOnOtherNetworkOnlyChecksStatus() async throws {
    let suite = "CampusLink.Tests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let vault = Vault(service: suite)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? vault.forget()
    }
    defaults.set(true, forKey: "autoConnect")
    try vault.save([a, b])
    defaults.set(b.id.uuidString, forKey: "selectedProfile")
    let portal = Portal { _, op, _ in
      XCTAssertEqual(op, .status)
      return #"campusLogin({"result":0})"#
    }
    let model = ConnectionModel(
      portal: portal, vault: vault, defaults: defaults, onCampus: { false })
    model.start(atLogin: true)
    try await waitUntil { model.state == .offline && !model.checking }
    XCTAssertEqual(model.selected, b.id)
    XCTAssertFalse(model.busy)
  }

  func testOldProbeCannotOverwriteNewSession() async throws {
    var pending: CheckedContinuation<String, Never>?
    var calls = 0
    let portal = Portal { _, op, _ in
      XCTAssertEqual(op, .status)
      calls += 1
      if calls == 1 { return await withCheckedContinuation { pending = $0 } }
      return #"campusLogin({"result":1,"uid":"b"})"#
    }
    let model = ConnectionModel(portal: portal)
    model.refresh()
    try await waitUntil { pending != nil }
    model.login(b)
    try await waitUntil { !model.busy }
    pending?.resume(returning: #"campusLogin({"result":0})"#)
    try await waitUntil { !model.checking }
    XCTAssertEqual(model.state, .online("b"))
  }
}
