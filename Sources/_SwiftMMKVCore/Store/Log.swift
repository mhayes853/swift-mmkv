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
    writeToStandardError("[SwiftMMKV] <\(function)> \(level): \(message)\n")
  }

}

private func writeToStandardError(_ line: String) {
  var line = line
  line.withUTF8 { utf8 in
    guard let base = utf8.baseAddress else { return }
    _ = write(2, base, utf8.count)
  }
}
