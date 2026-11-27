import AppKit
import Combine
import Foundation

/// 系统资源模块的唯一入口：拥有采样循环、应用内存聚合与清理动作。
///
/// 采样全部在后台线程完成，只有最终的值类型快照回到主线程，避免菜单栏面板
/// 在打开时被 `sysctl` / `proc_pidpath` / IOKit 调用卡住。
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    // MARK: 采样结果

    @Published private(set) var memory: MemorySnapshot = .empty
    @Published private(set) var cpu: CPUSnapshot = .empty
    @Published private(set) var disk: DiskSnapshot = .empty
    @Published private(set) var network: NetworkSnapshot = .empty
    @Published private(set) var sensors: SensorSnapshot = .empty
    @Published private(set) var apps: [AppMemoryRow] = []
    @Published private(set) var networkHistory: [NetworkPoint] = []
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var isRefreshing = false

    /// 系统身份只读取一次（芯片、系统版本、物理内存）。
    let identity: SystemIdentity = SystemSampler.identity()

    // MARK: 清理状态

    @Published private(set) var cacheScan: CacheScanResult?
    @Published private(set) var selectedKinds: Set<CacheKind> = Set(CacheKind.allCases)
    @Published private(set) var isScanningCaches = false
    @Published private(set) var isCleaningCaches = false
    @Published private(set) var isReleasingMemory = false

    // MARK: 内部状态

    private var loopTask: Task<Void, Never>?
    private let networkCounter = NetworkCounter()
    private let cpuCounter = CPUCounter()
    private let sensorReader = SensorReader()
    private let iconCache = NSCache<NSString, NSImage>()
    private var runningAppsByPath: [String: NSRunningApplication] = [:]
    private var runningAppsStamp: TimeInterval = 0
    private let historyLimit = 60
    private let processLimit = 5

    /// 面板当前是否可见；面板打开时用 2 秒全量采样，收起后按状态栏需要降频。
    private var panelActive = false
    /// 状态栏选中的指标；为空且面板收起时完全停止采样。
    private var statusMetrics: Set<SystemStatusMetric> = []
    private var settingsCancellable: AnyCancellable?

    private init() {
        statusMetrics = SettingsStore.shared.statusBarMetrics
        settingsCancellable = SettingsStore.shared.$statusBarMetrics
            .sink { [weak self] metrics in
                MainActor.assumeIsolated {
                    self?.updateStatusMetrics(metrics)
                }
            }
        restartLoop()
    }

    // MARK: 生命周期

    /// 面板出现：切换为 2 秒全量采样（含进程列表）。
    func startMonitoring() {
        guard !panelActive else { return }
        panelActive = true
        // 长时间未打开面板时清掉上一轮的陈旧曲线，避免把旧速率当成实时值。
        if let lastUpdate, Date().timeIntervalSince(lastUpdate) > 30 {
            networkHistory.removeAll()
        }
        restartLoop()
    }

    /// 面板收起：状态栏仍有选中指标时降频到 3 秒、跳过进程扫描；否则完全停止。
    func stopMonitoring() {
        guard panelActive else { return }
        panelActive = false
        restartLoop()
    }

    private var currentInterval: UInt64 {
        panelActive ? 2_000_000_000 : 3_000_000_000
    }

    private func restartLoop() {
        loopTask?.cancel()
        loopTask = nil
        guard panelActive || !statusMetrics.isEmpty else { return }

        loopTask = Task { [weak self] in
            await self?.refreshNow(full: self?.panelActive ?? false)
            // CPU tick 与网卡计数都需要上一帧才能算差分；首帧后快速补一帧。
            try? await Task.sleep(nanoseconds: 600_000_000)
            while !Task.isCancelled {
                await self?.refreshNow(full: self?.panelActive ?? false)
                try? await Task.sleep(nanoseconds: self?.currentInterval ?? 3_000_000_000)
            }
        }
    }

    private func updateStatusMetrics(_ metrics: Set<SystemStatusMetric>) {
        let neededBefore = panelActive || !statusMetrics.isEmpty
        statusMetrics = metrics
        let neededAfter = panelActive || !metrics.isEmpty
        if neededBefore != neededAfter {
            restartLoop()
        }
    }

    func refreshNow(full: Bool = true) async {
        // 面板、状态栏循环与清理动作可能同时请求刷新；等当前一帧结束再采样，
        // 避免调用方拿到空的初始值。
        while isRefreshing {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let networkCounter = self.networkCounter
        let cpuCounter = self.cpuCounter
        let sensorReader = self.sensorReader
        let needsSensors = full
            || statusMetrics.contains(.cpuTemperature)
            || statusMetrics.contains(.fanSpeed)
        let bundle = await Task.detached(priority: .utility) {
            let network = networkCounter.sample()
            let cpu = cpuCounter.sample()
            let sensors = needsSensors ? await sensorReader.sample() : nil
            return SampleBundle(
                memory: SystemSampler.memory(),
                cpu: cpu,
                disk: SystemSampler.disk(),
                network: network,
                sensors: sensors,
                processes: full ? SystemSampler.appGroups() : nil
            )
        }.value

        apply(bundle)
    }

    private func apply(_ bundle: SampleBundle) {
        memory = bundle.memory
        cpu = bundle.cpu
        disk = bundle.disk
        network = bundle.network
        if let sensors = bundle.sensors { self.sensors = sensors }
        if let processes = bundle.processes { apps = makeAppRows(from: processes) }

        let now = Date()
        networkHistory.append(
            NetworkPoint(
                time: now,
                download: bundle.network.downloadBytesPerSecond,
                upload: bundle.network.uploadBytesPerSecond
            )
        )
        if networkHistory.count > historyLimit {
            networkHistory.removeFirst(networkHistory.count - historyLimit)
        }
        lastUpdate = now
    }

    // MARK: 应用内存聚合

    private func makeAppRows(from samples: [AppProcessSample]) -> [AppMemoryRow] {
        refreshRunningAppsIfNeeded()
        var rows: [AppMemoryRow] = []
        rows.reserveCapacity(samples.count)

        for sample in samples {
            guard sample.bytes >= 8 * 1024 * 1024 else { continue }
            let app = runningAppsByPath[sample.bundlePath]
            let fallbackName = URL(fileURLWithPath: sample.bundlePath)
                .deletingPathExtension()
                .lastPathComponent
            rows.append(
                AppMemoryRow(
                    id: sample.bundlePath,
                    name: app?.localizedName ?? fallbackName,
                    bytes: sample.bytes,
                    icon: icon(for: sample.bundlePath)
                )
            )
        }

        rows.sort { $0.bytes > $1.bytes }
        guard rows.count > processLimit else { return rows }

        let top = Array(rows.prefix(processLimit))
        let rest = rows.dropFirst(processLimit)
        let restBytes = rest.reduce(UInt64(0)) { $0 + $1.bytes }
        let other = AppMemoryRow(
            id: "__other__",
            name: "其他 \(rest.count) 个应用",
            bytes: restBytes,
            icon: NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil),
            isOther: true
        )
        return top + [other]
    }

    private func refreshRunningAppsIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - runningAppsStamp > 5 || runningAppsByPath.isEmpty else { return }
        runningAppsStamp = now
        var map: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let path = app.bundleURL?.standardizedFileURL.path else { continue }
            if map[path] == nil { map[path] = app }
        }
        runningAppsByPath = map
    }

    private func icon(for path: String) -> NSImage? {
        if let cached = iconCache.object(forKey: path as NSString) { return cached }
        let source = NSWorkspace.shared.icon(forFile: path)
        let icon = source.copy() as? NSImage ?? source
        icon.size = NSSize(width: 18, height: 18)
        iconCache.setObject(icon, forKey: path as NSString)
        return icon
    }

    // MARK: 垃圾扫描 / 清理

    func scanCachesIfNeeded() {
        guard cacheScan == nil, !isScanningCaches, !isCleaningCaches else { return }
        scanCaches()
    }

    func scanCaches() {
        guard !isScanningCaches, !isCleaningCaches else { return }
        isScanningCaches = true
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { CacheCleaner.scan() }.value
            guard let self else { return }
            self.cacheScan = result
            self.isScanningCaches = false
            Log.system.info("Cache scan finished, bytes=\(result.totalBytes, privacy: .public)")
        }
    }

    func isSelected(_ kind: CacheKind) -> Bool { selectedKinds.contains(kind) }

    func setSelected(_ selected: Bool, for kind: CacheKind) {
        if selected {
            selectedKinds.insert(kind)
        } else {
            selectedKinds.remove(kind)
        }
    }

    /// 当前勾选项对应的可清理字节数。
    var selectedCacheBytes: UInt64 {
        guard let cacheScan else { return 0 }
        return cacheScan.categories
            .filter { selectedKinds.contains($0.kind) }
            .reduce(UInt64(0)) { $0 + $1.bytes }
    }

    func cleanSelectedCaches() async -> CacheCleanOutcome {
        let kinds = selectedKinds
        guard !kinds.isEmpty, !isCleaningCaches else { return .empty }
        isCleaningCaches = true
        let outcome = await Task.detached(priority: .userInitiated) {
            CacheCleaner.clean(kinds: kinds)
        }.value
        await refreshNow()

        // 先立即把已清理类别归零，再后台重扫；避免一次清理后按钮转圈十几秒。
        if let scan = cacheScan {
            let categories = scan.categories.map { category in
                kinds.contains(category.kind)
                    ? CacheCategoryResult(kind: category.kind, bytes: 0, itemCount: 0)
                    : category
            }
            cacheScan = CacheScanResult(categories: categories, scannedAt: Date())
        }
        isCleaningCaches = false
        scanCaches()
        Log.system.info("Cache clean finished, freed=\(outcome.freedBytes, privacy: .public)")
        return outcome
    }

    // MARK: 内存释放

    func releaseMemory() async -> MemoryReleaseResult {
        guard !isReleasingMemory else { return .empty }
        isReleasingMemory = true
        defer { isReleasingMemory = false }

        let target = MemoryReclaimer.targetBytes(reclaimable: memory.reclaimableBytes, pressure: memory.pressure)
        let before = memory.usedBytes
        let allocated = await Task.detached(priority: .userInitiated) {
            MemoryReclaimer.reclaim(bytes: target)
        }.value
        await refreshNow()

        let freed = before > memory.usedBytes ? before - memory.usedBytes : 0
        Log.system.info("Memory release requested=\(target, privacy: .public) freed=\(freed, privacy: .public)")
        return MemoryReleaseResult(freedBytes: freed, allocatedBytes: allocated)
    }
}

// MARK: - 后台采样结果

private struct SampleBundle: Sendable {
    var memory: MemorySnapshot
    var cpu: CPUSnapshot
    var disk: DiskSnapshot
    var network: NetworkSnapshot
    /// 状态栏没有温度 / 风扇指标且面板收起时为 nil，避免无谓的 IOKit 采样。
    var sensors: SensorSnapshot?
    /// 面板收起时为 nil；此时保留上一次的应用列表。
    var processes: [AppProcessSample]?
}
