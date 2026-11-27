import AppKit

/// 把「开明图标 + 指标图标 + 数值」绘制成一张模板 NSImage。
///
/// `MenuBarExtra` 的 label 在 NSStatusItem 中不会稳定渲染内联 SF Symbol，
/// 多子视图 HStack 也只会按第一项测宽；绘制成单张图片可以同时解决图标、
/// 动态宽度和深浅色适配（`isTemplate = true`）。
@MainActor
enum MenuBarStatusImage {
    private static let height: CGFloat = 18
    private static let logoSize: CGFloat = 16
    private static let iconSize: CGFloat = 11
    private static let sidePadding: CGFloat = 1
    private static let groupGap: CGFloat = 5
    private static let iconTextGap: CGFloat = 1.5

    private struct Item {
        let metric: SystemStatusMetric
        let text: String
        let slotWidth: CGFloat
    }

    static func make(metrics: [SystemStatusMetric], monitor: SystemMonitor) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]

        func textWidth(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: attributes).width
        }

        let items = metrics.map { metric -> Item in
            Item(
                metric: metric,
                text: valueText(for: metric, monitor: monitor),
                slotWidth: slotWidth(for: metric, width: textWidth) + 1
            )
        }

        let totalWidth = sidePadding * 2
            + logoSize
            + items.reduce(0) { $0 + groupGap + iconSize + iconTextGap + $1.slotWidth }
        let size = NSSize(width: max(totalWidth, 18), height: height)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixelWidth = Int((size.width * scale).rounded(.up))
        let pixelHeight = Int((size.height * scale).rounded(.up))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage(size: size)
        }

        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.cgContext.scaleBy(x: scale, y: scale)

        var x = sidePadding
        if let logo = NSImage(named: "MenuBarIcon") {
            let logoRect = NSRect(x: x, y: (height - logoSize) / 2, width: logoSize, height: logoSize)
            logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        x += logoSize

        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        for item in items {
            x += groupGap

            if let icon = NSImage(systemSymbolName: item.metric.symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfiguration) {
                let iconRect = NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            x += iconSize + iconTextGap

            let textSize = (item.text as NSString).size(withAttributes: attributes)
            let textRect = NSRect(
                x: x,
                y: (height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (item.text as NSString).draw(in: textRect, withAttributes: attributes)
            x += item.slotWidth
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    private static func valueText(for metric: SystemStatusMetric, monitor: SystemMonitor) -> String {
        switch metric {
        case .cpuTemperature:
            SystemFormat.compactTemperature(monitor.sensors.cpuTemperature)
        case .cpuUsage:
            SystemFormat.percent(monitor.cpu.usage)
        case .fanSpeed:
            monitor.sensors.fanRPM.map { String(format: "%.0f", $0) } ?? "—"
        case .memoryUsage:
            "\(monitor.memory.usedPercent)%"
        case .diskUsage:
            "\(monitor.disk.usedPercent)%"
        case .networkDownload:
            SystemFormat.compactRate(monitor.network.downloadBytesPerSecond)
        case .networkUpload:
            SystemFormat.compactRate(monitor.network.uploadBytesPerSecond)
        }
    }

    /// 每个指标预留固定文本宽度，数值变化时状态项不会左右跳动。
    private static func slotWidth(for metric: SystemStatusMetric, width: (String) -> CGFloat) -> CGFloat {
        switch metric {
        case .cpuTemperature:
            width("100°")
        case .cpuUsage, .memoryUsage, .diskUsage:
            width("100%")
        case .fanSpeed:
            width("9999")
        case .networkDownload, .networkUpload:
            max(width("999B"), width("999K"), width("9.9M"))
        }
    }
}
