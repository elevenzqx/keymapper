import Foundation
import Carbon.HIToolbox

/// 提供 keyCode 与可读名称之间的转换
enum KeyCodeMap {
    /// 常用按键 keyCode → 名称（虚拟键码参考 Carbon HIToolbox）
    static let names: [UInt16: String] = [
        // 字母
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
        38: "J", 40: "K", 45: "N", 46: "M",
        // 数字（主键盘）
        18: "1", 19: "2", 20: "3", 21: "4", 22: "5", 23: "6",
        26: "7", 28: "8", 25: "9", 29: "0",
        // 数字（小键盘）
        82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3", 86: "Num 4",
        87: "Num 5", 88: "Num 6", 89: "Num 7", 91: "Num 8", 92: "Num 9",
        // 功能键
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        // 修饰键
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete",
        53: "Esc", 71: "Clear", 76: "Keypad Enter", 65: "Keypad .",
        67: "Keypad *", 69: "Keypad +", 78: "Keypad -", 75: "Keypad /",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        114: "Insert", 115: "Home", 116: "Page Up", 117: "Forward Delete",
        119: "End", 121: "Page Down",
    ]

    static func name(for keyCode: UInt16) -> String {
        names[keyCode] ?? String(format: "0x%02X", keyCode)
    }

    /// 可供选择的按键列表（按分组排序，方便下拉选择）
    static var allKeys: [UInt16] {
        Array(names.keys).sorted()
    }
}
