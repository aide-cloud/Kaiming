import Foundation

/// 菜单栏（状态栏）可以展示的系统指标。
///
/// 设置项放在 `Shared/`：`SettingsStore` 需要持久化这份选择，而 `SystemMonitor`
/// 只负责提供数值；两侧都不必互相引用对方的类型。
enum SystemStatusMetric: String, CaseIterable, Identifiable, Sendable {
    case cpuTemperature
    case cpuUsage
    case fanSpeed
    case memoryUsage
    case diskUsage
    case networkDownload
    case networkUpload

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpuTemperature: "CPU 温度"
        case .cpuUsage: "CPU 负载"
        case .fanSpeed: "风扇转速"
        case .memoryUsage: "内存占用"
        case .diskUsage: "磁盘占用"
        case .networkDownload: "网络下载"
        case .networkUpload: "网络上传"
        }
    }

    /// 面板里的小标签，尽量短。
    var shortTitle: String {
        switch self {
        case .cpuTemperature: "温度"
        case .cpuUsage: "负载"
        case .fanSpeed: "风扇"
        case .memoryUsage: "内存"
        case .diskUsage: "磁盘"
        case .networkDownload: "下载"
        case .networkUpload: "上传"
        }
    }

    var symbolName: String {
        switch self {
        case .cpuTemperature: "thermometer.medium"
        case .cpuUsage: "cpu"
        case .fanSpeed: "fanblades"
        case .memoryUsage: "memorychip"
        case .diskUsage: "internaldrive"
        case .networkDownload: "arrow.down"
        case .networkUpload: "arrow.up"
        }
    }
}
