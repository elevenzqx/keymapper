import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindowController: NSWindowController?
    private var settingsWindow: NSWindow?

    /// 全局状态，供菜单栏与设置界面共享
    private let appState = AppState.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标，纯菜单栏应用
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupSettingsWindow()
        startEngine()
        requestAccessibilityIfNeeded()
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "KeyMapper")
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let state = appState
        let pauseItem = NSMenuItem(
            title: state.isPaused ? "▶️ 恢复映射" : "⏸ 暂停映射",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "打开设置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 KeyMapper",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func togglePause() {
        appState.isPaused.toggle()
        rebuildMenu()
    }

    @objc private func openSettings() {
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 设置窗口

    private func setupSettingsWindow() {
        let contentView = SettingsView()
            .environmentObject(appState)
        let hosting = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hosting)
        window.title = "KeyMapper 设置"
        window.setContentSize(NSSize(width: 760, height: 520))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        window.isReleasedWhenClosed = false

        settingsWindow = window
        settingsWindowController = NSWindowController(window: window)
    }

    // MARK: - 引擎

    private func startEngine() {
        DeviceManager.shared.startMonitoring()
        MappingEngine.shared.start()
    }

    private func requestAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        if !trusted {
            // 用户尚未授权，稍后在设置界面里也提供引导入口
            print("⚠️ 需要辅助功能权限才能生效")
        }
    }
}
