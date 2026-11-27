import Foundation

// MARK: - 可清理的垃圾位置

enum CacheKind: String, CaseIterable, Identifiable, Sendable {
    case userCaches
    case logs
    case trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userCaches: "应用缓存"
        case .logs: "日志"
        case .trash: "废纸篓"
        }
    }

    var url: URL {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        switch self {
        case .userCaches: return home.appendingPathComponent("Library/Caches", isDirectory: true)
        case .logs: return home.appendingPathComponent("Library/Logs", isDirectory: true)
        case .trash: return home.appendingPathComponent(".Trash", isDirectory: true)
        }
    }
}

struct CacheCategoryResult: Identifiable, Sendable, Equatable {
    let kind: CacheKind
    var bytes: UInt64
    var itemCount: Int

    var id: String { kind.rawValue }
}

struct CacheScanResult: Sendable, Equatable {
    var categories: [CacheCategoryResult]
    var scannedAt: Date

    func bytes(for kind: CacheKind) -> UInt64 {
        categories.first(where: { $0.kind == kind })?.bytes ?? 0
    }

    var totalBytes: UInt64 {
        categories.reduce(0) { $0 + $1.bytes }
    }

    var totalItems: Int {
        categories.reduce(0) { $0 + $1.itemCount }
    }
}

struct CacheCleanOutcome: Sendable, Equatable {
    var freedBytes: UInt64
    var removedItems: Int

    static let empty = CacheCleanOutcome(freedBytes: 0, removedItems: 0)
}

// MARK: - 缓存扫描 / 清理

enum CacheCleaner {
    /// 扫描时最多统计的条目数，避免某个巨大目录让面板等待过久。
    private static let scanLimit = 250_000

    static func scan(
        kinds: Set<CacheKind> = Set(CacheKind.allCases),
        roots: [CacheKind: URL]? = nil
    ) -> CacheScanResult {
        var categories: [CacheCategoryResult] = []
        for kind in CacheKind.allCases where kinds.contains(kind) {
            if Task.isCancelled { break }
            let measured = measure(roots?[kind] ?? kind.url)
            categories.append(CacheCategoryResult(kind: kind, bytes: measured.bytes, itemCount: measured.items))
        }
        return CacheScanResult(categories: categories, scannedAt: Date())
    }

    /// 只清理 1 小时前修改过的内容，避免动到正在写入的缓存。
    static func clean(
        kinds: Set<CacheKind>,
        roots: [CacheKind: URL]? = nil
    ) -> CacheCleanOutcome {
        let cutoff = Date().addingTimeInterval(-3600)
        var freed: UInt64 = 0
        var removed = 0

        for kind in CacheKind.allCases where kinds.contains(kind) {
            let root = roots?[kind] ?? kind.url
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            ) else { continue }

            for item in items {
                if Task.isCancelled { break }
                let values = try? item.resourceValues(forKeys: [.contentModificationDateKey])
                if let modified = values?.contentModificationDate, modified > cutoff { continue }

                let measured = measure(item)
                do {
                    try FileManager.default.removeItem(at: item)
                    freed += measured.bytes
                    removed += measured.items
                } catch {
                    // 文件被占用 / 权限不足时跳过，不中断整轮清理。
                    continue
                }
            }
        }
        return CacheCleanOutcome(freedBytes: freed, removedItems: removed)
    }

    private static func measure(_ url: URL) -> (bytes: UInt64, items: Int) {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
        ]
        let keySet = Set(keys)

        // 清理阶段会直接传单个文件 URL；`enumerator(at:)` 对文件返回 nil，需要单独处理。
        if let values = try? url.resourceValues(forKeys: keySet) {
            if values.isSymbolicLink == true { return (0, 1) }
            if values.isRegularFile == true {
                let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
                return (UInt64(max(size, 0)), 1)
            }
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return (0, 0)
        }

        var bytes: UInt64 = 0
        var items = 0
        for case let fileURL as URL in enumerator {
            if items >= scanLimit || Task.isCancelled { break }
            let values = try? fileURL.resourceValues(forKeys: keySet)
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let size = values?.totalFileAllocatedSize
                ?? values?.fileAllocatedSize
                ?? values?.fileSize
                ?? 0
            bytes += UInt64(max(size, 0))
            items += 1
        }
        return (bytes, items)
    }
}

// MARK: - 内存释放

struct MemoryReleaseResult: Sendable, Equatable {
    var freedBytes: UInt64
    var allocatedBytes: UInt64

    static let empty = MemoryReleaseResult(freedBytes: 0, allocatedBytes: 0)
}

/// 通过一次性申请并立即归还大块内存，给内核施加短暂压力，促使它回收闲置页。
/// 这不是 root-only 的 `purge`，所以实际回收量有限；界面按采样差值如实展示。
enum MemoryReclaimer {
    static let chunkBytes = 32 * 1024 * 1024

    /// 压力越高，施加的瞬时内存越少，避免在紧张时把系统推向交换。
    static func targetBytes(reclaimable: UInt64, pressure: MemoryPressure) -> UInt64 {
        let cap: UInt64 = switch pressure {
        case .normal: 1024 * 1024 * 1024
        case .warning: 512 * 1024 * 1024
        case .critical: 256 * 1024 * 1024
        }
        let floor: UInt64 = 192 * 1024 * 1024
        return min(cap, max(floor, reclaimable / 2))
    }

    /// 返回实际申请的字节数（结束后已全部释放）。
    static func reclaim(bytes target: UInt64) -> UInt64 {
        guard target > 0 else { return 0 }
        var pointers: [UnsafeMutableRawPointer] = []
        pointers.reserveCapacity(Int(target / UInt64(chunkBytes)) + 1)
        defer {
            for pointer in pointers { free(pointer) }
            malloc_zone_pressure_relief(nil, 0)
        }

        var allocated: UInt64 = 0
        while allocated < target {
            guard let pointer = malloc(chunkBytes) else { break }
            memset(pointer, 0, chunkBytes)
            pointers.append(pointer)
            allocated += UInt64(chunkBytes)
        }
        return allocated
    }
}
