#if DEBUG
import AppKit
import Foundation

/// 调试自检：`Kaiming --logic-test-system`。
/// 只读采样 + 一次内存释放，不改动用户缓存与设置；结果打印到 stdout 后退出。
enum SystemSelfTest {
    @MainActor
    static func run() {
        Task {
            let monitor = SystemMonitor.shared
            let started = Date()
            await monitor.refreshNow()
            print("[system-test] refresh \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            print("[system-test] memory used=\(monitor.memory.usedBytes) total=\(monitor.memory.totalBytes) pct=\(monitor.memory.usedPercent) reclaimable=\(monitor.memory.reclaimableBytes) pressure=\(monitor.memory.pressure.rawValue)")
            print("[system-test] cpu usage=\(monitor.cpu.usage) cores=\(monitor.cpu.coreCount) load=\(monitor.cpu.loadAverage)")
            print("[system-test] disk available=\(monitor.disk.availableBytes) total=\(monitor.disk.totalBytes) volume=\(monitor.disk.volumeName ?? "-")")
            let tempText = monitor.sensors.cpuTemperature.map { String(format: "%.2f", $0) } ?? "-"
            let fanText = monitor.sensors.fanRPM.map { String(format: "%.0f", $0) } ?? "-"
            print("[system-test] sensors temp=\(tempText) source=\(monitor.sensors.temperatureSource ?? "-") fan=\(fanText)")
            print("[system-test] network down=\(monitor.network.downloadBytesPerSecond) up=\(monitor.network.uploadBytesPerSecond) if=\(monitor.network.interfaceName ?? "-")")
            print("[system-test] apps=\(monitor.apps.map { "\($0.name):\($0.bytes)" })")

            let scanStarted = Date()
            let scan = await Task.detached(priority: .utility) { CacheCleaner.scan() }.value
            print("[system-test] cache-scan \(String(format: "%.2f", Date().timeIntervalSince(scanStarted)))s total=\(scan.totalBytes) items=\(scan.totalItems)")

            runCacheCleanerFixture()
            print("[system-test] cache-fixture done")

            let release = await monitor.releaseMemory()
            print("[system-test] release allocated=\(release.allocatedBytes) freed=\(release.freedBytes)")

            try? await Task.sleep(nanoseconds: 300_000_000)
            print("[system-test] done")
            NSApp.terminate(nil)
        }
    }

    /// 在临时目录里验证「扫描 / 1 小时保护 / 清理」逻辑，不碰真实缓存。
    private static func runCacheCleanerFixture() {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kaiming-system-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: base) }

        var roots: [CacheKind: URL] = [:]
        for kind in CacheKind.allCases {
            let root = base.appendingPathComponent(kind.rawValue, isDirectory: true)
            try? manager.createDirectory(at: root, withIntermediateDirectories: true)
            roots[kind] = root
        }

        func write(_ kind: CacheKind, _ name: String, bytes: Int, age: TimeInterval) {
            guard let root = roots[kind] else { return }
            let file = root.appendingPathComponent(name)
            try? Data(repeating: 0x41, count: bytes).write(to: file)
            try? manager.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)],
                ofItemAtPath: file.path
            )
        }

        write(.userCaches, "old.bin", bytes: 2_000_000, age: 2 * 3600)
        write(.userCaches, "new.bin", bytes: 1_000_000, age: 0)
        write(.logs, "old.log", bytes: 100_000, age: 2 * 3600)

        let scan = CacheCleaner.scan(roots: roots)
        let outcome = CacheCleaner.clean(kinds: Set(CacheKind.allCases), roots: roots)
        let newFileKept = manager.fileExists(atPath: roots[.userCaches]!.appendingPathComponent("new.bin").path)
        let oldFileRemoved = !manager.fileExists(atPath: roots[.userCaches]!.appendingPathComponent("old.bin").path)
        print("[system-test] cache-fixture scan=\(scan.totalBytes) items=\(scan.totalItems) freed=\(outcome.freedBytes) removed=\(outcome.removedItems) newKept=\(newFileKept) oldRemoved=\(oldFileRemoved)")
    }
}
#endif
