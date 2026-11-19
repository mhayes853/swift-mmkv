/// What MMKV logs, and where those messages go.
///
/// MMKV logs when something goes wrong with a store's files, such as a file that fails its
/// integrity check or cannot be opened. Logging is shared by every store in the process: there
/// is one minimum level and one destination.
///
/// By default, warnings and errors are printed to standard error, or to the system log on
/// Android. With the `Logging` trait they go to swift-log instead, through `MMKVLog.logger`. To
/// send them elsewhere, install a handler:
///
/// ```swift
/// MMKVLog.setHandler { message in
///   crashReporter.addBreadcrumb("\(message.level): \(message.text)")
/// }
/// ```
public enum MMKVLog {
  /// How severe a message is.
  public enum Level: Int, Sendable, Hashable, CaseIterable {
    /// What MMKV is doing, such as loading a file or growing one.
    case info = 1

    /// Something unexpected that MMKV carried on from.
    case warning

    /// A failure, such as a file that cannot be opened or that fails its integrity check.
    case error
  }

  /// A message MMKV logged.
  public struct Message: Sendable, Hashable {
    /// How severe the message is.
    public let level: Level

    /// The message, which names the store it is about when it is about one.
    public let text: String

    /// The name of the MMKV source file that logged the message, such as `MMKV_IO.cpp`.
    public let file: String

    /// The MMKV function that logged the message.
    public let function: String

    /// The line of ``file`` that logged the message.
    public let line: Int

    /// Creates a message.
    public init(level: Level, text: String, file: String, function: String, line: Int) {
      self.level = level
      self.text = text
      self.file = file
      self.function = function
      self.line = line
    }
  }

  /// The least severe level that is logged, or `nil` to log nothing. It starts as
  /// ``Level/warning``.
  ///
  /// Messages below this level are dropped before they are put together, so they cost nothing.
  public static var minimumLevel: Level? {
    get { LogSink.minimumLevel }
    set { LogSink.minimumLevel = newValue }
  }

  /// Sends every message to `handler` instead of where messages go by default.
  ///
  /// The handler runs on the thread that logged the message, usually while MMKV holds the lock
  /// of the store the message is about. It must not read or write a store.
  ///
  /// - Parameter handler: Receives each message at or above ``minimumLevel``, or `nil` to
  ///   send messages where they go by default again.
  public static func setHandler(_ handler: (@Sendable (Message) -> Void)?) {
    LogSink.setHandler(handler)
  }
}

extension MMKVLog.Level: Comparable {
  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

extension MMKVLog.Level: CustomStringConvertible {
  public var description: String {
    switch self {
    case .info: "info"
    case .warning: "warning"
    case .error: "error"
    }
  }
}
