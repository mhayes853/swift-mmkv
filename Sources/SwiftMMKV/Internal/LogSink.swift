import CSwiftMMKVCore

/// Where the core's log messages go, for ``MMKVLog``.
///
/// The shim prints messages itself until a callback is installed, so a callback is only
/// installed while there is somewhere in Swift to send them.
enum LogSink {
  typealias Handler = @Sendable (MMKVLog.Message) -> Void

  private static let handler = Lock<Handler?>(nil)

  static var minimumLevel: MMKVLog.Level? {
    get { MMKVLog.Level(rawValue: Int(mmkv_log_level())) }
    set { mmkv_set_log_level(Int32(newValue?.rawValue ?? Int(MMKV_LOG_NONE))) }
  }

  static func setHandler(_ handler: Handler?) {
    self.handler.withLock { current in
      current = handler
      mmkv_set_log_callback(handler == nil ? nil : self.callback)
    }
  }

  private static let callback: mmkv_log_callback = { level, file, line, function, text in
    guard
      let level = MMKVLog.Level(rawValue: Int(level)),
      let handler = LogSink.handler.withLock({ $0 })
    else { return }
    handler(
      MMKVLog.Message(
        level: level,
        text: String(text),
        file: String(file),
        function: String(function),
        line: Int(line)
      )
    )
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
