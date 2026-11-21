import AppKit
import Carbon
import Combine
import SwiftUI

@main @MainActor final class CampusLinkApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
  static func main() {
    let app = NSApplication.shared
    let delegate = CampusLinkApp()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }

  private let model = ConnectionModel()
  private var panel: NSWindow?, preferences: NSWindow?, item: NSStatusItem!
  private var subscription: AnyCancellable?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let event = NSAppleEventManager.shared().currentAppleEvent
    let login =
      event?.eventID == kAEOpenApplication
      && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        == keyAELaunchedAsLogInItem
    let silent = login && UserDefaults.standard.bool(forKey: "silentStartup")
    NSApp.setActivationPolicy(silent ? .accessory : .regular)
    let main = NSMenu()
    let app = NSMenu()
    let edit = NSMenu()
    main.addItem(withTitle: "CampusLink", action: nil, keyEquivalent: "").submenu = app
    app.addItem(withTitle: "设置…", action: #selector(settings), keyEquivalent: ",").target = self
    app.addItem(
      withTitle: "退出 CampusLink", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
    )
    main.addItem(withTitle: "编辑", action: nil, keyEquivalent: "").submenu = edit
    for (title, action, key) in [
      ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a"),
    ] {
      edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
    }
    NSApp.mainMenu = main
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.target = self
    item.button?.action = #selector(statusItemClicked(_:))
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    subscription = model.objectWillChange.sink { [weak self] in
      DispatchQueue.main.async { self?.updateIcon() }
    }
    updateIcon()
    model.hidePanel = { [weak self] in
      self?.panel?.orderOut(nil)
      self?.updateDockAfterClosing()
    }
    model.start(atLogin: login)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
    if !silent { showPanel() }
  }
  @objc private func woke() { model.refresh() }
  private func updateIcon() {
    let icon: String
    switch model.state {
    case .online: icon = "checkmark.circle.fill"
    case .offline: icon = "power.circle"
    case .unknown: icon = "questionmark.circle"
    }
    item.button?.image = NSImage(
      systemSymbolName: model.busy ? "ellipsis.circle" : icon,
      accessibilityDescription: model.status)?.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    item.button?.toolTip = model.status
  }
  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    guard
      NSApp.currentEvent?.type == .rightMouseUp
        || NSApp.currentEvent?.modifierFlags.contains(.control) == true
    else {
      showPanel()
      return
    }
    let menu = NSMenu()
    menu.addItem(withTitle: model.status, action: nil, keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "打开连接面板", action: #selector(showPanel), keyEquivalent: "").target = self
    menu.addItem(withTitle: "设置…", action: #selector(settings), keyEquivalent: ",").target = self
    menu.addItem(
      withTitle: "退出 CampusLink", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
    )
    menu.popUp(
      positioning: nil,
      at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY : sender.bounds.minY), in: sender)
  }
  private func updateDockAfterClosing(excluding closing: NSWindow? = nil) {
    if ![panel, preferences].compactMap({ $0 }).contains(where: {
      $0 !== closing && ($0.isVisible || $0.isMiniaturized)
    }) {
      NSApp.setActivationPolicy(.accessory)
    }
  }
  func windowWillClose(_ notification: Notification) {
    updateDockAfterClosing(excluding: notification.object as? NSWindow)
  }
  private func window<V: View>(_ title: String, view: V) -> NSWindow {
    let window = NSWindow(contentViewController: NSHostingController(rootView: view))
    window.delegate = self
    window.title = title
    window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.center()
    return window
  }
  private func show(_ window: NSWindow?) {
    if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    if window?.isMiniaturized == true { window?.deminiaturize(nil) }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }
  @objc func showPanel() {
    if panel == nil { panel = window("CampusLink", view: Panel(model: model, settings: settings)) }
    show(panel)
    model.refresh()
  }
  @objc func settings() {
    if !model.busy { model.loadProfiles() }
    if preferences == nil {
      preferences = window(
        "设置",
        view: Preferences(
          back: { [weak self] in
            self?.showPanel()
            self?.preferences?.close()
          }, model: model))
    }
    show(preferences)
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    showPanel()
    return false
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct Panel: View {
  @ObservedObject var model: ConnectionModel
  var settings: () -> Void
  @State private var confirmation: Confirmation?
  struct Confirmation: Identifiable {
    let id = UUID()
    let state: ConnectionModel.State
    let gateway: Gateway
    let target: Profile?
  }

  var online: Bool {
    if case .online = model.state { return true }
    return false
  }
  var switching: Bool {
    online && model.profile != nil
      && (model.active == nil || model.profile?.account != model.active?.account)
  }
  var tint: Color {
    if model.busy || model.state == .unknown { return .secondary }
    return online
      ? Color(red: 0.10, green: 0.56, blue: 0.36) : Color(red: 0.82, green: 0.23, blue: 0.24)
  }
  var label: String {
    if model.busy { return "请稍候" }
    if model.state == .unknown { return model.checking ? "检测中" : "重新检测" }
    if online { return switching ? "切换连接" : "已连接" }
    return model.profile == nil ? "添加账号" : "开始连接"
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("喀什大学校园网").font(.system(size: 13, weight: .medium))
        Spacer()
        Button(action: settings) { Image(systemName: "gearshape") }.buttonStyle(.borderless).help(
          "设置")
      }.foregroundStyle(.secondary)
      Spacer()
      Button {
        if model.state == .unknown {
          model.refresh()
        } else if online {
          if switching && model.active != nil {
            model.disconnect(switchTo: model.profile)
          } else {
            confirmation = Confirmation(
              state: model.state, gateway: model.gateway, target: switching ? model.profile : nil)
          }
        } else if let p = model.profile {
          model.login(p)
        } else {
          settings()
        }
      } label: {
        ZStack {
          Circle().stroke(tint.opacity(0.18), lineWidth: 1).frame(width: 176, height: 176)
          Circle().fill(tint.gradient).frame(width: 156, height: 156).shadow(
            color: tint.opacity(0.20), radius: 10, y: 4)
          VStack(spacing: 8) {
            Image(
              systemName: model.busy
                ? "ellipsis"
                : online
                  ? (switching ? "arrow.triangle.2.circlepath" : "checkmark")
                  : model.state == .unknown ? "arrow.clockwise" : "power"
            )
            .font(.system(size: 34, weight: .medium))
            Text(label).font(.system(size: 16, weight: .semibold))
          }.foregroundStyle(.white)
        }
      }.buttonStyle(.plain).disabled(model.busy || (model.state == .unknown && model.checking))
        .accessibilityLabel(label)
      Text(model.status).font(.headline).padding(.top, 18)
      if !model.note.isEmpty {
        Text(model.note).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
          .padding(.top, 5)
      }
      Spacer()
      Divider()
      HStack {
        Text("账号组").foregroundStyle(.secondary)
        Spacer()
        if model.profiles.isEmpty {
          Button("添加账号组…", action: settings).buttonStyle(.borderless)
        } else {
          Picker("账号组", selection: $model.selected) {
            ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
          }.labelsHidden().frame(maxWidth: 210, alignment: .trailing)
        }
      }.disabled(model.busy).padding(.top, 16)
    }.padding(24).frame(width: 364, height: 398)
      .alert(item: $confirmation) { kind in
        Alert(
          title: Text(kind.target == nil ? "断开当前校园网连接？" : "注销当前会话并切换账号？"),
          message: Text(kind.target == nil ? "注销可能同时解除当前设备绑定。" : "当前在线账号待识别。确认后会先注销，再连接所选账号。"),
          primaryButton: .destructive(Text(kind.target == nil ? "断开" : "切换")) {
            guard kind.state == model.state, kind.gateway == model.gateway,
              kind.target == nil || kind.target == model.profile
            else {
              model.note = "当前会话或所选账号已变化，请重新确认。"
              return
            }
            model.disconnect(switchTo: kind.target)
          },
          secondaryButton: .cancel(Text("取消")))
      }
  }
}
