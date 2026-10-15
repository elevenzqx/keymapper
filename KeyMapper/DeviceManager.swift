import Foundation
import IOKit.hid

/// 负责枚举、监听键盘设备（内置 / USB / 蓝牙），并识别每把键盘的稳定指纹
final class DeviceManager: ObservableObject {
    static let shared = DeviceManager()

    private var hidManager: IOHIDManager?

    /// 已知的所有键盘（含离线的，用于保留映射规则）
    @Published private(set) var knownDevices: [KeyboardDevice] = []

    private let configStore = ConfigStore.shared

    private init() {}

    func startMonitoring() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // 只关心键盘类设备
        let usagePageKey = kIOHIDDeviceUsagePageKey
        let usageKey = kIOHIDDeviceUsageKey
        let matching = [
            usagePageKey: kHIDPage_GenericDesktop,   // 0x01
            usageKey: kHIDUsage_GD_Keyboard          // 0x06
        ] as CFDictionary

        IOHIDManagerSetDeviceMatching(manager, matching)

        // 注册匹配/移除回调
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, sender, device in
            guard let context = context else { return }
            let mgr = Unmanaged<DeviceManager>.fromOpaque(context).takeUnretainedValue()
            mgr.deviceAdded(device)
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, result, sender, device in
            guard let context = context else { return }
            let mgr = Unmanaged<DeviceManager>.fromOpaque(context).takeUnretainedValue()
            mgr.deviceRemoved(device)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        hidManager = manager

        // 枚举已连接的设备
        if let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in set {
                deviceAdded(device)
            }
        }
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        var model = makeModel(from: device)
        model.isOnline = true

        // 为该设备注册输入回调，用于标记"当前在用"
        registerInputCallback(for: device)

        // 合并进已知设备：已有则复用其映射规则
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
            if let saved = configStore.mappings(forDeviceID: model.id) {
                newModel.mappings = saved
            }
            knownDevices.append(newModel)
        }

        // 更新应用状态里的在线设备列表
        AppState.shared.devices = knownDevices.filter { $0.isOnline }
    }

    /// 为单个设备注册输入回调，收到按键即标记其为"当前在用"
    private func registerInputCallback(for device: IOHIDDevice) {
        IOHIDDeviceRegisterInputValueCallback(device, { context, result, sender, value in
            guard let context = context else { return }
            let mgr = Unmanaged<DeviceManager>.fromOpaque(context).takeUnretainedValue()
            // sender 即触发事件的设备
            if let senderDevice = sender {
                let dev = Unmanaged<IOHIDDevice>.fromOpaque(senderDevice).takeUnretainedValue()
                mgr.markDeviceActive(dev)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// 标记某设备为"当前在用"
    private func markDeviceActive(_ device: IOHIDDevice) {
        let model = makeModel(from: device)
        if let idx = knownDevices.firstIndex(where: { $0.id == model.id }) {
            // 手动触发 objectWillChange，因为修改的是数组内元素的属性
            objectWillChange.send()
            knownDevices[idx].lastActivity = Date()
        }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        let model = makeModel(from: device)
        if let idx = knownDevices.firstIndex(where: { $0.id == model.id }) {
            // 关键：断开时只标记离线，不删除规则
            knownDevices[idx].isOnline = false
        }
        AppState.shared.devices = knownDevices.filter { $0.isOnline }
    }

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
