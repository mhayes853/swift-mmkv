#if Logging
  import Logging

  extension MMKVLog {
    /// The logger MMKV's messages are sent to, unless a handler has been set with
    /// ``setHandler(_:)``.
    ///
    /// It starts as `Logger(label: "swift-mmkv")`, made when the first message is logged or
    /// when this is first read. To have that logger made by your logging system, bootstrap the
    /// system before using a store, or assign a logger of your own here.
    ///
    /// ```swift
    /// MMKVLog.logger = Logger(label: "com.example.storage")
    /// MMKVLog.logger.logLevel = .info
    /// ```
    ///
    /// Each message is logged at the matching level with the source `"MMKV"`, and with the
    /// MMKV source file, function and line that logged it.
    ///
    /// ## Levels
    ///
    /// Setting this property, or anything in it, also sets ``minimumLevel`` to match the
    /// logger's level, so that MMKV does not put together messages the logger would drop. Set
    /// ``minimumLevel`` afterwards to choose differently. A message has to pass both levels to
    /// be logged.
    public static var logger: Logger {
      get {
        LogSink.logger
      }
      set {
        LogSink.logger = newValue
        self.minimumLevel = Level(newValue.logLevel)
      }
    }
  }

  extension MMKVLog.Level {
    /// The least severe MMKV level that a logger at `level` would log.
    ///
    /// MMKV has nothing below ``info``, and nothing above ``error``.
    public init(_ level: Logger.Level) {
      switch level {
      case .trace, .debug, .info, .notice: self = .info
      case .warning: self = .warning
      case .error, .critical: self = .error
      }
    }
  }

  extension Logger.Level {
    /// The level an MMKV message of `level` is logged at.
    public init(_ level: MMKVLog.Level) {
      switch level {
      case .info: self = .info
      case .warning: self = .warning
      case .error: self = .error
      }
    }
  }
#endif
