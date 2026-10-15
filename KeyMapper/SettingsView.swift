import SwiftUI
import AppKit
import Combine

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var deviceManager = DeviceManager.shared

    /// 定时刷新，用于更新"使用中"状态的时效性
    private let refreshTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()
    @State private var refreshTick = 0

    var body: some View {
        VStack(spacing: 0) {
            header

            if !state.accessibilityGranted {
                permissionBanner
            }

            if deviceManager.knownDevices.isEmpty {
                emptyState
            } else {
                deviceList
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            state.accessibilityGranted = AXIsProcessTrusted()
        }
        .onReceive(refreshTimer) { _ in
            // 强制刷新"使用中"状态
            refreshTick += 1
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack {
            Text("按键映射")
                .font(.title2.bold())
            Spacer()
            Button("重新检测设备") {
                refreshDevices()
            }
        }
        .padding()
    }

    private var permissionBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("需要「辅助功能」权限才能拦截键盘事件")
            Spacer()
            Button("去授权") {
                openAccessibilitySettings()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("未检测到键盘设备")
                .font(.headline)
            Text("连接键盘后点击「重新检测设备」")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 设备列表

    private var deviceList: some View {
        List {
            ForEach(deviceManager.knownDevices) { device in
                DeviceRow(device: device)
            }
        }
        .listStyle(.inset)
    }

    private func refreshDevices() {
        // 触发设备重新枚举
        deviceManager.startMonitoring()
        state.accessibilityGranted = AXIsProcessTrusted()
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 单个设备行

struct DeviceRow: View {
    @ObservedObject var deviceManager = DeviceManager.shared
    let device: KeyboardDevice

    @State private var isExpanded = false
    @State private var newSource: UInt16 = 18 // 默认数字 1
    @State private var newTarget: UInt16 = 83 // 默认 Num 1

    private var onlineIndicator: String {
        device.isActive ? "🟢" : (device.isOnline ? "⚪️" : "⚫️")
    }

    private var statusText: String {
        if !device.isOnline { return "离线" }
        return device.isActive ? "使用中" : "已连接"
    }

    /// 按键瞬间高亮强度：距离上次按键越近越亮，约 1.2 秒内渐隐
    private var flashIntensity: Double {
        guard let last = device.lastActivity else { return 0 }
        let elapsed = Date().timeIntervalSince(last)
        guard elapsed < 1.2 else { return 0 }
        // 从 1.0 线性衰减到 0
        return max(0, 1.0 - elapsed / 1.2)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                mappingRows
                addMappingRow
                if !device.mappings.isEmpty {
                    presetButtons
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text(onlineIndicator)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(device.name)
                            .font(.headline)
                        Text(statusText)
                            .font(.caption)
                            .foregroundColor(device.isActive ? .green : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((device.isActive ? Color.green : Color.secondary).opacity(0.15))
                            .cornerRadius(4)
                    }
                    HStack(spacing: 6) {
                        Text(device.connectionType.rawValue)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if let bt = device.bluetoothName, !bt.isEmpty {
                            Text("· \(bt)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Spacer()
                Text("\(device.mappings.count) 条规则")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        // 按键瞬间高亮背景
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.22 * flashIntensity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.6 * flashIntensity), lineWidth: 1.5)
        )
    }

    // MARK: 映射行

    private var mappingRows: some View {
        ForEach(device.mappings) { mapping in
            HStack {
                Text(KeyCodeMap.name(for: mapping.sourceKeyCode))
                    .font(.system(.body, design: .monospaced))
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                Text(KeyCodeMap.name(for: mapping.targetKeyCode))
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Toggle("", isOn: binding(for: mapping))
                    .labelsHidden()
                    .toggleStyle(.switch)
                Button {
                    removeMapping(mapping)
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: 新增映射

    private var addMappingRow: some View {
        HStack {
            Picker("", selection: $newSource) {
                ForEach(KeyCodeMap.allKeys, id: \.self) { code in
                    Text(KeyCodeMap.name(for: code)).tag(code)
                }
            }
            .frame(width: 120)

            Image(systemName: "arrow.right")
                .foregroundColor(.secondary)

            Picker("", selection: $newTarget) {
                ForEach(KeyCodeMap.allKeys, id: \.self) { code in
                    Text(KeyCodeMap.name(for: code)).tag(code)
                }
            }
            .frame(width: 120)

            Spacer()

            Button("添加") {
                addMapping()
            }
            .buttonStyle(.borderedProminent)
            .disabled(newSource == newTarget)
        }
    }

    // MARK: 预设

    private var presetButtons: some View {
        HStack {
            Button("数字键 → 小键盘") {
                applyNumericPreset()
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("清空所有规则") {
                deviceManager.saveMappings([], forDeviceID: device.id)
            }
            .buttonStyle(.bordered)
            .foregroundColor(.red)
        }
    }

    // MARK: 操作

    private func addMapping() {
        var current = device.mappings
        current.append(KeyMapping(sourceKeyCode: newSource, targetKeyCode: newTarget))
        deviceManager.saveMappings(current, forDeviceID: device.id)
    }

    private func removeMapping(_ mapping: KeyMapping) {
        var current = device.mappings
        current.removeAll { $0.id == mapping.id }
        deviceManager.saveMappings(current, forDeviceID: device.id)
    }

    private func binding(for mapping: KeyMapping) -> Binding<Bool> {
        Binding(
            get: { mapping.enabled },
            set: { newValue in
                var current = device.mappings
                if let idx = current.firstIndex(where: { $0.id == mapping.id }) {
                    current[idx].enabled = newValue
                    deviceManager.saveMappings(current, forDeviceID: device.id)
                }
            }
        )
    }

    private func applyNumericPreset() {
        // 主键盘数字 → 小键盘数字
        let pairs: [(UInt16, UInt16)] = [
            (18, 83), // 1 -> Num1
            (19, 84), // 2 -> Num2
            (20, 85), // 3 -> Num3
            (21, 86), // 4 -> Num4
            (23, 87), // 5 -> Num5
            (22, 88), // 6 -> Num6
            (26, 89), // 7 -> Num7
            (28, 91), // 8 -> Num8
            (25, 92), // 9 -> Num9
            (29, 82), // 0 -> Num0
        ]
        let mappings = pairs.map { KeyMapping(sourceKeyCode: $0.0, targetKeyCode: $0.1) }
        deviceManager.saveMappings(mappings, forDeviceID: device.id)
    }
}
