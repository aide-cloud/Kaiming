import CoreFoundation
import Foundation
import IOKit

// MARK: - SMC（风扇）

/// 通过 AppleSMC 用户客户端读取风扇转速。
///
/// SMC 返回的数据在结构体字段上使用主机字节序，但键值本身是大端，容易踩坑：
/// 这里用固定 80 字节缓冲区 + 明确的偏移量读写，与 AppleSMC 的 `SMCKeyData_t` 对齐。
final class SMCConnection {
    private var connection: io_connect_t = 0
    private static let kernelIndexSMC: UInt32 = 2
    private static let commandReadBytes: UInt8 = 5
    private static let commandReadKeyInfo: UInt8 = 9

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var handle: io_connect_t = 0
        guard IOServiceOpen(service, MachSupport.taskPort, 0, &handle) == KERN_SUCCESS, handle != 0 else {
            return nil
        }
        connection = handle
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// 读取任意键的原始值。
    func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard let info = keyInfo(key), info.result == 0,
              info.dataSize > 0, info.dataSize <= 32 else {
            return nil
        }
        let code = Self.fourCharacterCode(key)
        var valueInput = [UInt8](repeating: 0, count: 80)
        Self.writeUInt32(&valueInput, 0, code)
        Self.writeUInt32(&valueInput, 28, info.dataSize)
        valueInput[42] = Self.commandReadBytes
        guard let value = call(valueInput), value[40] == 0 else { return nil }
        let size = Int(info.dataSize)
        return (info.type, Array(value[48..<(48 + size)]))
    }

    /// `nil` 表示连接层失败；`false` 表示键在 SMC 里不存在（例如无风扇机型）。
    func hasKey(_ key: String) -> Bool? {
        guard let info = keyInfo(key) else { return nil }
        if info.result == 0 { return true }
        if info.result == 0x84 { return false }
        return nil
    }

    private func keyInfo(_ key: String) -> (dataSize: UInt32, type: String, result: UInt8)? {
        guard connection != 0 else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        Self.writeUInt32(&input, 0, Self.fourCharacterCode(key))
        input[42] = Self.commandReadKeyInfo
        guard let output = call(input) else { return nil }
        let dataSize = Self.readUInt32(output, 28)
        let type = String(bytes: output[32..<36].reversed(), encoding: .ascii) ?? "????"
        return (dataSize, type, output[40])
    }

    /// 读取并解码为浮点数（风扇：flt / fpe2）。
    func number(_ key: String) -> Double? {
        guard let reading = read(key) else { return nil }
        return Self.decode(reading)
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = 80
        let result = input.withUnsafeBytes { inputPointer in
            output.withUnsafeMutableBytes { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    Self.kernelIndexSMC,
                    inputPointer.baseAddress,
                    80,
                    outputPointer.baseAddress,
                    &outputSize
                )
            }
        }
        return result == KERN_SUCCESS ? output : nil
    }

    // MARK: 字节序

    private static func fourCharacterCode(_ key: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in key.utf8.prefix(4) {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    /// 结构体字段按主机（小端）字节序写入。
    private static func writeUInt32(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt32) {
        buffer[offset] = UInt8(value & 0xff)
        buffer[offset + 1] = UInt8((value >> 8) & 0xff)
        buffer[offset + 2] = UInt8((value >> 16) & 0xff)
        buffer[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private static func readUInt32(_ buffer: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(buffer[offset])
            | UInt32(buffer[offset + 1]) << 8
            | UInt32(buffer[offset + 2]) << 16
            | UInt32(buffer[offset + 3]) << 24
    }

    private static func decode(_ reading: (type: String, bytes: [UInt8])) -> Double? {
        let bytes = reading.bytes
        switch reading.type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw)) / 256
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui8 ":
            return bytes.first.map(Double.init)
        default:
            return nil
        }
    }
}

// MARK: - IOHID 温度传感器

/// 通过 IOHIDEventSystemClient 读取 Apple Silicon 暴露的温度传感器。
///
/// `IOHIDEventSystemClientCreateWithType` 等符号不在公开 SDK 头文件里，
/// 因此用 `dlsym` 动态解析；任一符号缺失时整个读取器静默退化为 nil，不影响其它功能。
final class HIDTemperatureReader {
    private typealias CreateWithType = @convention(c) (CFAllocator?, UInt32, CFDictionary?) -> CFTypeRef?
    private typealias CopyServices = @convention(c) (CFTypeRef) -> CFArray?
    private typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> CFTypeRef?
    private typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> CFTypeRef?
    private typealias GetFloatValue = @convention(c) (CFTypeRef, Int32) -> Double

