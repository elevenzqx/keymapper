import Foundation
import Combine
import ApplicationServices

/// 全局应用状态
final class AppState: ObservableObject {
    static let shared = AppState()

    /// 是否暂停所有映射
    @Published var isPaused: Bool = false {
        didSet { MappingEngine.shared.setPaused(isPaused) }
    }

    /// 是否已授予辅助功能权限
    @Published var accessibilityGranted: Bool = AXIsProcessTrusted()

    /// 当前在线设备列表
    @Published var devices: [KeyboardDevice] = []

    private init() {}
}
