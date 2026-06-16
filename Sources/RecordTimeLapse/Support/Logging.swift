import Foundation
import os

/// Centralised os.Logger categories. Filter in Console.app with subsystem
/// `com.recvient.RecordTimeLapse`.
enum Log {
    private static let subsystem = "com.recvient.RecordTimeLapse"

    static let app       = Logger(subsystem: subsystem, category: "app")
    static let capture   = Logger(subsystem: subsystem, category: "capture")
    static let encode    = Logger(subsystem: subsystem, category: "encode")
    static let segment   = Logger(subsystem: subsystem, category: "segment")
    static let power     = Logger(subsystem: subsystem, category: "power")
    static let disk      = Logger(subsystem: subsystem, category: "disk")
    static let recovery  = Logger(subsystem: subsystem, category: "recovery")
}
