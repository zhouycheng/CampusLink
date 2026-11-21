import CoreWLAN
import Network
import SwiftUI
import SystemConfiguration

@MainActor final class ConnectionModel: ObservableObject {
  enum State: Equatable {
    case unknown, offline
    case online(String)
  }
  @Published var state = State.unknown
  @Published var progress = ""
  @Published var note = ""
  @Published var profiles: [Profile] = []
  @Published var selected: UUID? {
    didSet { defaults.set(selected?.uuidString, forKey: "selectedProfile") }
  }
  var profile: Profile? { profiles.first { $0.id == selected } }
  var active: Profile? {
    guard case .online(let uid) = state, !uid.isEmpty else { return nil }
    return profiles.first { $0.account == uid }
  }
  var status: String {
    if !progress.isEmpty { return progress }
    switch state {
    case .online: return "当前在线 · " + (active?.name ?? "账号待识别")
    case .offline: return "校园网未连接"
    case .unknown: return checking ? "正在检测校园网状态" : "无法确认校园网状态"
    }
  }
  private let portal: Portal
  private let vault: Vault
  private let defaults: UserDefaults
  private let onCampus: () -> Bool
  private let monitor = NWPathMonitor()

  init(
    portal: Portal = Portal(), vault: Vault = Vault(), defaults: UserDefaults = .standard,
    onCampus: @escaping () -> Bool = ConnectionModel.onCampusWiFi
  ) {
    self.portal = portal
    self.vault = vault
    self.defaults = defaults
    self.onCampus = onCampus
  }

  private(set) var gateway = Gateway.campus
  private var polling: Timer?
  @Published private(set) var checking = false
  private var needsRefresh = false
  private var generation = 0
  private var readable = false
  var hidePanel: () -> Void = {}
  var busy: Bool { !progress.isEmpty }

  func start(atLogin: Bool) {
    loadProfiles()
    if defaults.object(forKey: "hideAfterConnect") == nil {
      defaults.set(defaults.bool(forKey: "quitAfterConnect"), forKey: "hideAfterConnect")
    }
    let auto = atLogin && defaults.bool(forKey: "autoConnect") && self.onCampus()
    if auto, let profile { login(profile, auto: true) } else { refresh() }
    monitor.pathUpdateHandler = { [weak self] _ in Task { @MainActor in self?.refresh() } }
    monitor.start(queue: DispatchQueue(label: "CampusLink.network"))
    polling = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }
  nonisolated static func onCampusWiFi() -> Bool {
    guard let store = SCDynamicStoreCreate(nil, "CampusLink" as CFString, nil, nil),
      let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
        as? [String: Any],
      let name = global["PrimaryInterface"] as? String,
      CWWiFiClient.shared().interfaceNames()?.contains(name) == true
    else { return false }
    return StartupNetwork.allows(
      ssid: CWWiFiClient.shared().interface(withName: name)?.ssid(), primaryIsWiFi: true)
  }
  func loadProfiles() {
    do {
      profiles = try vault.profiles()
      readable = true
      let saved = defaults.string(forKey: "selectedProfile").flatMap(
        UUID.init(uuidString:))
      selected = profiles.first { $0.id == saved }?.id ?? profiles.first?.id
    } catch {
      readable = false
      note = "无法读取钥匙串，请解锁后重新打开设置。"
    }
  }
  func persist(_ list: [Profile]) throws {
    guard readable else { throw Vault.Failure(code: errSecInteractionNotAllowed) }
    try vault.save(list)
    profiles = list
    if !list.contains(where: { $0.id == selected }) { selected = list.first?.id }
  }
  private func inspect() async throws -> (Gateway, State) {
    let (g, online, data) = try await portal.discover(gateway)
    return (g, online ? .online(data["uid"] as? String ?? "") : .offline)
  }
  func refresh() {
    if busy || checking {
      needsRefresh = true
      return
    }
    checking = true
    let epoch = generation
    Task {
      let result = try? await inspect()
      if epoch == generation { apply(result) }
      checking = false
      if needsRefresh && !busy {
        needsRefresh = false
        refresh()
      }
    }
  }
  private func apply(_ result: (Gateway, State)?) {
    if let (g, s) = result {
      gateway = g
      state = s
    } else {
      state = .unknown
    }
  }
  func login(_ profile: Profile, auto: Bool = false) {
    run("正在连接" + profile.name) {
      let (g, _) = try await self.portal.connect(
        account: profile.account, password: profile.password, preferred: self.gateway,
        atStartup: auto, maySubmit: { !auto || self.onCampus() })
      self.gateway = g
      self.finishLogin = profile.account
    }
  }
  func disconnect(switchTo target: Profile? = nil) {
    guard case .online(let uid) = state else {
      refresh()
      return
    }
    run("正在注销当前账号") {
      self.gateway = try await self.portal.disconnect(preferred: self.gateway, expectedUID: uid)
      guard let target else { return }
      self.progress = "正在连接" + target.name
      let (g, _) = try await self.portal.connect(
        account: target.account, password: target.password, preferred: self.gateway)
      self.gateway = g
      self.finishLogin = target.account
    }
  }
  private var finishLogin: String?
  private func run(_ title: String, _ action: @escaping () async throws -> Void) {
    guard !busy else { return }
    generation += 1
    finishLogin = nil
    progress = title
    note = ""
    Task {
      do { try await action() } catch { note = error.localizedDescription }
      apply(try? await inspect())
      progress = ""
      if let intended = finishLogin {
        if case .online(let uid) = state, uid == intended {
          if defaults.bool(forKey: "hideAfterConnect") { hidePanel() }
        } else {
          note = "尚未确认所选账号的在线状态。"
        }
      }
      if needsRefresh {
        needsRefresh = false
        refresh()
      }
    }
  }
}
