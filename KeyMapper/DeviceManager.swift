import Foundation
import IOKit.hid
import CoreFoundation
import Darwin

/// 一条底层 HID 按键事件记录，用于把 CGEventTap 收到的按键归属到具体是哪把键盘
private struct HIDEventRecord {
    /// 来源设备的稳定指纹
    let deviceID: String
    /// IOHIDValue 携带的时间戳（mach absolute time），与 CGEvent.timestamp 同源
    let machTimestamp: UInt64
    /// 记录到达的挂钟时间，用于时间戳不同源时的回退匹配
    let arrivalTime: CFAbsoluteTime
}

/// 负责枚举、监听键盘设备（内置 / USB / 蓝牙），并识别每把键盘的稳定指纹
final class DeviceManager: ObservableObject {
    static let shared = DeviceManager()

    private var hidManager: IOHIDManager?

    /// 承载 IOHIDManager 的专用线程与 runloop。
    /// 放在后台线程可以让 HID 回调尽快执行，保证 CGEventTap 收到事件时能查到来源设备。
    private var hidThread: Thread?
    private var hidRunLoop: CFRunLoop?
    private var isStarted = false

    /// 已知的所有键盘（含离线的，用于保留映射规则）
    @Published private(set) var knownDevices: [KeyboardDevice] = []

    private let configStore = ConfigStore.shared

    // MARK: - 事件归属

    private let eventLock = NSLock()
    /// 最近的 HID 按键事件（环形缓冲），仅保留少量用于时间戳匹配
    private var recentEvents: [HIDEventRecord] = []
    private let maxRecentEvents = 256

    /// IOHIDDevice 指针 → 设备指纹，避免每次按键都重新计算指纹
    private var deviceIDCache: [UnsafeMutableRawPointer: String] = [:]

    /// UI 活动上报节流：deviceID → 上次上报时间
    private var lastUIActivity: [String: CFAbsoluteTime] = [:]
    private let uiActivityInterval: CFAbsoluteTime = 0.1

    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private init() {}

    // MARK: - 启动 / 刷新

    func startMonitoring() {
        if isStarted {
            refresh()
            return
        }
        isStarted = true

        let thread = Thread { [weak self] in
            self?.runHIDLoop()
        }
        thread.name = "KeyMapper.HID"
        thread.stackSize = 1 << 19
        hidThread = thread
        thread.start()
    }

