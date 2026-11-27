import AppKit
import Foundation

// MARK: - 内存

/// 系统内存压力等级，来自 `kern.memorystatus_vm_pressure_level`。
enum MemoryPressure: String, Sendable, Equatable {
    case normal
    case warning
    case critical

    var title: String {
        switch self {
        case .normal: "正常"
        case .warning: "偏高"
        case .critical: "紧张"
        }
    }
}

/// 一次内存采样。
///
/// 口径与「活动监视器」一致：已用 = 应用内存（internal − purgeable）+ 联动内存 + 压缩内存。
struct MemorySnapshot: Sendable, Equatable {
    var totalBytes: UInt64 = 0
    var usedBytes: UInt64 = 0
    var appBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    /// 预计可回收（inactive + purgeable），仅用于展示与释放目标估算。
    var reclaimableBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0
    var pressure: MemoryPressure = .normal

    static let empty = MemorySnapshot()

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }

    var usedPercent: Int { Int((usedFraction * 100).rounded()) }
}

// MARK: - CPU / 磁盘 / 网络

struct CPUSnapshot: Sendable, Equatable {
    /// 0…1，全部核心的加权占用。
    var usage: Double = 0
    var coreCount: Int = 0
    var loadAverage: Double = 0

    static let empty = CPUSnapshot()
}

struct DiskSnapshot: Sendable, Equatable {
    var totalBytes: UInt64 = 0
    var availableBytes: UInt64 = 0
    var volumeName: String?

    static let empty = DiskSnapshot()

    var usedBytes: UInt64 { totalBytes > availableBytes ? totalBytes - availableBytes : 0 }
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }
    var availableFraction: Double { max(0, 1 - usedFraction) }
    var usedPercent: Int { Int((usedFraction * 100).rounded()) }
}

struct NetworkSnapshot: Sendable, Equatable {
    var downloadBytesPerSecond: Double = 0
    var uploadBytesPerSecond: Double = 0
    /// 参与统计的物理网卡（例如 en0）；未连接时为 nil。
    var interfaceName: String?

    static let empty = NetworkSnapshot()
}

struct NetworkPoint: Identifiable, Sendable, Equatable {
    let id = UUID()
    let time: Date
    let download: Double
    let upload: Double
}

// MARK: - 传感器

struct SensorSnapshot: Sendable, Equatable {
    /// CPU 集群温度（摄氏度）。机型未暴露传感器时为 nil。
    var cpuTemperature: Double?
    var fanRPM: Double?
    var fanMinRPM: Double?
    var fanMaxRPM: Double?
    /// 温度读数的来源说明，用于界面上的「—」解释。
    var temperatureSource: String?

    static let empty = SensorSnapshot()
}

// MARK: - 进程 / 应用

/// 后台采样得到的「应用包路径 + 累计物理内存」，图标与名称在主线程补齐。
struct AppProcessSample: Sendable, Equatable {
    var bundlePath: String
    var bytes: UInt64
    var pid: Int32
}

/// 面板展示用的一行应用内存占用。
struct AppMemoryRow: Identifiable {
    let id: String
    let name: String
    let bytes: UInt64
    let icon: NSImage?
    var isOther = false
}

// MARK: - 系统身份

struct SystemIdentity: Sendable, Equatable {
    var chip: String
    var osVersion: String
    var memoryBytes: UInt64

    var summary: String {
        var parts: [String] = []
        if !chip.isEmpty { parts.append(chip) }
        if !osVersion.isEmpty { parts.append("macOS \(osVersion)") }
        if memoryBytes > 0 { parts.append("\(SystemFormat.bytes(memoryBytes)) 内存") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 格式化

enum SystemFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    /// 1024 进制，1.91 GB / 268 MB / 65.6 MB 风格。
    static func bytes(_ value: UInt64) -> String { bytes(Double(value)) }

    static func bytes(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0 B" }
        var amount = value
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(amount.rounded())) B" }
        let digits: Int = amount >= 100 ? 0 : (amount >= 10 ? 1 : 2)
        return String(format: "%.\(digits)f %@", amount, units[unit])
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(max(0, bytesPerSecond)) + "/s"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else { return "—" }
        return String(format: "%.0f°C", celsius)
    }

    static func compactTemperature(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else { return "—" }
        return String(format: "%.0f°", celsius)
    }

    /// 菜单栏用的极短速率：1.2M / 812K / 0。
    static func compactRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0" }
        let kb = 1024.0
        let mb = kb * 1024
        let gb = mb * 1024
        if bytesPerSecond >= gb { return trimmed(bytesPerSecond / gb) + "G" }
        if bytesPerSecond >= mb { return trimmed(bytesPerSecond / mb) + "M" }
        if bytesPerSecond >= kb { return trimmed(bytesPerSecond / kb) + "K" }
        return "\(Int(bytesPerSecond.rounded()))B"
    }

    private static func trimmed(_ value: Double) -> String {
        if value >= 10 { return String(format: "%.0f", value) }
        if value >= 1 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    static func rpm(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(value.rounded())) R"
    }

    static func signedRPM(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "—" }
        return "\(Int(value.rounded())) R"
    }
}
