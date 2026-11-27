import CSwiftMMKV
import Foundation
import SwiftMMKV

// A call to the C interface is never the whole of an expectation: `#expect(f("key"))` is
// written as `#expect(f("key") == true)`. Swift Testing takes a lone call apart and evaluates
// its arguments before making it, by which time the C string that Swift made for a string
// argument, or the pointer it made for an array, no longer points anywhere.

/// A status other than `SWIFTMMKV_OK` from the C interface.
struct CStatusError: Error, Equatable {
  let status: swiftmmkv_status
}

/// A store opened through the C interface.
///
/// The handle is closed by hand, as a binding would close it, and not when this is released:
/// Swift may release a value straight after its last use, which is before the call that the
/// handle was read for has been made.
struct CStore {
  let handle: OpaquePointer

  init(
    id: String = "mmkv.default",
    directory: String = temporaryRootDirectory(),
    mode: swiftmmkv_mode = SWIFTMMKV_MODE_SINGLE_PROCESS,
    configure: (OpaquePointer) -> Void = { _ in }
  ) throws {
    let configuration = swiftmmkv_configuration_create(directory, mode)
    defer { swiftmmkv_configuration_destroy(configuration) }
    swiftmmkv_configuration_set_id(configuration, id)
    configure(configuration)
    var handle: OpaquePointer?
    let status = swiftmmkv_store_open(configuration, &handle)
    guard status == SWIFTMMKV_OK, let handle else { throw CStatusError(status: status) }
    self.handle = handle
  }

  func destroy() {
    swiftmmkv_store_destroy(self.handle)
  }

  /// The keys at or under `prefix`, read by asking for their size and then reading them.
  func keys(under prefix: String, separator: String? = nil) -> [String] {
    var size = 0
    var count = 0
    swiftmmkv_store_keys_under(self.handle, prefix, separator, nil, 0, &size, &count)
    var buffer = [CChar](repeating: 0, count: size)
    swiftmmkv_store_keys_under(self.handle, prefix, separator, &buffer, size, &size, &count)
    let keys = unpacked(buffer)
    precondition(keys.count == count)
    return keys
  }

  /// The string stored under `key`, read the way a binding reads a value whose size it does
  /// not know: by asking for the size, and then reading into a buffer of that size.
  func string(forKey key: String) -> String? {
    var length = 0
    guard swiftmmkv_store_get_string(self.handle, key, nil, 0, &length) else { return nil }
    var buffer = [CChar](repeating: 0, count: length + 1)
    guard
      swiftmmkv_store_get_string(self.handle, key, &buffer, buffer.count, &length),
      length < buffer.count
    else { return nil }
    return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  /// The bytes stored under `key`.
  func bytes(forKey key: String) -> [UInt8]? {
    var count = 0
    guard swiftmmkv_store_value_size(self.handle, key, &count) else { return nil }
    var buffer = [UInt8](repeating: 0, count: count)
    guard
      swiftmmkv_store_get_bytes(self.handle, key, &buffer, buffer.count, &count),
      count == buffer.count
    else { return nil }
    return buffer
  }

  /// The list of strings stored under `key`.
  func strings(forKey key: String) -> [String]? {
    var size = 0
    var count = 0
    guard swiftmmkv_store_get_strings(self.handle, key, nil, 0, &size, &count) else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard
      swiftmmkv_store_get_strings(self.handle, key, &buffer, buffer.count, &size, &count),
      size == buffer.count
    else { return nil }
    let strings = unpacked(buffer)
    return strings.count == count ? strings : nil
  }

  /// Every key in the store.
  func keys() -> [String] {
    var size = 0
    var count = 0
    swiftmmkv_store_keys(self.handle, nil, 0, &size, &count)
    var buffer = [CChar](repeating: 0, count: size)
    swiftmmkv_store_keys(self.handle, &buffer, buffer.count, &size, &count)
    let keys = unpacked(buffer)
    precondition(size == buffer.count && keys.count == count)
    return keys
  }
}

/// `strings` as the C interface takes a list of them: end to end, each followed by a NUL.
func packed(_ strings: [String]) -> [CChar] {
  strings.flatMap(\.utf8CString)
}

/// The strings of a packed list.
func unpacked(_ list: [CChar]) -> [String] {
  list.split(separator: 0, omittingEmptySubsequences: false)
    .dropLast()
    .map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
}

/// A store and a recorder, for a callback that reads the store and records what it read.
final class CReadingContext: Sendable {
  nonisolated(unsafe) let store: OpaquePointer
  let recorder: CCallbackRecorder

  init(store: OpaquePointer, recorder: CCallbackRecorder) {
    self.store = store
    self.recorder = recorder
  }
}

/// Collects what the callbacks of the C interface are called with, as their context.
final class CCallbackRecorder: Sendable {
  private let lock = NSLock()
  nonisolated(unsafe) private var recordedEvents = [String]()
  nonisolated(unsafe) private var recordedReleases = 0

  /// Every call, as a line of text.
  var events: [String] {
    self.lock.withLock { self.recordedEvents }
  }

  /// How often the context was released.
  var releases: Int {
    self.lock.withLock { self.recordedReleases }
  }

  /// Whether the context has been released once, waiting a while for it.
  ///
  /// Logging and integrity failures are shared by the whole process, so another test's store
  /// can be in the middle of calling the callback when it is replaced or cancelled. The context
  /// is then released when that call returns.
  var isReleasedOnce: Bool {
    for _ in 0..<5000 where self.releases == 0 {
      usleep(1000)
    }
    return self.releases == 1
  }

  /// The recorder as a callback's context. The test keeps the recorder alive.
  var context: UnsafeMutableRawPointer {
    Unmanaged.passUnretained(self).toOpaque()
  }

  func record(_ event: String) {
    self.lock.withLock { self.recordedEvents.append(event) }
  }

  private static func from(_ context: UnsafeMutableRawPointer?) -> CCallbackRecorder {
    Unmanaged<CCallbackRecorder>.fromOpaque(context!).takeUnretainedValue()
  }

  static let release: swiftmmkv_context_release = { context in
    let recorder = CCallbackRecorder.from(context)
    recorder.lock.withLock { recorder.recordedReleases += 1 }
  }

  /// Records one event for each batch: `key:<name>` for each of its keys and `external` if it
  /// is external, joined with commas.
  static let onChange: swiftmmkv_change_callback = { context, batch in
    let batch = batch.pointee
    var parts = [String]()
    if batch.key_count > 0, let keys = batch.keys {
      parts = (0..<batch.key_count).map { "key:\(String(cString: keys[$0]))" }
    } else if batch.key_count > 0 || batch.keys != nil {
      parts = ["unexpected"]
    }
    if batch.is_external {
      parts.append("external")
    }
    CCallbackRecorder.from(context).record(parts.joined(separator: ","))
  }

  /// Records `<level> <file>:<line> <function> <text>`.
  static let onLog: swiftmmkv_log_callback = { context, level, text, file, function, line in
    CCallbackRecorder.from(context)
      .record(
        "\(level) \(String(cString: file)):\(line) \(String(cString: function)) "
          + String(cString: text)
      )
  }

  /// Records `<kind> <id>`.
  static let onIntegrityFailure: swiftmmkv_integrity_failure_callback = { context, id, kind in
    CCallbackRecorder.from(context).record("\(kind) \(String(cString: id))")
  }
}
