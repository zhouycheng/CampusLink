// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "CampusLinkCore", platforms: [.macOS(.v13)], targets: [
    .target(name: "CampusHTTP", path: "HTTP", linkerSettings: [.linkedLibrary("curl")]),
    .target(name: "CampusLinkCore", dependencies: ["CampusHTTP"], path: ".",
            exclude: ["App/CampusLinkApp.swift", "App/Preferences.swift", "HTTP", "Tests", "AppInfo.plist", "CampusLink.entitlements",
                      "CampusLink.icns", "CampusLink.xcodeproj", "README.md"],
            sources: ["Core", "Storage", "App/ConnectionModel.swift"]),
    .testTarget(name: "CampusLinkCoreTests", dependencies: ["CampusLinkCore"], path: "Tests")
])
