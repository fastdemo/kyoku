import Foundation
import os

/// Centralized logging. Use per-subsystem loggers, never print() in app code.
struct KyokuLogger {
    private let log: OSLog

    init(subsystem: String, category: String = "general") {
        self.log = OSLog(
            subsystem: "com.kyoku.app.\(subsystem)",
            category: category
        )
    }

    func info(_ message: String) {
        os_log("%{public}@", log: log, type: .info, message)
    }

    func error(_ message: String) {
        os_log("%{public}@", log: log, type: .error, message)
    }

    func debug(_ message: String) {
        os_log("%{public}@", log: log, type: .debug, message)
    }
}
