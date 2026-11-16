import CSwiftMMKVCore

/// Reads the value of one key of an ``MMKVStore``, in whichever encoding the caller names.
///
/// A reader is handed to ``MMKVValue/init(from:)`` and cannot outlive that call. Every method
/// returns `nil` when the key has no value. Because the file stores no type information, the
/// numeric methods return a value for any key that exists, whatever it was written as.
public struct MMKVValueReader: ~Copyable, ~Escapable {
  let store: MMKVStore
  let key: String

  @_lifetime(immortal)
  init(store: MMKVStore, key: String) {
    self.store = store
    self.key = key
  }

  /// Reads the key as a Boolean.
  public func bool() -> Bool? {
    var value = false
    return self.key.withMMKVBytes { swiftmmkv_get_bool(self.store.handle, $0, &value) }
      ? value : nil
  }

  /// Reads the key as a signed 32-bit integer.
  public func int32() -> Int32? {
    var value: Int32 = 0
    return self.key.withMMKVBytes { swiftmmkv_get_int32(self.store.handle, $0, &value) }
      ? value : nil
  }

  /// Reads the key as an unsigned 32-bit integer.
  public func uint32() -> UInt32? {
    var value: UInt32 = 0
    return self.key.withMMKVBytes { swiftmmkv_get_uint32(self.store.handle, $0, &value) }
      ? value : nil
  }

  /// Reads the key as a signed 64-bit integer.
  public func int64() -> Int64? {
    var value: Int64 = 0
    return self.key.withMMKVBytes { swiftmmkv_get_int64(self.store.handle, $0, &value) }
      ? value : nil
  }

  /// Reads the key as an unsigned 64-bit integer.
  public func uint64() -> UInt64? {
    var value: UInt64 = 0
    return self.key.withMMKVBytes { swiftmmkv_get_uint64(self.store.handle, $0, &value) }
      ? value : nil
  }

  /// Reads the key as a single-precision floating-point number.
  public func float() -> Float? {
    var value: Float = 0
    return self.key.withMMKVBytes { swiftmmkv_get_float(self.store.handle, $0, &value) }
      ? value : nil
  }

  /// Reads the key as a double-precision floating-point number, which is how JavaScript numbers
  /// are stored.
  public func double() -> Double? {
    var value: Double = 0
    return self.key.withMMKVBytes { swiftmmkv_get_double(self.store.handle, $0, &value) }
      ? value : nil
  }

  /// Reads the key as a UTF-8 string, repairing any invalid UTF-8.
  public func string() -> String? {
    self.withStringBytes { String(decoding: $0, as: UTF8.self) }
  }

  /// Reads the key as a list of strings.
  public func strings() -> [String]? {
    var strings = [String]()
    let hasValue = self.key.withMMKVBytes { key in
      forEachCallbackBytes { context, callback in
        swiftmmkv_get_strings(self.store.handle, key, context, callback)
      } _: { buffer in
        strings.append(String(decoding: buffer, as: UTF8.self))
      }
    }
    return hasValue ? strings : nil
  }

  /// Reads the key as raw bytes, which are only valid for the duration of `body`.
  ///
  /// This layer does not copy the bytes. MMKV itself may, and always does for an encrypted
  /// store.
  ///
  /// - Returns: The result of `body`, or `nil` if the key has no value.
  public func withBytes<R, E: Error>(_ body: (RawSpan) throws(E) -> R) throws(E) -> R? {
    try self.key.withMMKVBytes { key in
      Result { () throws(E) -> R? in
        try withCallbackBytes { context, callback in
          swiftmmkv_get_bytes(self.store.handle, key, context, callback)
        } _: { (buffer: UnsafeRawBufferPointer) throws(E) -> R in
          try body(buffer.bytes)
        }
      }
    }.get()
  }

  /// Reads the key as a string, handing over its UTF-8 bytes without building a `String`.
  func withStringBytes<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R? {
    self.key.withMMKVBytes { key in
      withCallbackBytes { context, callback in
        swiftmmkv_get_string(self.store.handle, key, context, callback)
      } _: { buffer in
        body(buffer)
      }
    }
  }
}
