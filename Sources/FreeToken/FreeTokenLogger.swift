import OSLog

extension FreeToken {
    /// Global logger function for centralized logging
    func logger(_ message: String, _ level: FreeTokenLogger.LogLevel) {
        FreeTokenLogger.shared.log(message, level: level)
    }
    
    /// Logger class to handle centralized logging with configurable verbosity levels
    public class FreeTokenLogger: @unchecked Sendable {
        public enum LogLevel: Int {
            case error = 0
            case warning = 1
            case info = 2
            case debug = 3
        }
        
        public static let shared = FreeTokenLogger()
        
        private let osLogger: Logger
        private var currentLogLevel: LogLevel = .info
        
        private init() {
            self.osLogger = Logger(subsystem: "com.fractionallabs.FreeToken", category: "Client")
        }
        
        /// Configure the logger with a specific verbosity level
        public func configure(logLevel: LogLevel) {
            self.currentLogLevel = logLevel
        }
        
        /// Log a message with a specific log level
        /// Only shows messages that are equal to or above the current log level
        public func log(_ message: String, level: LogLevel) {
            guard level.rawValue <= currentLogLevel.rawValue else { return }
            
            switch level {
            case .error:
                osLogger.error("[FreeToken] \(message)")
            case .warning:
                osLogger.warning("[FreeToken] \(message)")
            case .info:
                osLogger.info("[FreeToken] \(message)")
            case .debug:
                osLogger.debug("[FreeToken] \(message)")
            }
        }
    }
}
