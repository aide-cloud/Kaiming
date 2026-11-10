import CoreGraphics
import Foundation

/// 长截图的滚动方式。
enum LongScreenshotMode: String, Sendable {
    case automatic
    case manual

    var title: String {
        switch self {
        case .automatic: "自动滚动拼接"
        case .manual: "手动滚动拼接"
        }
    }
}

/// 行指纹：对每一行的像素按固定步长采样后做 FNV-1a 哈希。
///
/// 不依赖 AppKit，可以用合成图像独立验证；索引 0 始终是图像**顶部**行。
struct RowAverage: Equatable, Sendable {
    let red: Int
    let green: Int
    let blue: Int
}

struct RowFingerprints: Sendable {
    let hashes: [UInt64]
    let averages: [RowAverage]
}

enum RowFingerprint {
    static let defaultSampleStep = 4

    /// 逐行计算「精确哈希 + 颜色均值」。颜色均值用于手动滚动时的容差匹配。
    static func fingerprints(
        of image: CGImage,
        sampleStep: Int = defaultSampleStep
    ) -> RowFingerprints? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raw = context.data else { return nil }
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = context.bytesPerRow
        let step = max(1, sampleStep)

        var hashes: [UInt64] = []
        var averages: [RowAverage] = []
        hashes.reserveCapacity(height)
        averages.reserveCapacity(height)
        for topRow in 0..<height {
            // CGBitmapContext 的内存第 0 行对应图像顶部行（与绘制坐标 y 轴方向相反）。
            let rowStart = topRow * bytesPerRow
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            var redSum = 0
            var greenSum = 0
            var blueSum = 0
            var samples = 0
            var x = 0
            while x < width {
                let offset = rowStart + x * 4
                let red = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let blue = Int(bytes[offset + 2])
                redSum += red
                greenSum += green
                blueSum += blue
                samples += 1

                hash = (hash ^ UInt64(red)) &* 0x0000_0100_0000_01b3
                hash = (hash ^ UInt64(green)) &* 0x0000_0100_0000_01b3
                hash = (hash ^ UInt64(blue)) &* 0x0000_0100_0000_01b3
                hash = (hash ^ UInt64(bytes[offset + 3])) &* 0x0000_0100_0000_01b3
                x += step
            }
            hashes.append(hash)
            averages.append(
                RowAverage(
                    red: samples > 0 ? redSum / samples : 0,
                    green: samples > 0 ? greenSum / samples : 0,
                    blue: samples > 0 ? blueSum / samples : 0
                )
            )
        }
        return RowFingerprints(hashes: hashes, averages: averages)
    }

    /// 便捷入口：只要精确哈希。
    static func hashes(of image: CGImage, sampleStep: Int = defaultSampleStep) -> [UInt64]? {
        fingerprints(of: image, sampleStep: sampleStep)?.hashes
    }

    /// 在 `previousTail` 的后缀与 `nextTop` 的前缀之间找最大重叠行数。
    ///
    /// - Returns: 重叠行数；找不到返回 nil。要求重叠至少 `minOverlap` 行。
    static func overlap(
        previousTail: [UInt64],
        nextTop: [UInt64],
        maxOverlap: Int,
        minOverlap: Int
    ) -> Int? {
        let upper = min(maxOverlap, previousTail.count, nextTop.count)
        guard upper >= minOverlap, minOverlap > 0 else { return nil }

        var candidate = upper
        while candidate >= minOverlap {
            let previousStart = previousTail.count - candidate
            var matches = true
            var index = 0
            while index < candidate {
                if previousTail[previousStart + index] != nextTop[index] {
                    matches = false
                    break
                }
                index += 1
            }
            if matches {
                return candidate
            }
            candidate -= 1
        }
        return nil
    }
}

extension RowFingerprint {
    /// 容差匹配：用于手动滚动时因亚像素偏移/抗锯齿导致精确行哈希不一致的情况。
    ///
    /// 逐行比较采样颜色均值，允许少量行超过容差；仍然要求最多 `maxMismatchRatio` 的行不匹配。
    static func tolerantOverlap(
        previousTail: [RowAverage],
        nextTop: [RowAverage],
        maxOverlap: Int,
        minOverlap: Int,
        tolerance: Int = 10,
        maxMismatchRatio: Double = 0.02
    ) -> Int? {
        let upper = min(maxOverlap, previousTail.count, nextTop.count)
        guard upper >= minOverlap, minOverlap > 0 else { return nil }

        var candidate = upper
        while candidate >= minOverlap {
            let allowedMismatches = max(1, Int(Double(candidate) * maxMismatchRatio))
            let previousStart = previousTail.count - candidate
            var mismatches = 0
            var index = 0
            while index < candidate {
                let previous = previousTail[previousStart + index]
                let next = nextTop[index]
                if abs(previous.red - next.red) > tolerance
                    || abs(previous.green - next.green) > tolerance
                    || abs(previous.blue - next.blue) > tolerance {
                    mismatches += 1
                    if mismatches > allowedMismatches {
                        break
                    }
                }
                index += 1
            }
            if mismatches <= allowedMismatches {
                return candidate
            }
            candidate -= 1
        }
        return nil
    }
}

