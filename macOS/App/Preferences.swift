import CoreLocation
import ServiceManagement
import SwiftUI

private final class LocationPermission: NSObject, ObservableObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  @Published private(set) var status: CLAuthorizationStatus = .notDetermined
  @Published private(set) var requested = false
  override init() {
    super.init()
    manager.delegate = self
    refresh()
  }
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { refresh() }
  func refresh() {
    status = manager.authorizationStatus
    if status != .notDetermined { requested = false }
  }
  func request() {
    requested = true
    manager.requestWhenInUseAuthorization()
  }
  var statusText: String {
    switch status {
    case .notDetermined: return requested ? "等待系统授权。如未出现提示，可打开定位服务检查。" : "尚未授权读取 Wi-Fi 名称。"
    case .denied: return "定位未授权或系统定位服务已关闭。"
    case .restricted: return "定位权限受系统限制。"
    default: return "已授权读取 Wi-Fi 名称。"
    }
  }
}

struct Preferences: View {
  let back: () -> Void
  @StateObject private var permission = LocationPermission()
  @ObservedObject var model: ConnectionModel
  @AppStorage("silentStartup") private var silent = false
  @AppStorage("autoConnect") private var auto = false
  @AppStorage("hideAfterConnect") private var hide = false
  @State private var startup = SMAppService.mainApp.status
  @State private var editing: Profile?
  @State private var deleting: Profile?
  @State private var error = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: back) { Label("返回连接面板", systemImage: "chevron.backward") }
        .buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 8)
      Form {
        Section("账号组") {
          ForEach(model.profiles) { profile in
            HStack {
              VStack(alignment: .leading) {
                Text(profile.name)
                if profile.name != profile.account {
                  Text(profile.account).font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              Button("编辑") { editing = profile }
              Button {
                deleting = profile
              } label: {
                Image(systemName: "trash")
              }.help("删除账号组")
            }
          }
          Button {
            editing = Profile(name: "", account: "", password: "")
          } label: {
            Label("添加账号组", systemImage: "plus")
          }
        }.disabled(model.busy)
        Section("启动与运行") {
          Toggle(
            "登录 Mac 时启动",
            isOn: Binding(
              get: { startup == .enabled || startup == .requiresApproval },
              set: { enabled in
                do {
                  if enabled {
                    try SMAppService.mainApp.register()
                  } else {
                    try SMAppService.mainApp.unregister()
                  }
                } catch let failure { error = failure.localizedDescription }
                startup = SMAppService.mainApp.status
              }))
          if startup == .requiresApproval {
            Button("在系统设置中允许登录项") { SMAppService.openSystemSettingsLoginItems() }
          }
          Toggle("静默自启，仅显示菜单栏图标", isOn: $silent)
          Toggle("自启时自动连接 ksu-Wlan", isOn: $auto)
          HStack {
            Text(permission.statusText).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if permission.status == .notDetermined && !permission.requested {
              Button("请求定位权限…") { permission.request() }
            } else {
              Button("打开定位服务…") {
                let url = URL(
                  string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
                )!
                if !NSWorkspace.shared.open(url) { error = "请打开系统设置 → 隐私与安全性 → 定位服务。" }
              }
            }
          }
          Toggle("连接成功后收起窗口", isOn: $hide)
        }
        if !error.isEmpty { Text(error).foregroundStyle(.red) }
      }.formStyle(.grouped)
    }.frame(width: 460, height: 525)
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        startup = SMAppService.mainApp.status
        permission.refresh()
      }
      .sheet(item: $editing) { ProfileEditor(model: model, draft: $0) }
      .alert(item: $deleting) { profile in
        Alert(
          title: Text("删除“" + profile.name + "”？"), message: Text("当前网络连接会保留。"),
          primaryButton: .destructive(Text("删除")) {
            do { try model.persist(model.profiles.filter { $0.id != profile.id }) } catch let
              failure
            { error = failure.localizedDescription }
          },
          secondaryButton: .cancel(Text("取消")))
      }
  }
}

private struct ProfileEditor: View {
  @ObservedObject var model: ConnectionModel
  @State var draft: Profile
  @Environment(\.dismiss) var dismiss
  @State var message = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("账号组").font(.title2.bold())
      TextField("名称（可选）", text: $draft.name)
      TextField("校园网账号", text: $draft.account)
      SecureField("密码", text: $draft.password)
      Text("凭据保存在本机钥匙串。学校网关通过明文 HTTP 接收密码。").font(.caption).foregroundStyle(.secondary)
      if !message.isEmpty { Text(message).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("保存") {
          draft.account = draft.account.trimmingCharacters(in: .whitespacesAndNewlines)
          draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
          if draft.name.isEmpty { draft.name = draft.account }
          var profiles = model.profiles
          if profiles.contains(where: { $0.id != draft.id && $0.account == draft.account }) {
            message = "此账号已有账号组"
            return
          }
          if let index = profiles.firstIndex(where: { $0.id == draft.id }) {
            profiles[index] = draft
          } else {
            profiles.append(draft)
          }
          do {
            try model.persist(profiles)
            dismiss()
          } catch { message = error.localizedDescription }
        }.keyboardShortcut(.defaultAction).disabled(
          model.busy || draft.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.password.isEmpty)
      }
    }.textFieldStyle(.roundedBorder).padding(24).frame(width: 340)
  }
}
