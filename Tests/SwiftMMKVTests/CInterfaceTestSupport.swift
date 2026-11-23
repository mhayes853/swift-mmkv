import CSwiftMMKV
import Foundation
import SwiftMMKV

// A call to the C interface is never the whole of an expectation: `#expect(f("key"))` is
// written as `#expect(f("key") == true)`. Swift Testing takes a lone call apart and evaluates
// its arguments before making it, by which time the C string that Swift made for a string
// argument, or the pointer it made for an array, no longer points anywhere.

/// A constant of the C interface as the type its functions take and return. Swift imports the
/// constants of an unnamed C enum with a type of its own choosing.
func code(_ constant: some BinaryInteger) -> Int32 {
  Int32(constant)
}

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
    mode: some BinaryInteger = SWIFTMMKV_MODE_SINGLE_PROCESS,
    configure: (OpaquePointer) -> Void = { _ in }
  ) throws {
    let configuration = swiftmmkv_configuration_create(directory, code(mode))
    defer { swiftmmkv_configuration_destroy(configuration) }
    swiftmmkv_configuration_set_id(configuration, id)
    configure(configuration)
    var handle: OpaquePointer?
    let status = swiftmmkv_store_open(configuration, &handle)
    guard status == code(SWIFTMMKV_OK), let handle else { throw CStatusError(status: status) }
    self.handle = handle
  }

  func close() {
    swiftmmkv_store_close(self.handle)
  }

  /// The string stored under `key`, read and freed through the C interface.
  func string(forKey key: String) -> String? {
    var value: UnsafeMutablePointer<CChar>?
    guard swiftmmkv_store_get_string(self.handle, key, &value, nil), let value else { return nil }
    defer { swiftmmkv_free(value) }
    return String(cString: value)
  }
}

/// Calls `body` with `strings` as a C array of C strings.
func withCStrings<R>(
  _ strings: [String],
  _ body: (UnsafePointer<UnsafePointer<CChar>>?, Int) -> R
) -> R {
  let copies = strings.map { UnsafePointer(strdup($0)!) }
  defer { copies.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
  return copies.withUnsafeBufferPointer { body($0.baseAddress, $0.count) }
}

/// The strings of a list from the C interface, which this frees.
func takeStrings(_ list: OpaquePointer) -> [String] {
  defer { swiftmmkv_string_list_free(list) }
  return (0..<swiftmmkv_string_list_count(list))
    .map {
      String(cString: swiftmmkv_string_list_get(list, $0))
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

  /// Records `key:<name>` or `external`.
  static let onChange: swiftmmkv_change_callback = { context, kind, key in
    if kind == code(SWIFTMMKV_CHANGE_KEY), let key {
      CCallbackRecorder.from(context).record("key:\(String(cString: key))")
    } else if kind == code(SWIFTMMKV_CHANGE_EXTERNAL), key == nil {
      CCallbackRecorder.from(context).record("external")
    } else {
      CCallbackRecorder.from(context).record("unexpected")
    }
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