/// 增量拼接器（纯逻辑，不触碰 AppKit / 窗口 / 权限）。
///
/// 每次调用 `append(_:)` 都用行哈希在「已拼接内容的最后若干行」和「新帧顶部」之间
/// 寻找重叠，只把新增的行画进内部画布。画布按需倍增，避免每一步复制整张长图。
/// 固定标题栏（sticky header）会被识别并从后续帧中裁掉。
struct LongScreenshotComposer {
    static let maxHeightPixels = 20_000

    enum AppendResult: Equatable {
        case firstFrame(totalHeight: Int)
        case appended(overlap: Int, added: Int, totalHeight: Int, headerTrimmed: Int)
        case noChange(totalHeight: Int)
        case noOverlap(totalHeight: Int)
        case heightLimit(totalHeight: Int)
        case failed
    }

    private(set) var totalHeight = 0
    private(set) var frameCount = 0
    /// 最近一次检测到的固定标题栏高度（像素），供 UI 提示。
    private(set) var fixedHeaderHeight = 0
    /// 拼接结果的像素宽度（首帧确定）。
    private(set) var pixelWidth = 0

    /// 按需生成当前拼接结果；长图较大时只在需要时合成一次。
    var image: CGImage? {
        guard let canvas, totalHeight > 0 else { return nil }
        guard let fullImage = canvas.makeImage() else { return nil }
        guard fullImage.height > totalHeight else { return fullImage }
        return fullImage.cropping(
            to: CGRect(x: 0, y: 0, width: pixelWidth, height: totalHeight)
        )
    }

    private let maxHeight: Int
    private let minimumOverlap: Int
    private let maximumOverlap: Int
    private let detectFixedHeader: Bool
    private let maxHeaderRows: Int
    private let minHeaderRows: Int

    private var canvas: CGContext?
    /// 内部画布高度，按需倍增，最大为 maxHeight。
    private var canvasHeight = 0
    private var tailHashes: [UInt64] = []
    private var tailAverages: [RowAverage] = []
    private var firstFrameTopHashes: [UInt64] = []
    private var lastFrameSignature: UInt64 = 0

    init(
        maxHeight: Int = LongScreenshotComposer.maxHeightPixels,
        minimumOverlap: Int = 8,
        maximumOverlap: Int = 1_600,
        detectFixedHeader: Bool = true,
        maxHeaderRows: Int = 160,
        minHeaderRows: Int = 20
    ) {
        self.maxHeight = max(64, maxHeight)
        self.minimumOverlap = max(1, minimumOverlap)
        self.maximumOverlap = max(minimumOverlap, maximumOverlap)
        self.detectFixedHeader = detectFixedHeader
        self.maxHeaderRows = max(minHeaderRows, maxHeaderRows)
        self.minHeaderRows = max(4, minHeaderRows)
    }