    /// 在专用线程上创建并打开 IOHIDManager（该线程随后进入 runloop）
    private func runHIDLoop() {
        hidRunLoop = CFRunLoopGetCurrent()

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // 只关心键盘类设备
        let matching = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,   // 0x01
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard          // 0x06
        ] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)

        let ctx = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context = context else { return }
            let mgr = Unmanaged<DeviceManager>.fromOpaque(context).takeUnretainedValue()
            mgr.handleDeviceAdded(device)
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context = context else { return }
            let mgr = Unmanaged<DeviceManager>.fromOpaque(context).takeUnretainedValue()
            mgr.handleDeviceRemoved(device)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        hidManager = manager

        // 枚举已连接的设备
        if let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in set {
                handleDeviceAdded(device)
            }
        }

        CFRunLoopRun()
    }

    /// 重新枚举当前已连接的设备（供「重新检测设备」使用）
    func refresh() {
        guard let runLoop = hidRunLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self = self, let manager = self.hidManager else { return }
            if let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
                for device in set {
                    self.handleDeviceAdded(device)
                }
            }
        }
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: - 设备增删（HID 线程）

    private func handleDeviceAdded(_ device: IOHIDDevice) {
        let model = makeModel(from: device)
        deviceIDCache[Unmanaged.passUnretained(device).toOpaque()] = model.id

        // 显式打开设备，确保能收到输入事件（用于来源设备归属）
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            print("⚠️ 打开设备失败(\(openResult))，可能影响该设备的按键归属：\(model.name)")
        }
        registerInputCallback(for: device)

        DispatchQueue.main.async { [weak self] in
            self?.mergeIntoKnownDevices(model)
        }
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        let id = makeModel(from: device).id
        deviceIDCache.removeValue(forKey: Unmanaged.passUnretained(device).toOpaque())

        eventLock.lock()
        recentEvents.removeAll { $0.deviceID == id }
        eventLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let idx = self.knownDevices.firstIndex(where: { $0.id == id }) {
                // 关键：断开时只标记离线，不删除规则
                self.knownDevices[idx].isOnline = false
                self.knownDevices[idx].lastActivity = nil
            }
            AppState.shared.devices = self.knownDevices.filter { $0.isOnline }
        }
    }

    /// 在主线程合并设备信息：已有则复用其映射规则
    private func mergeIntoKnownDevices(_ model: KeyboardDevice) {
        if let idx = knownDevices.firstIndex(where: { $0.id == model.id }) {
            knownDevices[idx].isOnline = true
            // 更新可能变化的信息（如名称、蓝牙名）
            knownDevices[idx].name = model.name
            knownDevices[idx].manufacturer = model.manufacturer
            knownDevices[idx].bluetoothName = model.bluetoothName
            knownDevices[idx].connectionType = model.connectionType
        } else {
            // 新设备，尝试从配置恢复历史映射
            var newModel = model
            newModel.isOnline = true
            if let saved = configStore.mappings(forDeviceID: model.id) {
                newModel.mappings = saved
            }
            knownDevices.append(newModel)
        }

        AppState.shared.devices = knownDevices.filter { $0.isOnline }

        // 设备（及其已保存的映射）就绪后立即让引擎生效
        MappingEngine.shared.reloadRules()
    }

    // MARK: - 输入事件记录（HID 线程）

    /// 为单个设备注册输入回调：既标记「当前在用」，也记录事件时间戳用于归属
    private func registerInputCallback(for device: IOHIDDevice) {
        IOHIDDeviceRegisterInputValueCallback(device, { context, _, sender, value in
            guard let context = context, let sender = sender else { return }
            let mgr = Unmanaged<DeviceManager>.fromOpaque(context).takeUnretainedValue()
            let senderDevice = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            mgr.handleInputValue(from: senderDevice, value: value)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func handleInputValue(from device: IOHIDDevice, value: IOHIDValue) {
        let pointer = Unmanaged.passUnretained(device).toOpaque()
        let deviceID = deviceIDCache[pointer] ?? makeModel(from: device).id

        let record = HIDEventRecord(
            deviceID: deviceID,
            machTimestamp: IOHIDValueGetTimeStamp(value),
            arrivalTime: CFAbsoluteTimeGetCurrent()
        )

        eventLock.lock()
        recentEvents.append(record)
        if recentEvents.count > maxRecentEvents {
            recentEvents.removeFirst(recentEvents.count - maxRecentEvents)
        }
        eventLock.unlock()

        reportActivity(deviceID: deviceID)
    }

    /// 通知 UI 该设备正在被使用（节流，避免高频刷新）
    private func reportActivity(deviceID: String) {
        let now = CFAbsoluteTimeGetCurrent()
        eventLock.lock()
        let previous = lastUIActivity[deviceID] ?? 0
        let shouldReport = now - previous >= uiActivityInterval
        if shouldReport {
            lastUIActivity[deviceID] = now
        }
        eventLock.unlock()

        guard shouldReport else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let idx = self.knownDevices.firstIndex(where: { $0.id == deviceID }) {
                self.knownDevices[idx].lastActivity = Date()
            }
        }
    }

    // MARK: - 事件归属查询（供 MappingEngine 调用）

    /// 根据 CGEvent 时间戳精确匹配来源设备。
    /// IOHIDValue 与 CGEvent 的时间戳同源（均为 mach absolute time），容差内取最接近的一条。
    func sourceDeviceID(forEventTimestamp timestamp: UInt64,
                        tolerance: TimeInterval = 0.005) -> String? {
        let toleranceTicks = nanosToTicks(UInt64(tolerance * 1_000_000_000))

        eventLock.lock()
        defer { eventLock.unlock() }

        var bestID: String?
        var bestDiff = UInt64.max
        for record in recentEvents {
            let diff = record.machTimestamp > timestamp
                ? record.machTimestamp - timestamp
                : timestamp - record.machTimestamp
            if diff <= toleranceTicks && diff < bestDiff {
                bestDiff = diff
                bestID = record.deviceID
            }
        }
        return bestID
    }

    /// 回退策略：取最近一次 HID 事件的来源设备（限定很短的时间窗口）。
    /// 用于时间戳无法精确对齐（时钟不同源）的场景。
    func recentlyActiveDeviceID(within window: TimeInterval = 0.08) -> String? {
        eventLock.lock()
        defer { eventLock.unlock() }

        guard let last = recentEvents.last else { return nil }
        guard CFAbsoluteTimeGetCurrent() - last.arrivalTime <= window else { return nil }
        return last.deviceID
    }

    /// 纳秒 → mach ticks
    private func nanosToTicks(_ nanos: UInt64) -> UInt64 {
        guard timebase.numer != 0 else { return nanos }
        return nanos &* UInt64(timebase.denom) / UInt64(timebase.numer)
    }

    // MARK: - 设备模型

    /// 从 IOHIDDevice 构造键盘模型（含稳定指纹）
    private func makeModel(from device: IOHIDDevice) -> KeyboardDevice {
        let vendorID = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        let locationID = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int) ?? 0
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String

        let connectionType = KeyboardConnectionType.from(device: device)

        // 制造商
        let manufacturer = (IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String) ?? ""

        // 产品名
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? ""

        // 蓝牙设备名（蓝牙键盘常有独立的产品显示名）
        let btName = IOHIDDeviceGetProperty(device, "BluetoothProductName" as CFString) as? String

        // 组合展示名：优先蓝牙名，其次"制造商 产品名"，最后兜底
        var displayName: String
        if let bt = btName, !bt.isEmpty {
            displayName = bt
        } else if !manufacturer.isEmpty && !product.isEmpty {
            displayName = "\(manufacturer) \(product)"
        } else if !product.isEmpty {
            displayName = product
        } else if !manufacturer.isEmpty {
            displayName = manufacturer
        } else {
            displayName = "未知键盘"
        }

        let fingerprint = KeyboardDevice.fingerprint(
            vendorID: vendorID,
            productID: productID,
            locationID: locationID,
            serialNumber: serial
        )

        return KeyboardDevice(
            id: fingerprint,
            name: displayName,
            manufacturer: manufacturer,
            bluetoothName: btName,
            connectionType: connectionType,
            vendorID: vendorID,
            productID: productID,
            locationID: locationID
        )
    }

    /// 保存某设备的映射规则并持久化
    func saveMappings(_ mappings: [KeyMapping], forDeviceID id: String) {
        if let idx = knownDevices.firstIndex(where: { $0.id == id }) {
            knownDevices[idx].mappings = mappings
        }
        configStore.saveMappings(mappings, forDeviceID: id)
        // 规则变化后立即让引擎生效
        MappingEngine.shared.reloadRules()
    }
}
