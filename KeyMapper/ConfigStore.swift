import Foundation

/// 映射规则的持久化：JSON 存到 ~/Library/Application Support/KeyMapper/
final class ConfigStore {
    static let shared = ConfigStore()

    private struct ConfigFile: Codable {
        /// deviceID → 映射规则数组
        var deviceMappings: [String: [KeyMapping]] = [:]
    }

    private var config: ConfigFile
    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("KeyMapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(ConfigFile.self, from: data) {
            config = decoded
        } else {
            config = ConfigFile()
        }
    }

    /// 读取某设备的映射规则
    func mappings(forDeviceID id: String) -> [KeyMapping]? {
        config.deviceMappings[id]
    }

    /// 保存某设备的映射规则
    func saveMappings(_ mappings: [KeyMapping], forDeviceID id: String) {
        config.deviceMappings[id] = mappings
        persist()
    }

    /// 删除某设备的映射规则（手动删除）
    func deleteMappings(forDeviceID id: String) {
        config.deviceMappings.removeValue(forKey: id)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