    private static let temperatureEvent: Int64 = 15
    private static let temperatureField = Int32(15 << 16)
    private static let sensorPage = 0xff00
    private static let temperatureUsage = 5

    private var client: CFTypeRef?
    private let copyServices: CopyServices
    private let copyProperty: CopyProperty
    private let copyEvent: CopyEvent
    private let getFloatValue: GetFloatValue

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            return nil
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let create = symbol("IOHIDEventSystemClientCreateWithType", as: CreateWithType.self),
              let services = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let property = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let event = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let value = symbol("IOHIDEventGetFloatValue", as: GetFloatValue.self),
              let systemClient = create(kCFAllocatorDefault, 1, nil) else {
            return nil
        }
        client = systemClient
        copyServices = services
        copyProperty = property
        copyEvent = event
        getFloatValue = value
    }

    /// 最高 CPU 集群温度：优先 pACC / eACC（性能 / 能效簇），其次 PMU 晶粒、SOC 传感器。
    func cpuTemperature() -> (celsius: Double, source: String)? {
        guard let client, let services = copyServices(client) as? [CFTypeRef] else { return nil }

        var cluster: [Double] = []
        var die: [Double] = []
        var soc: [Double] = []

        for service in services {
            guard let page = (copyProperty(service, "PrimaryUsagePage" as CFString) as? Int),
                  page == Self.sensorPage,
                  let usage = (copyProperty(service, "PrimaryUsage" as CFString) as? Int),
                  usage == Self.temperatureUsage,
                  let name = copyProperty(service, "Product" as CFString) as? String,
                  let event = copyEvent(service, Self.temperatureEvent, 0, 0) else {
                continue
            }
            let value = getFloatValue(event, Self.temperatureField)
            guard value.isFinite, value > 1, value < 130 else { continue }

            if name.contains("pACC") || name.contains("eACC") {
                cluster.append(value)
            } else if name.hasPrefix("PMU"), name.contains("tdie") {
                die.append(value)
            } else if name.contains("SOC MTR") {
                soc.append(value)
            } else if name.contains("PMGR SOC Die") {
                soc.append(value)
            }
        }

        if let value = cluster.max() { return (value, "CPU 集群") }
        if let value = die.max() { return (value, "PMU 晶粒") }
        if let value = soc.max() { return (value, "SOC 晶粒") }
        return nil
    }
}

// MARK: - 传感器门面

/// 把所有硬件传感器读取串行化在一个 actor 里，避免 IOKit 连接被并发访问。
actor SensorReader {
    private var smc: SMCConnection?
    private var hid: HIDTemperatureReader?
    private var initialized = false
    private var failedFanReads = 0

    func sample() -> SensorSnapshot {
        if !initialized {
            smc = SMCConnection()
            hid = HIDTemperatureReader()
            initialized = true
        }

        var snapshot = SensorSnapshot.empty
        if let reading = hid?.cpuTemperature() {
            snapshot.cpuTemperature = reading.celsius
            snapshot.temperatureSource = reading.source
        }

        if let smc {
            // Intel / 部分机型的 IOHID 不暴露 CPU 簇传感器，退回 SMC 常见键。
            if snapshot.cpuTemperature == nil {
                for key in ["TC0P", "TC0D", "Tp09", "Tp0P", "Te05"] {
                    if let celsius = smc.number(key), celsius > 5, celsius < 130 {
                        snapshot.cpuTemperature = celsius
                        snapshot.temperatureSource = "SMC \(key)"
                        break
                    }
                }
            }

            if let rpm = smc.number("F0Ac"), rpm > 0, rpm < 20_000 {
                snapshot.fanRPM = rpm
                snapshot.fanMinRPM = smc.number("F0Mn")
                snapshot.fanMaxRPM = smc.number("F0Mx")
                failedFanReads = 0
            } else if smc.hasKey("F0Ac") == true {
                failedFanReads += 1
                // 睡眠唤醒后 SMC 连接可能失效，连续失败时重建一次。
                if failedFanReads >= 5 {
                    self.smc = SMCConnection()
                    failedFanReads = 0
                }
            } else {
                // 键不存在（无风扇机型）不是故障，不触发重连。
                failedFanReads = 0
            }
        }
        return snapshot
    }
}
