@preconcurrency import Darwin
import Foundation

// MARK: - 无状态采样

/// 直接调用 Darwin / Mach API 的采样实现。
///
/// 这些函数都会被放到后台线程执行；它们不触碰 AppKit，因此可以安全地在
/// `Task.detached` 里调用（返回类型全部是 `Sendable` 值类型）。
enum SystemSampler {

    // MARK: 内存

    static func memory() -> MemorySnapshot {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .empty }

        let page = UInt64(getpagesize())
        let total = ProcessInfo.processInfo.physicalMemory
        let free = UInt64(stats.free_count) * page
        let speculative = UInt64(stats.speculative_count) * page
        let inactive = UInt64(stats.inactive_count) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let purgeable = UInt64(stats.purgeable_count) * page
        let internalPages = UInt64(stats.internal_page_count) * page

        // 活动监视器口径：应用内存 = internal − purgeable（避免把可回收页算作已用）。
        let appMemory = internalPages > purgeable ? internalPages - purgeable : 0
        let used = min(total, appMemory + wired + compressed)
        let reclaimable = min(total - min(used, total), inactive + speculative + purgeable)
        let swap = swapUsage()

        return MemorySnapshot(
            totalBytes: total,
            usedBytes: used,
            appBytes: appMemory,
            wiredBytes: wired,
            compressedBytes: compressed,
            freeBytes: free,
            reclaimableBytes: reclaimable,
            swapUsedBytes: swap.used,
            swapTotalBytes: swap.total,
            pressure: memoryPressure()
        )
    }

    private static func memoryPressure() -> MemoryPressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            if level >= 4 { return .critical }
            if level >= 2 { return .warning }
        }
        return .normal
    }

    private static func swapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    // MARK: 磁盘

    static func disk() -> DiskSnapshot {
        let url = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else {
            return .empty
        }
        let available = values.volumeAvailableCapacity ?? 0
        return DiskSnapshot(
            totalBytes: UInt64(max(total, 0)),
            availableBytes: UInt64(max(available, 0)),
            volumeName: values.volumeName
        )
    }

    // MARK: 进程（按 .app 聚合）

    /// 找出所有用户态 .app 进程，按最外层 `.app` 路径聚合物理内存（footprint）。
    ///
    /// 系统守护进程（路径里没有 `.app/`）会被跳过；Chrome / Electron 的帮助进程
    /// 会归并到宿主应用下，与活动监视器的「按应用」口径接近。
    static func appGroups() -> [AppProcessSample] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = size / stride + 8
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }

        let count = min(size / stride, capacity)
        var groups: [String: (bytes: UInt64, pid: Int32)] = [:]
        var pathBuffer = [CChar](repeating: 0, count: 4096)

        for index in 0..<count {
            let pid = processes[index].kp_proc.p_pid
            guard pid > 1 else { continue }
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            let executablePath = string(from: pathBuffer)
            guard let bundlePath = appBundlePath(in: executablePath) else { continue }
            guard let footprint = physicalFootprint(pid: pid), footprint > 0 else { continue }

            if let existing = groups[bundlePath] {
                groups[bundlePath] = (existing.bytes + footprint, existing.pid)
            } else {
                groups[bundlePath] = (footprint, pid)
            }
        }

        return groups.map { path, value in
            AppProcessSample(bundlePath: path, bytes: value.bytes, pid: value.pid)
        }
    }

    /// `/Applications/Foo.app/Contents/...` → `/Applications/Foo.app`。
    private static func appBundlePath(in executablePath: String) -> String? {
        guard let range = executablePath.range(of: ".app/", options: .caseInsensitive) else { return nil }
        return String(executablePath[executablePath.startIndex..<range.upperBound].dropLast())
    }

    /// 与活动监视器「内存」列同源的物理 footprint（含压缩页分摊）。
    private static func physicalFootprint(pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        return result == 0 ? UInt64(info.ri_phys_footprint) : nil
    }

    // MARK: 系统身份

    static func identity() -> SystemIdentity {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(version.majorVersion).\(version.minorVersion)"
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Mac"
        return SystemIdentity(
            chip: chip,
            osVersion: osVersion,
            memoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    private static func string(from buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return string(from: buffer)
    }
}

// MARK: - CPU 增量采样

/// `host_processor_info` 返回的是累计 tick，需要保存上一帧才能算占用率。
final class CPUCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var previousUsed: [UInt64] = []
    private var previousTotal: [UInt64] = []

    func sample() -> CPUSnapshot {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &info,
            &infoCount
        )
        var loads: [Double] = []
        if result == KERN_SUCCESS, let info, cpuCount > 0 {
            defer {
                vm_deallocate(
                    MachSupport.taskPort,
                    vm_address_t(UInt(bitPattern: info)),
                    vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
                )
            }
            let ticks = info.withMemoryRebound(to: processor_cpu_load_info.self, capacity: Int(cpuCount)) {
                UnsafeBufferPointer(start: $0, count: Int(cpuCount))
            }
            loads = computeUsage(ticks: ticks)
        }

        let load = loadAverages()
        return CPUSnapshot(
            usage: loads.isEmpty ? 0 : loads.reduce(0, +) / Double(loads.count),
            coreCount: Int(cpuCount),
            loadAverage: load
        )
    }

    private func computeUsage(ticks: UnsafeBufferPointer<processor_cpu_load_info>) -> [Double] {
        lock.lock()
        defer { lock.unlock() }

        var used: [UInt64] = []
        var totals: [UInt64] = []
        for tick in ticks {
            let user = UInt64(tick.cpu_ticks.0)
            let system = UInt64(tick.cpu_ticks.1)
            let idle = UInt64(tick.cpu_ticks.2)
            let nice = UInt64(tick.cpu_ticks.3)
            let busy = user + system + nice
            used.append(busy)
            totals.append(busy + idle)
        }

        var usage: [Double] = []
        if previousUsed.count == used.count, previousTotal.count == totals.count {
            for index in used.indices {
                let busyDelta = used[index] >= previousUsed[index] ? used[index] - previousUsed[index] : 0
                let totalDelta = totals[index] >= previousTotal[index] ? totals[index] - previousTotal[index] : 0
                usage.append(totalDelta > 0 ? min(1, Double(busyDelta) / Double(totalDelta)) : 0)
            }
        } else {
            usage = Array(repeating: 0, count: used.count)
        }

        previousUsed = used
        previousTotal = totals
        return usage
    }

    private func loadAverages() -> Double {
        var load: [Double] = [0, 0, 0]
        let count = getloadavg(&load, 3)
        guard count > 0 else { return 0 }
        return load[0]
    }
}

