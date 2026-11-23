import CSwiftMMKV
import SwiftMMKV

// MARK: - Handles

// Every opaque type of the header is a pointer to a retained Swift object. C sees them as
// distinct types, but Swift imports each as `OpaquePointer`, so the functions here name the
// class they expect.

extension OpaquePointer {
  /// A handle that owns a reference to `object`, to be given up with ``release(as:)``.
  init(retaining object: some AnyObject) {
    self.init(Unmanaged.passRetained(object).toOpaque())
  }

  /// The object behind a handle, which the handle goes on owning.
  func object<T: AnyObject>(_ type: T.Type = T.self) -> T {
    Unmanaged<T>.fromOpaque(UnsafeRawPointer(self)).takeUnretainedValue()
  }

  /// Gives up the reference a handle owns, after which the handle is invalid.
  func release<T: AnyObject>(as type: T.Type) {
    Unmanaged<T>.fromOpaque(UnsafeRawPointer(self)).release()
  }

  /// The store behind a `swiftmmkv_store`.
  var store: MMKVStore {
    self.object(MMKVStore.self)
  }
}

// MARK: - Version

@c @implementation
public func swiftmmkv_abi_version() -> UInt32 {
  UInt32(SWIFTMMKV_ABI_VERSION)
}

// MARK: - Strings

/// Copies `string` into memory the caller of the C interface owns.
///
/// - Returns: The NUL-terminated copy, and its length in bytes without the terminator.
func makeCString(_ string: String) -> (pointer: UnsafeMutablePointer<CChar>, length: Int) {
  var string = string
  return string.withUTF8 { utf8 in
    let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count + 1)
    UnsafeMutableRawBufferPointer(start: pointer, count: utf8.count)
      .copyMemory(
        from: UnsafeRawBufferPointer(utf8)
      )
    pointer[utf8.count] = 0
    return (pointer, utf8.count)
  }
}

/// The strings of a C array of C strings.
func makeStrings(_ strings: UnsafePointer<UnsafePointer<CChar>>?, _ count: Int) -> [String] {
  guard let strings else { return [] }
  return UnsafeBufferPointer(start: strings, count: count).map { String(cString: $0) }
}

/// A copy of a run of bytes.
func makeBytes(_ bytes: UnsafeRawPointer?, _ count: Int) -> [UInt8] {
  guard let bytes else { return [] }
  return Array(UnsafeRawBufferPointer(start: bytes, count: count))
}

// MARK: - Memory

@c @implementation
public func swiftmmkv_free(_ pointer: UnsafeMutableRawPointer?) {
  pointer?.deallocate()
}

/// The object behind a `swiftmmkv_string_list`.
final class StringList {
  let strings: [UnsafeMutablePointer<CChar>]

  init(_ strings: some Sequence<String>) {
    self.strings = strings.map { makeCString($0).pointer }
  }

  deinit {
    for string in self.strings {
      string.deallocate()
    }
  }
}

@c @implementation
public func swiftmmkv_string_list_count(_ list: OpaquePointer) -> Int {
  list.object(StringList.self).strings.count
}

@c @implementation
public func swiftmmkv_string_list_get(_ list: OpaquePointer, _ index: Int) -> UnsafePointer<CChar> {
  UnsafePointer(list.object(StringList.self).strings[index])
}

@c @implementation
public func swiftmmkv_string_list_free(_ list: OpaquePointer?) {
  list?.release(as: StringList.self)
}

// MARK: - Callback Contexts

/// The context pointer of a C callback, which is released when the last closure that calls
/// the callback is.
///
/// A listener that another thread is in the middle of calling holds on to its closure, so the
/// context outlives every call however a cancellation races with one.
final class CallbackContext: @unchecked Sendable {
  let pointer: UnsafeMutableRawPointer?
  private let release: swiftmmkv_context_release?

  init(_ pointer: UnsafeMutableRawPointer?, release: swiftmmkv_context_release?) {
    self.pointer = pointer
    self.release = release
  }

  deinit {
    self.release?(self.pointer)
  }
}

/// The object behind a `swiftmmkv_subscription`.
final class Subscription {
  let subscription: MMKVSubscription

  init(_ subscription: MMKVSubscription) {
    self.subscription = subscription
  }
}

@c @implementation
public func swiftmmkv_subscription_cancel(_ subscription: OpaquePointer?) {
  guard let subscription else { return }
  subscription.object(Subscription.self).subscription.cancel()
  subscription.release(as: Subscription.self)
}
