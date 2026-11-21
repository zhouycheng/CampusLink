import CoreFoundation
import Foundation

typealias Object = [String: Any]

extension Dictionary where Key == String, Value == Any {
  fileprivate func field(_ key: String) -> String {
    if let string = self[key] as? String { return string }
    if let number = self[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
      return number.stringValue
    }
    return ""
  }
  fileprivate var accepted: Bool { ["1", "ok"].contains(field("result")) }
}

struct Device {
  let ip: String, mac: String, vlan: String

  static func mac(_ value: String) -> String? {
    let clean = value.filter { $0 != ":" && $0 != "-" }
    guard clean.utf8.count == 12, clean.allSatisfy({ $0.isASCII && $0.isHexDigit }),
      !["000000000000", "111111111111"].contains(clean)
    else { return nil }
    return clean
  }
  init(page: String, status: Object) throws {
    func capture(_ pattern: String) -> String? {
      guard let re = try? NSRegularExpression(pattern: pattern),
        let match = re.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)),
        let range = Range(match.range(at: 1), in: page)
      else { return nil }
      return String(page[range])
    }
    func values(_ names: [String]) -> [String] {
      names.compactMap { capture(#"\b"# + $0 + #"\s*=\s*['"]([^'"]{0,128})['"]"#) }
        + names.map(status.field)
    }
    guard let ip = values(["v46ip", "ss5", "v4ip"]).first(where: { isValidIPv4($0) }) else {
      throw PortalError.device
    }
    self.ip = ip
    mac = values(["ss4", "olmac"]).compactMap(Self.mac).first ?? "000000000000"
    vlan = capture(#"\bvlanid\s*=\s*['"]?(\d{1,4})"#).flatMap(Int.init).map(String.init) ?? "1"
  }
}

private func isValidIPv4(_ value: String) -> Bool {
  var address = in_addr()
  return !value.utf8.contains(0) && inet_pton(AF_INET, value, &address) == 1 && address.s_addr != 0
}

enum StartupNetwork {
  static func allows(ssid: String?, primaryIsWiFi: Bool) -> Bool {
    primaryIsWiFi && ssid == "ksu-Wlan"
  }
}

struct Portal {
  let send: Transport
  var pause: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0 * 1_000_000) }
  init(send: @escaping Transport = DirectHTTP.shared.send) { self.send = send }

  static func parse(_ body: String) throws -> Object {
    let space = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))
    var text = body.trimmingCharacters(in: space)
    guard text.hasPrefix("campusLogin") else { throw PortalError.response }
    text = String(text.dropFirst(11)).trimmingCharacters(in: space)
    if text.last == ";" { text = String(text.dropLast()).trimmingCharacters(in: space) }
    guard text.first == "(", text.last == ")",
      let obj = (try? JSONSerialization.jsonObject(with: Data(text.dropFirst().dropLast().utf8)))
        as? Object
    else { throw PortalError.response }
    return obj
  }
  func api(_ g: Gateway, _ op: GatewayOperation, _ fields: Query = [:]) async throws -> Object {
    var q = fields
    q["callback"] = "campusLogin"
    q["jsVersion"] = "4.2"
    q["lang"] = "zh-cn"
    q["v"] = String(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    return try await Self.parse(send(g, op, q))
  }
  func status(_ g: Gateway) async throws -> (Bool, Object) {
    let reply = try await api(g, .status)
    guard ["0", "1"].contains(reply.field("result")) else { throw PortalError.response }
    return (reply.field("result") == "1", reply)
  }
  func discover(_ preferred: Gateway = .campus) async throws -> (Gateway, Bool, Object) {
    var last: Error = PortalError.response
    for g in [preferred, preferred == .campus ? .wired : .campus] {
      do {
        let (online, data) = try await status(g)
        return (g, online, data)
      } catch { last = error }
    }
    throw last
  }
  func prepare(_ g: Gateway, _ data: Object) async throws -> (Device, Object) {
    let device = try await Device(page: send(g, .page, [:]), status: data)
    return (device, try await configuration(g, device))
  }
  private func configuration(_ g: Gateway, _ device: Device) async throws -> Object {
    let q = [
      "program_index": "", "wlan_vlan_id": device.vlan,
      "wlan_user_ip": Data(device.ip.utf8).base64EncodedString(),
      "wlan_user_ipv6": "", "wlan_user_ssid": "", "wlan_user_areaid": "", "wlan_ac_ip": "",
      "wlan_ap_mac": "000000000000", "gw_id": "000000000000",
    ]
    let reply = try await api(g, .config, q)
    guard reply.field("code") == "1", let config = reply["data"] as? Object else {
      throw PortalError.config
    }
    return config
  }

  enum Login { case alreadyOnline, connected }
  func connect(
    account: String, password: String, preferred: Gateway = .campus, atStartup: Bool = false,
    maySubmit: () -> Bool = { true }
  ) async throws -> (Gateway, Login) {
    var initial: (Gateway, Bool, Object)
    var retries = 0
    while true {
      do {
        initial = try await discover(preferred)
        break
      } catch PortalError.network where atStartup && retries < 3 {
        retries += 1
        try await pause(2000)
      }
    }
    var (g, online, data) = initial
    if online { return (g, .alreadyOnline) }
    guard !account.isEmpty, !password.isEmpty else { throw PortalError.credentials }
    func supported(_ gateway: Gateway, _ state: Object) async throws -> (Device, Object) {
      let (d, c) = try await prepare(gateway, state)
      guard ["1", "9"].contains(c.field("login_method")) else { throw PortalError.config }
      return (d, c)
    }
    let d: Device
    let c: Object
    do { (d, c) = try await supported(g, data) } catch  where g == preferred {
      let first = error
      g = g == .campus ? .wired : .campus
      do {
        (online, data) = try await status(g)
        if online { return (g, .alreadyOnline) }
        (d, c) = try await supported(g, data)
      } catch PortalError.network { throw first }
    }
    let prefix =
      c.field("account_prefix") == "1" ? (c.field("custom_perceive") == "1" ? ",b," : ",0,") : ""
    let q = [
      "login_method": c.field("login_method"),
      "user_account": prefix + account + c.field("account_suffix"),
      "user_password": password, "wlan_user_ip": d.ip, "wlan_user_ipv6": "", "wlan_user_mac": d.mac,
      "wlan_ac_ip": "", "wlan_ac_name": "", "terminal_type": "1",
    ]
    guard maySubmit() else { throw PortalError.startupNetwork }
    let reply = try await mutation(g, .login, q)
    guard reply.accepted else { throw PortalError.rejected }
    for attempt in 0..<3 {
      guard let state = try? await status(g) else { throw PortalError.uncertain }
      if state.0 { return (g, .connected) }
      if attempt < 2 { try await pause(650) }
    }
    throw PortalError.uncertain
  }
  private func mutation(_ g: Gateway, _ op: GatewayOperation, _ q: Query) async throws -> Object {
    guard let reply = try? await api(g, op, q), ["ok", "1", "0"].contains(reply.field("result"))
    else {
      throw PortalError.uncertain
    }
    return reply
  }

  func disconnect(preferred: Gateway, expectedUID: String? = nil) async throws -> Gateway {
    let g = preferred
    let (online, state) = try await status(g)
    if online, let expectedUID, state.field("uid") != expectedUID {
      throw PortalError.sessionChanged
    }
    guard online else { return g }
    let (d, c) = try await prepare(g, state)
    let method = c.field("login_method")
    let ac = c.field("ac_logout").isEmpty ? "0" : c.field("ac_logout")
    let mode = c.field("register_mode").isEmpty ? "0" : c.field("register_mode")
    guard ["0", "1", "2"].contains(ac), ["", "0", "1"].contains(c.field("un_bind_mac")) else {
      throw PortalError.config
    }
    var unbound = false
    if c.field("un_bind_mac") == "1", ["1", "3", "4"].contains(mode) {
      let account = state.field("uid").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !account.isEmpty else { throw PortalError.device }
      var mac = Device.mac(d.mac)
      if mac == nil {
        let lookup = try await api(
          g, .find,
          [
            "user_account": account, "login_method": method,
            "find_mac": c.field("find_mac").isEmpty ? "0" : c.field("find_mac"),
            "wlan_user_ip": d.ip, "wlan_user_mac": d.mac,
          ])
        guard lookup.accepted, let list = lookup["list"] as? [Any] else { throw PortalError.device }
        let matches = Set(
          list.compactMap { $0 as? Object }.filter { $0.field("online_ip") == d.ip }
            .compactMap { Device.mac($0.field("online_mac"))?.uppercased() })
        guard matches.count == 1 else { throw PortalError.device }
        mac = matches.first
      }
      guard let mac else { throw PortalError.device }
      let decimal = d.ip.split(separator: ".").compactMap { UInt32($0) }.reduce(UInt32(0)) {
        ($0 << 8) | $1
      }
      unbound = try await mutation(
        g, .unbind,
        [
          "user_account": account, "wlan_user_mac": mac.uppercased(),
          "wlan_user_ip": String(decimal),
        ]
      ).accepted
    }
    if !unbound {
      let reply: Object
      if method == "0", ac == "0" {
        reply = try await mutation(g, .legacy, [:])
      } else if ["1", "9"].contains(method) {
        reply = try await mutation(
          g, .logout,
          [
            "login_method": method, "user_account": "drcom", "user_password": "123",
            "ac_logout": ac, "register_mode": mode, "wlan_user_ip": d.ip, "wlan_user_ipv6": "",
            "wlan_vlan_id": d.vlan,
            "wlan_user_mac": d.mac, "wlan_ac_ip": "", "wlan_ac_name": "",
          ])
      } else {
        throw PortalError.config
      }
      guard reply.accepted else { throw PortalError.rejected }
    }
    var previousOffline = false
    for attempt in 0..<12 {
      guard let state = try? await status(g) else { throw PortalError.uncertain }
      if !state.0 && previousOffline { return g }
      previousOffline = !state.0
      if attempt < 11 { try await pause(750) }
    }
    throw PortalError.uncertain
  }

  func diagnose() async -> String {
    var lines = [String]()
    for g in Gateway.allCases {
      var stage = "状态查询"
      do {
        let (online, data) = try await status(g)
        lines.append("\(g.title) · \(online ? "在线" : "待认证")")
        stage = "设备页面"
        let device = try await Device(page: send(g, .page, [:]), status: data)
        stage = "认证配置"
        let c = try await configuration(g, device)
        lines.append(["1", "9"].contains(c.field("login_method")) ? "认证配置受支持" : "认证方式暂不支持")
      } catch {
        lines.append("\(g.title) · \(stage)：\((error as? PortalError)?.errorDescription ?? "读取失败")")
      }
    }
    return lines.joined(separator: "\n")
  }
}
