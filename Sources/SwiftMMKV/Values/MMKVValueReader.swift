/// Reads the value of one key of an ``MMKVStore``, in whichever encoding the caller names.
///
/// A reader is handed to ``MMKVValue/init(from:)`` and cannot outlive that call. Every method
/// returns `nil` when the key has no value. Because the file stores no type information, the
/// numeric methods return a value for any key that exists, whatever it was written as.
public struct MMKVValueReader: ~Copyable, ~Escapable {
  private let core: MMKVCore
  private let key: String

  @_lifetime(immortal)
  fileprivate init(core: MMKVCore, key: String) {
    self.core = core
    self.key = key
  }

  /// Reads the key as a Boolean.
  public func bool() -> Bool? {
    self.core.read { $0.bool(forKey: self.key) }
  }

  /// Reads the key as a signed 32-bit integer.
  public func int32() -> Int32? {
    self.core.read { $0.int32(forKey: self.key) }
  }

  /// Reads the key as an unsigned 32-bit integer.
  public func uint32() -> UInt32? {
    self.core.read { $0.uint32(forKey: self.key) }
  }

  /// Reads the key as a signed 64-bit integer.
  public func int64() -> Int64? {
    self.core.read { $0.int64(forKey: self.key) }
  }

  /// Reads the key as an unsigned 64-bit integer.
  public func uint64() -> UInt64? {
    self.core.read { $0.uint64(forKey: self.key) }
  }

  /// Reads the key as a single-precision floating-point number.
  public func float() -> Float? {
    self.core.read { $0.float(forKey: self.key) }
  }

  /// Reads the key as a double-precision floating-point number, which is how JavaScript numbers
  /// are stored.
  public func double() -> Double? {
    self.core.read { $0.double(forKey: self.key) }
  }

  /// Reads the key as an integer that was stored as a `Double`, which is how JavaScript stores
  /// every number.
  ///
  /// - Returns: `nil` if the key has no value, or if its number is not a whole number that fits
  ///   in `I`.
  @inlinable
  public func number<I: BinaryInteger>(as type: I.Type = I.self) -> I? {
    self.double().flatMap { I(exactly: $0) }
  }

  /// Reads the key as a UTF-8 string, repairing any invalid UTF-8.
  public func string() -> String? {
    self.core.read { $0.string(forKey: self.key) }
  }

  /// Reads the key as a list of strings.
  public func strings() -> [String]? {
    self.core.read { $0.strings(forKey: self.key) }
  }

  /// Reads the key as raw bytes, which are only valid for the duration of `body`.
  ///
  /// A string value reads as its UTF-8 bytes, because MMKV stores the two the same way. This
  /// layer does not copy the bytes. MMKV itself may, and always does for an encrypted store.
  ///
  /// - Returns: The result of `body`, or `nil` if the key has no value.
  public func withBytes<R, E: Error>(_ body: (RawSpan) throws(E) -> R) throws(E) -> R? {
    try self.core.read { (engine) throws(E) -> R? in
      try engine.withBytes(forKey: self.key, body)
    }
  }

  /// Reads the key as raw bytes through a buffer pointer, which is only valid for the duration
  /// of `body`.
  ///
  /// - Returns: The result of `body`, or `nil` if the key has no value.
  public func withUnsafeBytes<R, E: Error>(
    _ body: (UnsafeRawBufferPointer) throws(E) -> R
  ) throws(E) -> R? {
    try self.withBytes { (bytes: RawSpan) throws(E) -> R in
      try bytes.withUnsafeBytes(body)
    }
  }
}

extension MMKVCore {
  /// Reads the value stored under `key` by handing `V` a reader for it.
  func value<V: MMKVValue>(forKey key: String, as type: V.Type) -> V? {
    V(from: MMKVValueReader(core: self, key: key))
  }
}
