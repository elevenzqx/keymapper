import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

/// 按键映射引擎：CGEventTap 拦截全局键盘事件并按「来源设备」改写
final class MappingEngine {
    static let shared = MappingEngine()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPaused = false

    /// deviceID → 该设备启用的映射规则
    private var deviceMappings: [String: [KeyMapping]] = [:]

    private init() {}

    func start() {
        reloadRules()

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<MappingEngine>.fromOpaque(refcon).takeUnretainedValue()
            return engine.handle(event: event, type: type)
        }

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = tap else {
            print("⚠️ 无法创建事件拦截（需要辅助功能权限）")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    /// 从 DeviceManager 重新加载所有设备的规则（只保留启用项）
    func reloadRules() {
        var map: [String: [KeyMapping]] = [:]
        for device in DeviceManager.shared.knownDevices {
            let enabled = device.mappings.filter { $0.enabled }
            if !enabled.isEmpty {
                map[device.id] = enabled
            }
        }
        deviceMappings = map
    }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        guard !isPaused,
              type == .keyDown || type == .keyUp,
              !deviceMappings.isEmpty else {
            return Unmanaged.passUnretained(event)
        }

        // 关键：先判断事件来自哪把键盘，再只套用该设备的规则
        guard let deviceID = sourceDeviceID(for: event),
              let mappings = deviceMappings[deviceID] else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // 在该设备的规则里查找匹配项
        guard let mapping = mappings.first(where: { $0.sourceKeyCode == keyCode }) else {
            return Unmanaged.passUnretained(event)
        }

        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(mapping.targetKeyCode))
        return Unmanaged.passUnretained(event)
    }

    /// 判定事件来源设备：优先按时间戳精确匹配，失败则回退到「最近活跃设备」
    private func sourceDeviceID(for event: CGEvent) -> String? {
        let manager = DeviceManager.shared

        // 1) 精确匹配：IOHIDValue 时间戳与 CGEvent 时间戳同源
        if let id = manager.sourceDeviceID(forEventTimestamp: event.timestamp),
           deviceMappings[id] != nil {
            return id
        }

        // 2) 回退匹配：最近一次 HID 事件（很短的时间窗口内）
        if let id = manager.recentlyActiveDeviceID(),
           deviceMappings[id] != nil {
            return id
        }

        // 3) 兜底：系统里只有一把键盘在线时，事件必然来自它
        if let id = soleOnlineDeviceID() {
            return id
        }

        // 4) 归属失败：不做任何映射，避免把 A 设备的规则错误套用到 B 设备
        warnAttributionFailure()
        return nil
    }

    /// 只有一台键盘在线且它配置了映射时，直接归属给它
    private func soleOnlineDeviceID() -> String? {
        let online = DeviceManager.shared.knownDevices.filter { $0.isOnline }
        guard online.count == 1, let only = online.first else { return nil }
        return deviceMappings[only.id] != nil ? only.id : nil
    }

    /// 归属失败提示（限流，避免刷屏）
    private var lastAttributionWarning: TimeInterval = 0

    private func warnAttributionFailure() {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastAttributionWarning > 3 else { return }
        lastAttributionWarning = now
        print("⚠️ 无法判定按键来源设备，已跳过映射。请确认键盘的 HID 输入回调是否可用。")
    }
}
