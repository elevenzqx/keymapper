import Foundation
import IOKit.hid

/// 键盘传输类型
enum KeyboardConnectionType: String, Codable, CaseIterable {
    case builtIn = "内置键盘"
    case usb = "USB 有线"
    case bluetooth = "蓝牙"
    case wireless = "2.4G 无线"
    case other = "其他"

    /// 从 IOHID 属性推导传输类型
    static func from(device: IOHIDDevice) -> KeyboardConnectionType {
        if let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String {
            switch transport {
            case "Bluetooth":
                return .bluetooth
            case "BluetoothLowEnergy", "BLE":
                return .bluetooth
            case "USB":
                return .usb
            case "Built-in", "Built-In", "Internal":
                return .builtIn
            case "Wireless", "RF", "2.4G", "2.4GHz":
                return .wireless
            default:
                break
            }
        }
        // 兜底：通过 Bluetooth 相关属性判断
        if IOHIDDeviceGetProperty(device, "BluetoothDevice" as CFString) != nil
            || IOHIDDeviceGetProperty(device, "BTAddress" as CFString) != nil {
            return .bluetooth
        }
        // 兜底：有无线相关属性
        if IOHIDDeviceGetProperty(device, "Wireless" as CFString) != nil {
            return .wireless
        }
        return .other
    }
}

/// 键盘设备模型
struct KeyboardDevice: Identifiable, Codable, Equatable {
    /// 稳定的设备指纹，用于持久化映射规则
    let id: String

    /// 展示名称（尽量为品牌+型号真名）
    var name: String

    /// 制造商名称
    var manufacturer: String

    /// 蓝牙设备名（仅蓝牙/2.4G 有效，用于区分具体是哪把键盘）
    var bluetoothName: String?

    /// 传输类型
    var connectionType: KeyboardConnectionType

    var vendorID: Int
    var productID: Int
    var locationID: Int

    /// 当前是否在线（在线与否由 DeviceManager 动态更新）
    var isOnline: Bool = false

    /// 最近一次收到按键事件的时间（用于判断"当前在用"）
    var lastActivity: Date?

    /// 该设备的映射规则（源键 → 目标键，keyCode 层面）
    var mappings: [KeyMapping] = []

    /// 是否"当前在用"（最近 5 秒内有按键活动）
    var isActive: Bool {
        guard let last = lastActivity else { return false }
        return Date().timeIntervalSince(last) < 5.0
    }

    /// 生成稳定指纹：优先序列号，其次 vendor+product+location
    static func fingerprint(vendorID: Int,
                            productID: Int,
                            locationID: Int,
                            serialNumber: String?) -> String {
        if let serial = serialNumber, !serial.isEmpty, serial != "Unknown" {
            return "sn:\(serial)"
        }
        return "vp:\(vendorID)-\(productID)-\(locationID)"
    }

    init(id: String,
         name: String,
         manufacturer: String = "",
         bluetoothName: String? = nil,
         connectionType: KeyboardConnectionType,
         vendorID: Int,
         productID: Int,
         locationID: Int,
         mappings: [KeyMapping] = []) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.bluetoothName = bluetoothName
        self.connectionType = connectionType
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.mappings = mappings
    }
}

/// 单条按键映射：源键 keyCode → 目标键 keyCode
struct KeyMapping: Codable, Equatable, Identifiable {
    var id: String { "\(sourceKeyCode)->\(targetKeyCode)" }

    /// 源按键 keyCode（CGKeyCode）
    var sourceKeyCode: UInt16
    /// 目标按键 keyCode
    var targetKeyCode: UInt16

    /// 是否启用
    var enabled: Bool = true

    init(sourceKeyCode: UInt16, targetKeyCode: UInt16, enabled: Bool = true) {
        self.sourceKeyCode = sourceKeyCode
        self.targetKeyCode = targetKeyCode
        self.enabled = enabled
    }
}
