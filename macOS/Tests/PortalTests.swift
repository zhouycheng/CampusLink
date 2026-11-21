import XCTest

@testable import CampusLinkCore

final class PortalTests: XCTestCase {
  let page = "v46ip='192.0.2.3';vlanid=2;"
  let offline = #"campusLogin({"result":0})"#
  let online = #"campusLogin({"result":1,"uid":"fixture"})"#
  let config =
    #"campusLogin({"code":1,"data":{"login_method":1,"account_prefix":1,"custom_perceive":1,"account_suffix":"@test"}})"#
  let binding =
    #"campusLogin({"code":1,"data":{"login_method":1,"un_bind_mac":1,"register_mode":3}})"#
  let ok = #"campusLogin({"result":"ok"})"#

  func testParsingAndEncoding() throws {
    for bad in ["other({})", "campusLogin({});run()", "campusLogin([1])", "campusLogin(true)"] {
      XCTAssertThrowsError(try Portal.parse(bad))
    }
    XCTAssertNotNil(try Portal.parse(" campusLogin ({}); "))
    let request = try DirectHTTP.request(.wired, .login, ["x": "中 +&?%="])
    XCTAssertEqual(
      request.url?.absoluteString,
      "http://172.31.0.10:801/eportal/portal/login?x=%E4%B8%AD%20%2B%26%3F%25%3D")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "http://172.31.0.10/a79.htm")
  }

  func testAlreadyOnline() async throws {
    var ops = [GatewayOperation]()
    let p = Portal { _, op, _ in
      ops.append(op)
      return self.online
    }
    let (_, result) = try await p.connect(account: "", password: "")
    XCTAssertEqual(result, .alreadyOnline)
    XCTAssertEqual(ops, [.status])
  }

  func testFallbackBeforeLoginOnly() async throws {
    var sent = false
    var calls = [GatewayOperation]()
    let p = Portal { g, op, q in
      calls.append(op)
      if g == .campus && op == .page { throw PortalError.network(-1) }
      switch op {
      case .status: return sent ? self.online : self.offline
      case .page: return self.page
      case .config: return self.config
      case .login:
        XCTAssertEqual(g, .wired)
        XCTAssertEqual(q["user_account"], ",b,test@test")
        XCTAssertEqual(q["user_password"], "test")
        sent = true
        return self.ok
      default: throw PortalError.response
      }
    }
    let (g, result) = try await p.connect(account: "test", password: "test")
    XCTAssertEqual(g, .wired)
    XCTAssertEqual(result, .connected)
    XCTAssertEqual(calls, [.status, .page, .status, .page, .config, .login, .status])
  }

  func testSubmittedLoginNeverChangesGateway() async {
    for mode in ["dropped", "rejected", "confirmation"] {
      var count = 0
      let p = Portal { g, op, _ in
        XCTAssertEqual(g, .campus)
        switch op {
        case .page: return self.page
        case .config: return self.config
        case .status:
          if count > 0 { throw PortalError.network(-1) }
          return self.offline
        case .login:
          count += 1
          if mode == "dropped" { throw PortalError.network(-1) }
          return mode == "rejected" ? self.offline : self.ok
        default: throw PortalError.response
        }
      }
      do {
        _ = try await p.connect(account: "test", password: "test")
        XCTFail()
      } catch { XCTAssertEqual(error as? PortalError, mode == "rejected" ? .rejected : .uncertain) }
      XCTAssertEqual(count, 1)
    }
  }

  func testUnbindRequiresUniqueCurrentDevice() async {
    let p = Portal { _, op, _ in
      switch op {
      case .status: return self.online
      case .page: return self.page
      case .config: return self.binding
      case .find:
        return
          #"campusLogin({"result":1,"list":[{"online_ip":"192.0.2.3","online_mac":"AABBCCDDEE01"},{"online_ip":"192.0.2.3","online_mac":"AABBCCDDEE02"}]})"#
      default:
        XCTFail("Unexpected mutation")
        throw PortalError.response
      }
    }
    do {
      _ = try await p.disconnect(preferred: .campus)
      XCTFail()
    } catch { XCTAssertEqual(error as? PortalError, .device) }
  }

  func testUnbindConfirmationAndExplicitRefusal() async throws {
    for mode in ["accepted", "rejected", "unknown"] {
      var states = [online, offline, online, offline, offline]
      var changes = [GatewayOperation]()
      var p = Portal { _, op, q in
        switch op {
        case .status: return states.removeFirst()
        case .page: return self.page + "ss4='aa:bb:cc:dd:ee:ff'"
        case .config: return self.binding
        case .unbind:
          changes.append(op)
          XCTAssertEqual(q["wlan_user_mac"], "AABBCCDDEEFF")
          XCTAssertEqual(q["wlan_user_ip"], "3221225987")
          if mode == "unknown" { throw PortalError.network(-1) }
          return mode == "rejected" ? self.offline : self.ok
        case .logout:
          changes.append(op)
          return self.ok
        default: throw PortalError.response
        }
      }
      p.pause = { _ in }
      do {
        _ = try await p.disconnect(preferred: .campus)
        XCTAssertNotEqual(mode, "unknown")
        XCTAssertTrue(states.isEmpty)
      } catch {
        XCTAssertEqual(mode, "unknown")
        XCTAssertEqual(error as? PortalError, .uncertain)
      }
      XCTAssertEqual(changes, mode == "rejected" ? [.unbind, .logout] : [.unbind])
    }
  }

  func testDiagnosticsAreReadOnly() async {
    let p = Portal { _, op, _ in
      switch op {
      case .status: return self.online
      case .page: return self.page
      case .config: return self.config
      default:
        XCTFail("Unexpected mutation")
        throw PortalError.response
      }
    }
    let report = await p.diagnose()
    XCTAssertFalse(report.contains("fixture"))
    XCTAssertFalse(report.contains("192.0.2.3"))
    XCTAssertTrue(report.contains("有线入口"))
  }

  func testStartupWaitsOnlyForReadOnlyNetworkRecovery() async throws {
    var probes = 0
    var waits = [UInt64]()
    var portal = Portal { _, op, _ in
      XCTAssertEqual(op, .status)
      probes += 1
      if probes < 5 { throw PortalError.network(-1) }
      return self.online
    }
    portal.pause = { waits.append($0) }
    let (_, result) = try await portal.connect(account: "", password: "", atStartup: true)
    XCTAssertEqual(result, .alreadyOnline)
    XCTAssertEqual(waits, [2000, 2000])
    XCTAssertEqual(probes, 5)
  }

  func testAutoLoginNeedsExactCampusSSIDAndWiFiRoute() {
    for ssid in [nil, "", "ksu-wlan", "KSU-Wlan", "ksu-Wlan ", "Guest"] as [String?] {
      XCTAssertFalse(StartupNetwork.allows(ssid: ssid, primaryIsWiFi: true))
    }
    XCTAssertFalse(StartupNetwork.allows(ssid: "ksu-Wlan", primaryIsWiFi: false))
    XCTAssertTrue(StartupNetwork.allows(ssid: "ksu-Wlan", primaryIsWiFi: true))
  }

  func testWiFiChangeDuringPreparationSkipsPassword() async {
    var operations = [GatewayOperation]()
    let portal = Portal { _, op, _ in
      operations.append(op)
      switch op {
      case .status: return self.offline
      case .page: return self.page
      case .config: return self.config
      default:
        XCTFail("Unexpected mutation")
        throw PortalError.response
      }
    }
    do {
      _ = try await portal.connect(
        account: "fixture", password: "test", atStartup: true, maySubmit: { false })
      XCTFail()
    } catch { XCTAssertEqual(error as? PortalError, .startupNetwork) }
    XCTAssertEqual(operations, [.status, .page, .config])
  }

  func testChangedSessionStopsLogoutBeforeMutation() async {
    let portal = Portal { _, op, _ in
      XCTAssertEqual(op, .status)
      return self.online
    }
    do {
      _ = try await portal.disconnect(preferred: .campus, expectedUID: "another")
      XCTFail()
    } catch { XCTAssertEqual(error as? PortalError, .sessionChanged) }
  }

  func testWireDoesNotReplayOrFollowRedirect() async throws {
    let server = Process()
    let output = Pipe()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = [
      "-u", "-c",
      #"""
      from http.server import BaseHTTPRequestHandler, HTTPServer
      counts = {}
      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *args): pass
          def do_GET(self):
              counts[self.path] = counts.get(self.path, 0) + 1
              if self.path == '/drop':
                  self.close_connection = True
                  return
              if self.path == '/redirect':
                  self.send_response(302)
                  self.send_header('Location', '/unexpected')
                  self.end_headers()
                  return
              self.send_response(200)
              self.end_headers()
              self.wfile.write(str([counts.get(k, 0) for k in ['/drop','/redirect','/unexpected']]).encode())
      server = HTTPServer(('127.0.0.1', 0), Handler)
      print(server.server_port)
      server.serve_forever()
      """#,
    ]
    server.standardOutput = output
    try server.run()
    defer {
      server.terminate()
      server.waitUntilExit()
    }
    let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let base = try XCTUnwrap(URL(string: "http://127.0.0.1:" + port))
    func fetch(_ path: String) async throws -> String {
      try await DirectHTTP.shared.fetch(URLRequest(url: base.appendingPathComponent(path)))
    }
    do {
      _ = try await fetch("drop")
      XCTFail()
    } catch { XCTAssertTrue(error is PortalError) }
    do {
      _ = try await fetch("redirect")
      XCTFail()
    } catch { XCTAssertEqual(error as? PortalError, .http(302)) }
    let count = try await fetch("counts")
    XCTAssertEqual(count, "[1, 1, 0]")
  }
}
