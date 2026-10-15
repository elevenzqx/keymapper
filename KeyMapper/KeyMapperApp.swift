import SwiftUI

@main
struct KeyMapperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 纯菜单栏应用，不显示 Dock 图标、无主窗口
        Settings {
            EmptyView()
        }
    }
}
