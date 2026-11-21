# CampusLink for macOS

面向喀什大学校园网的 SwiftUI 客户端。最低部署目标为 macOS 13，支持构建 Apple Silicon 与 Intel 通用应用。

在设置里添加账号组，然后回到连接面板选择账号。红色圆钮开始连接，绿色表示已在线；选中其他账号后，点击圆钮会先注销当前连接再登录所选账号。当前身份待识别时会先请求确认。关闭最后一个窗口后应用从 Dock 隐藏，菜单栏图标保持可用。单击图标打开连接面板，右键可打开设置或退出。窗口在前台时按 ⌘Q 退出应用。

登录 Mac 时启动、静默自启和自启时自动连接可分别设置。静默自启只显示菜单栏图标。自动认证仅在当前 IPv4 主网络为 Wi-Fi、名称精确匹配 `ksu-Wlan` 且校园网离线时执行；读取 Wi-Fi 名称可能需要在系统设置中授予定位权限。有线网络可手动认证。启动、网络变化、唤醒和运行期间会只读查询网关状态。

账号和密码保存在本机钥匙串，学校网关通过明文 HTTP GET 接收密码，请在可信的校园网络内连接。

## 构建和测试

在本目录使用 Xcode 打开 `CampusLink.xcodeproj` 并运行 CampusLink 方案，或执行以下命令。

```sh
swift test
xcodebuild -project CampusLink.xcodeproj -scheme CampusLink -configuration Release \
  -derivedDataPath build 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
open build/Build/Products/Release/CampusLink.app
```

传输层使用系统 libcurl。每次请求新建连接，限制响应正文大小，并禁止跟随重定向。

测试覆盖模拟网关、独立钥匙串条目以及本机回环 HTTP 服务。回环用例使用 Xcode 命令行工具提供的 Python 3。Release 默认使用本地 ad-hoc 签名。面向其他用户分发时需单独进行 Developer ID 签名和公证。

校内验收时分别记录 Wi-Fi 与有线环境的离线登录、已在线跳过、确认注销、重新登录及登录项自动连接结果。协议行为见[上游认证说明](../docs/AUTHENTICATION.md)。
