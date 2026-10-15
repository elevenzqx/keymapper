import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

/// 按键映射引擎：CGEventTap 拦截全局键盘事件并改写
final class MappingEngine {
    static let shared = MappingEngine()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPaused = false
    private var deviceMappings: [String: [KeyMapping]] = [:]

    /// 防止递归：改写后重新注入的事件不再二次处理
    private var isRewriting = false

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

    /// 从 DeviceManager 重新加载所有设备的规则
    func reloadRules() {
        var map: [String: [KeyMapping]] = [:]
        for device in DeviceManager.shared.knownDevices where !device.mappings.isEmpty {
            map[device.id] = device.mappings
        }
        deviceMappings = map
    }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if isPaused || isRewriting {
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // 寻找匹配的映射规则
        if let mapping = findMapping(for: keyCode) {
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(mapping.targetKeyCode))
        }

        return Unmanaged.passUnretained(event)
    }

    /// 在所有设备规则中查找源键匹配的映射（任意设备命中即生效）
    private func findMapping(for keyCode: UInt16) -> KeyMapping? {
        for (_, mappings) in deviceMappings {
            if let m = mappings.first(where: { $0.enabled && $0.sourceKeyCode == keyCode }) {
                return m
            }
        }
        return nil
    }
}