    /// 追加一帧。只有返回 `.appended` / `.firstFrame` 时内部状态才前进。
    mutating func append(_ frame: CGImage) -> AppendResult {
        guard let fingerprints = RowFingerprint.fingerprints(of: frame) else {
            return .failed
        }
        let frameHashes = fingerprints.hashes
        let signature = Self.signature(of: frameHashes)

        guard canvas != nil, frameCount > 0 else {
            guard begin(with: frame, fingerprints: fingerprints) else { return .failed }
            lastFrameSignature = signature
            return .firstFrame(totalHeight: totalHeight)
        }

        guard frame.width == pixelWidth else {
            return .failed
        }
        if signature == lastFrameSignature {
            return .noChange(totalHeight: totalHeight)
        }

        let headerTrimmed = fixedHeaderHeight(in: frameHashes)
        let contentStart = headerTrimmed
        guard contentStart < frameHashes.count else {
            return .noOverlap(totalHeight: totalHeight)
        }

        let nextTop = Array(
            frameHashes[contentStart..<min(frameHashes.count, contentStart + maximumOverlap)]
        )
        let nextAverages = Array(
            fingerprints.averages[contentStart..<min(fingerprints.averages.count, contentStart + maximumOverlap)]
        )
        let overlap = RowFingerprint.overlap(
            previousTail: tailHashes,
            nextTop: nextTop,
            maxOverlap: maximumOverlap,
            minOverlap: minimumOverlap
        ) ?? RowFingerprint.tolerantOverlap(
            previousTail: tailAverages,
            nextTop: nextAverages,
            maxOverlap: maximumOverlap,
            minOverlap: minimumOverlap
        )
        guard let overlap else {
            return .noOverlap(totalHeight: totalHeight)
        }

        let appendStart = contentStart + overlap
        let added = frame.height - appendStart
        guard added > 0 else {
            lastFrameSignature = signature
            return .noChange(totalHeight: totalHeight)
        }
        guard totalHeight + added <= maxHeight else {
            return .heightLimit(totalHeight: totalHeight)
        }
        guard ensureCanvasHeight(totalHeight + added),
              let canvas,
              let cropped = frame.cropping(
                  to: CGRect(
                      x: 0,
                      y: appendStart,
                      width: frame.width,
                      height: added
                  )
              ) else {
            return .failed
        }

        // 画布是 y 向上的：新内容接在已拼接内容的下方。
        let drawY = CGFloat(canvasHeight - totalHeight - added)
        canvas.draw(
            cropped,
            in: CGRect(x: 0, y: drawY, width: CGFloat(frame.width), height: CGFloat(added))
        )

        totalHeight += added
        frameCount += 1
        if headerTrimmed > 0 {
            fixedHeaderHeight = max(fixedHeaderHeight, headerTrimmed)
        }

        tailHashes.append(contentsOf: frameHashes[appendStart...])
        tailAverages.append(contentsOf: fingerprints.averages[appendStart...])
        if tailHashes.count > maximumOverlap {
            tailHashes.removeFirst(tailHashes.count - maximumOverlap)
        }
        if tailAverages.count > maximumOverlap {
            tailAverages.removeFirst(tailAverages.count - maximumOverlap)
        }
        lastFrameSignature = signature
        return .appended(
            overlap: overlap,
            added: added,
            totalHeight: totalHeight,
            headerTrimmed: headerTrimmed
        )
    }

    // MARK: - 画布

    private mutating func begin(with frame: CGImage, fingerprints: RowFingerprints) -> Bool {
        guard frame.width > 0, frame.height > 0, frame.height <= maxHeight else {
            return false
        }
        let initialHeight = min(maxHeight, max(frame.height, 1_024))
        guard let canvas = Self.makeCanvas(width: frame.width, height: initialHeight) else {
            return false
        }
        canvas.draw(
            frame,
            in: CGRect(x: 0, y: initialHeight - frame.height, width: frame.width, height: frame.height)
        )

        self.canvas = canvas
        canvasHeight = initialHeight
        pixelWidth = frame.width
        totalHeight = frame.height
        frameCount = 1
        firstFrameTopHashes = Array(fingerprints.hashes.prefix(maxHeaderRows))
        tailHashes = Array(fingerprints.hashes.suffix(maximumOverlap))
        tailAverages = Array(fingerprints.averages.suffix(maximumOverlap))
        return true
    }

    /// 保证画布能容纳 `needed` 行；容量按 2 倍增长，复制次数保持摊还 O(log n)。
    private mutating func ensureCanvasHeight(_ needed: Int) -> Bool {
        guard needed <= maxHeight else { return false }
        if needed <= canvasHeight {
            return true
        }
        let newHeight = min(maxHeight, max(needed, max(canvasHeight * 2, 1_024)))
        guard newHeight >= needed,
              let oldCanvas = canvas,
              let oldImage = oldCanvas.makeImage(),
              let newCanvas = Self.makeCanvas(width: pixelWidth, height: newHeight) else {
            return false
        }
        // 旧画布内容顶部对齐；整体搬到新画布顶部，底部留白供后续追加。
        newCanvas.draw(
            oldImage,
            in: CGRect(
                x: 0,
                y: newHeight - canvasHeight,
                width: pixelWidth,
                height: canvasHeight
            )
        )
        canvas = newCanvas
        canvasHeight = newHeight
        return true
    }

    private static func makeCanvas(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        return context
    }

    // MARK: - 行匹配

    /// 固定标题栏检测：新帧顶部与首帧顶部完全一致的行数。
    private func fixedHeaderHeight(in frameHashes: [UInt64]) -> Int {
        guard detectFixedHeader, frameCount > 0, !firstFrameTopHashes.isEmpty else { return 0 }
        // 最多占用新帧的 1/3，避免把正常内容误认成标题栏。
        let limit = min(maxHeaderRows, firstFrameTopHashes.count, frameHashes.count / 3)
        guard limit >= minHeaderRows else { return 0 }

        var matched = 0
        while matched < limit, frameHashes[matched] == firstFrameTopHashes[matched] {
            matched += 1
        }
        guard matched >= minHeaderRows else { return 0 }
        // 全是同一种颜色（例如整块空白）时不当作标题栏，避免误裁内容。
        let first = firstFrameTopHashes[0]
        let hasVariation = firstFrameTopHashes.prefix(matched).contains { $0 != first }
        return hasVariation ? matched : 0
    }

    private static func signature(of hashes: [UInt64]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for row in hashes {
            hash = (hash ^ row) &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
