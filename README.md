# CampusLink 校园网助手

Swift 原生 macOS 客户端：[下载 v1.0.0 DMG](https://github.com/zhouycheng/CampusLink/releases/latest/download/CampusLink-macOS-v1.0.0.dmg) · [功能与构建说明](macOS/README.md)。

面向喀什大学当前 Dr.COM 校园网的非官方 Windows 连接工具，使用 **C++20、C++/WinRT 和 WinUI 3** 开发。

[下载最新版本](https://github.com/JiangfengPang/CampusLink/releases/latest) · [使用说明](使用说明.txt) · [认证流程与凭据处理](docs/AUTHENTICATION.md) · [更新记录](CHANGELOG.md)

> 个人开发项目，与学校或校园网运营方没有官方隶属或授权关系。请使用自己的合法账号，并遵守学校网络管理规定。

## 下载和使用

支持 **Windows 10 2004 及以上 / Windows 11，x64**。安装版和便携版均附带所需的 Windows App SDK 运行文件，应用运行不依赖 .NET、PowerShell、浏览器或管理员权限。

1. 在 [Releases](https://github.com/JiangfengPang/CampusLink/releases) 下载安装版 EXE 或便携版 ZIP。
2. 安装版按向导安装；便携版先完整解压，再运行文件夹里的 `CampusLink.exe`，不要只复制 EXE。
3. 连接校园 Wi-Fi 或网线，输入账号密码并登录。选择记住账号后，凭据保存在当前 Windows 用户的凭据管理器中。

发行包目前未提供商业代码签名。开启应用程序控制的电脑可能阻止运行；本工具不会调整系统安全设置。详细限制及操作说明见 [使用说明](使用说明.txt)。

## 功能

- 一键认证，已在线时跳过重复登录。
- 识别学校已确认的常用入口和有线入口，读取当前设备信息与认证配置。
- 账号可由 Windows 保存在本机，安装版与便携版在同一用户下共用账号和偏好。
- 可选开机启动并自动连接、认证成功后关闭窗口；应用退出后无驻留服务。
- 确认后注销校园网，按学校配置处理当前设备绑定并核对离线状态。
- WinUI 原生左侧导航、宽窄窗口自适应、系统明暗主题及同步标题栏。
- 连接进度、成功和失败状态动画，遵循 Windows 动画设置。
- 只读网络诊断，可手动复制不含账号密码和设备 IP/MAC 的报告。

## 认证机制

代码主要由三个部分组成：

| 组件 | 作用 | 源码 |
| --- | --- | --- |
| 窗口 | 读取输入、触发认证、显示结果和注销确认 | [MainWindow.xaml.cpp](src/MainWindow.xaml.cpp) |
| 协议与传输 | 入口发现、设备上下文、配置、单次登录及结果确认 | [Portal.cpp](src/Portal.cpp) |
| 本机存储 | Windows 凭据管理器、偏好、自启注册及脱敏日志 | [Store.cpp](src/Store.cpp) |

请求只允许发往已核对的 `172.17.1.90` 和 `172.31.0.10` 的 80 / 801 端口。登录先查询状态；离线时读取当前设备信息和学校配置，确认支持后提交一次密码，随后在同一入口确认在线。入口切换只发生在提交密码之前的只读阶段；未知提交结果不会触发跨入口重发。

客户端没有 OAuth、JWT、API key、刷新令牌或 Cookie 登录会话。凭据由当前用户的 Windows 凭据管理器保存，不放入便携目录或偏好文件。学校现有接口采用 **HTTP GET**，URL 编码不提供传输加密；同一 Windows 用户运行的其他程序也可能访问其凭据管理器。

完整的请求顺序、参数、注销流程、内存清理及限制见 [认证架构与凭据处理](docs/AUTHENTICATION.md)。

## 构建

需要 Windows 和以下工具：

- Visual Studio 2022 / Build Tools 2022，MSVC v143 x64/x86 C++ 工具及 UWP C++ 构建支持。
- Windows SDK `10.0.26100.0`。
- PowerShell；生成安装版时还需要 Inno Setup 6.5 或更新的 6.x 版本。

NuGet 会还原固定版本的 Windows App SDK `1.8.260921001` 和 C++/WinRT `3.0.260818.1`。

```powershell
# 构建应用并运行模拟/隔离测试
./Build.ps1

# 构建、测试并生成安装版和便携版
./Build.ps1 -Package
```

应用输出在 `build/x64/Release/`，发行文件在 `release/`。同版本便携目录已存在时，打包会停止，避免误覆盖；请先另存该目录再重新打包。依赖、编译输出、个人设置与发行二进制均不进入 Git 历史。

GitHub Actions 使用 Windows Server 2022 与 Visual Studio 2022 构建应用并运行默认测试，不连接真实学校网关。

## 验证与诊断

默认测试通过注入模拟网关覆盖编码、严格 JSONP、当前设备信息、在线跳过、单次提交、结果确认、双入口准备切换、网络恢复、注销设备匹配及诊断隐私。凭据管理器和自启测试使用独立的测试目标并清理，不访问用户实际保存的账号。

```powershell
# 只查询真实网关状态，不认证、不注销
./build/tests/CampusLink.Tests.exe --live

# 准备注销路径，但在任何实际注销/解绑请求发送前拦截
./build/tests/CampusLink.Tests.exe --check-logout-route

# 纯界面演示：不读取保存凭据、不访问真实认证接口
./build/x64/Release/CampusLink.exe --demo-online --demo-dark
./build/x64/Release/CampusLink.exe --demo-offline --demo-light
```

演示模式中可按 F6 切换明暗主题；`--demo-animations` 可循环预览状态动画。网络问题可使用界面的“网络诊断 → 复制结果”，提交反馈前请检查截图和文本中没有个人信息。

**验证范围：** 常用入口的真实注销已由用户手动确认；有线环境已收到“在线状态和配置可读取”的诊断反馈。后者不能替代从离线开始的实际自动登录测试，也不表示学校所有区域与认证方式都兼容。学校配置变化时仍可能需要更新。

## 参与和许可

欢迎 [反馈问题](https://github.com/JiangfengPang/CampusLink/issues) 或提交改进。开发约束见 [CONTRIBUTING.md](CONTRIBUTING.md)，敏感问题见 [SECURITY.md](SECURITY.md)。

项目原创代码采用 [MIT License](LICENSE)。第三方翻译、Windows SDK 与再分发组件继续适用各自许可，见 [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt) 和 [安装器翻译许可](installer/ChineseSimplified.LICENSE)。使用前请阅读 [免责声明](免责声明.txt)。
