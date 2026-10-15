// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KeyMapper",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "KeyMapper",
            path: "KeyMapper",
            exclude: [
                "Info.plist",
            ],
            sources: [
                "KeyMapperApp.swift",
                "AppDelegate.swift",
                "AppState.swift",
                "Models.swift",
                "DeviceManager.swift",
                "ConfigStore.swift",
                "MappingEngine.swift",
                "KeyCodeMap.swift",
                "SettingsView.swift",
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
