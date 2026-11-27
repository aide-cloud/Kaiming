import Darwin
import Foundation

enum MachSupport {
    /// `mach_task_self_` 是 Darwin 导入的全局变量，Swift 6 不允许在并发上下文中直接读取。
    /// 这里在运行时解析符号并缓存端口值，语义与 `mach_task_self()` 完全一致。
    static let taskPort: mach_port_t = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "mach_task_self_") else {
            return 0
        }
        return symbol.assumingMemoryBound(to: mach_port_t.self).pointee
    }()
}
