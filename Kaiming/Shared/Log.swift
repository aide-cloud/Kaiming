import Foundation
import os

/// 统一日志入口。所有模块共用同一 subsystem，方便用 `log stream --predicate` 过滤。
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.kaiming.app"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let screenshot = Logger(subsystem: subsystem, category: "screenshot")
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    static let markdown = Logger(subsystem: subsystem, category: "markdown")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
}