// MARK: - 网络增量采样

/// `getifaddrs` 的字节计数同样是累计值；每秒两次采样求差分。
final class NetworkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: (date: Date, received: UInt64, sent: UInt64)?

    func sample() -> NetworkSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let counters = Self.readCounters()
        let now = Date()
        var snapshot = NetworkSnapshot(
            downloadBytesPerSecond: 0,
            uploadBytesPerSecond: 0,
            interfaceName: counters.name
        )

        if let previous {
            let interval = now.timeIntervalSince(previous.date)
            if interval > 0.05 {
                let received = counters.received >= previous.received ? counters.received - previous.received : 0
                let sent = counters.sent >= previous.sent ? counters.sent - previous.sent : 0
                snapshot.downloadBytesPerSecond = Double(received) / interval
                snapshot.uploadBytesPerSecond = Double(sent) / interval
            }
        }
        previous = (now, counters.received, counters.sent)
        return snapshot
    }

    private static func readCounters() -> (received: UInt64, sent: UInt64, name: String?) {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else { return (0, 0, nil) }
        defer { freeifaddrs(addressList) }

        // 只统计物理网卡：utun/awdl/bridge 等虚拟接口会重复计数 VPN 流量。
        let includedPrefixes = ["en", "pdp", "ppp"]
        let excludedPrefixes = ["lo", "utun", "ipsec", "awdl", "llw", "bridge", "ap", "gif", "stf", "p2p"]

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var primary: String?

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard includedPrefixes.contains(where: { name.hasPrefix($0) }),
                  !excludedPrefixes.contains(where: { name.hasPrefix($0) }),
                  let data = current.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else {
                continue
            }
            received += UInt64(data.pointee.ifi_ibytes)
            sent += UInt64(data.pointee.ifi_obytes)
            if primary == nil, (flags & IFF_RUNNING) != 0 { primary = name }
        }
        return (received, sent, primary)
    }
}
