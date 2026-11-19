/// Writes MMKV's warnings and errors to standard error, as the package's handler for the C++ core
/// does, so that a problem with a store's files is visible while debugging.
package enum Log {
  package static func warning(
    _ message: @autoclosure () -> String,
    function: StaticString = #function
  ) {
    Self.emit("warning", message(), function: function)
  }

  package static func error(
    _ message: @autoclosure () -> String,
    function: StaticString = #function
  ) {
    Self.emit("error", message(), function: function)
  }

  private static func emit(_ level: String, _ message: String, function: StaticString) {
    var line = "[SwiftMMKV] <\(function)> \(level): \(message)\n"
    line.withUTF8 { _ = write(2, $0.baseAddress, $0.count) }
  }
}
