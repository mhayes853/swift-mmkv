import CSwiftMMKVCore

#if Logging
  import Logging
#endif

/// Where the core's log messages go, for ``MMKVLog``.
///
/// The shim prints messages itself until a callback is installed, so a callback is only
/// installed while there is somewhere in Swift to send them: a handler, or with the `Logging`
/// trait a logger.
enum LogSink {
  typealias Handler = @Sendable (MMKVLog.Message) -> Void

  private struct Destination {
    var handler: Handler?
    #if Logging
      var logger: Logger?

      /// The logger is made when it is first needed, so that it is made by whatever logging
      /// system the app has bootstrapped by then.
      mutating func resolveLogger() -> Logger {
        if let logger = self.logger { return logger }
        let logger = Logger(label: "swift-mmkv")
        self.logger = logger
        return logger
      }
    #endif
  }

  private static let destination = Lock(Destination())

  static var minimumLevel: MMKVLog.Level? {
    get { MMKVLog.Level(rawValue: Int(mmkv_log_level())) }
    set { mmkv_set_log_level(Int32(newValue?.rawValue ?? Int(MMKV_LOG_NONE))) }
  }

  static func setHandler(_ handler: Handler?) {
    self.destination.withLock { destination in
      destination.handler = handler
      #if Logging
        mmkv_set_log_callback(self.callback)
      #else
        mmkv_set_log_callback(handler == nil ? nil : self.callback)
      #endif
    }
  }

  /// Sends messages to the logger when nothing else has been asked for. Called before the
  /// core is first used, and does nothing without the `Logging` trait.
  static func prepare() {
    #if Logging
      _ = self.installLoggerCallback
    #endif
  }

  #if Logging
    static var logger: Logger {
      get { self.destination.withLock { $0.resolveLogger() } }
      set {
        self.prepare()
        self.destination.withLock { $0.logger = newValue }
      }
    }

    private static let installLoggerCallback: Void = {
      mmkv_set_log_callback(LogSink.callback)
    }()
  #endif

  private static let callback: mmkv_log_callback = { level, file, line, function, text in
    guard let level = MMKVLog.Level(rawValue: Int(level)) else { return }
    let message = MMKVLog.Message(
      level: level,
      text: String(text),
      file: String(file),
      function: String(function),
      line: Int(line)
    )
    #if Logging
      let (handler, logger) = LogSink.destination.withLock { destination in
        (destination.handler, destination.handler == nil ? destination.resolveLogger() : nil)
      }
      if let handler {
        handler(message)
      } else if let logger {
        logger.log(
          level: Logger.Level(message.level),
          "\(message.text)",
          source: "MMKV",
          file: message.file,
          function: message.function,
          line: UInt(message.line)
        )
      }
    #else
      let handler = LogSink.destination.withLock { $0.handler }
      handler?(message)
    #endif
  }
}

extension String {
  fileprivate init(_ bytes: mmkv_bytes) {
    self.init(
      decoding: UnsafeRawBufferPointer(start: bytes.bytes, count: bytes.count),
      as: UTF8.self
    )
  }
}
