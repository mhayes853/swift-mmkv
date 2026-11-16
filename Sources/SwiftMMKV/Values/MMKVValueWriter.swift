/// Writes the value of one key of an ``MMKVStore``, in whichever encoding the caller names.
///
/// A writer is handed to ``MMKVValue/write(to:)`` and cannot outlive that call. Every method
/// returns whether the value was stored. A write fails when the key is empty, the store is
/// read-only, or the pair is larger than the store's item size limit.
public struct MMKVValueWriter: ~Copyable, ~Escapable {
  private let core: MMKVCore
  private let key: String
  private let expiresInSeconds: UInt32

  @_lifetime(immortal)
  fileprivate init(core: MMKVCore, key: String, expiresInSeconds: UInt32) {
    self.core = core
    self.key = key
    self.expiresInSeconds = expiresInSeconds
  }

  /// Stores a Boolean.
  public mutating func set(_ value: Bool) -> Bool {
    self.core.set(value, forKey: self.key, expiresInSeconds: self.expiresInSeconds)
  }

  /// Stores a signed 32-bit integer.
  public mutating func set(_ value: Int32) -> Bool {
    self.core.set(value, forKey: self.key, expiresInSeconds: self.expiresInSeconds)
  }

  /// Stores an unsigned 32-bit integer.
  public mutating func set(_ value: UInt32) -> Bool {
    self.core.set(value, forKey: self.key, expiresInSeconds: self.expiresInSeconds)
  }

  /// Stores a signed 64-bit integer.
  public mutating func set(_ value: Int64) -> Bool {
    self.core.set(value, forKey: self.key, expiresInSeconds: self.expiresInSeconds)
  }

  /// Stores an unsigned 64-bit integer.
  public mutating func set(_ value: UInt64) -> Bool {
    self.core.set(value, forKey: self.key, expiresInSeconds: self.expiresInSeconds)
  }

  /// Stores a single-precision floating-point number.
  public mutating func set(_ value: Float) -> Bool {
    self.core.set(value, forKey: self.key, expiresInSeconds: self.expiresInSeconds)
  }

  /// Stores a double-precision floating-point number, which is how JavaScript numbers are
  /// stored.
  public mutating func set(_ value: Double) -> Bool {
    self.core.set(value, forKey: self.key, expiresInSeconds: self.expiresInSeconds)
  }

  /// Stores a string as UTF-8.
  public mutating func set(_ value: String) -> Bool {
    self.core.set(value, forKey: self.key, expiresInSeconds: self.expiresInSeconds)
  }

  /// Stores a list of strings.
  public mutating func set(_ value: [String]) -> Bool {
    self.core.set(value, forKey: self.key, expiresInSeconds: self.expiresInSeconds)
  }

  /// Stores raw bytes, which MMKV copies into its file before this returns.
  ///
  /// Bytes that are valid UTF-8 read back as a string, because MMKV stores the two the same way.
  public mutating func set(bytes: RawSpan) -> Bool {
    self.core.set(bytes: bytes, forKey: self.key, expiresInSeconds: self.expiresInSeconds)
  }

  /// Stores the raw bytes in `unsafeBytes`, which MMKV copies into its file before this
  /// returns.
  public mutating func set(unsafeBytes: UnsafeRawBufferPointer) -> Bool {
    self.set(bytes: RawSpan(_unsafeBytes: unsafeBytes))
  }
}

extension MMKVCore {
  /// Stores `value` under `key` by handing it a writer for that key.
  func set<V: MMKVValue>(_ value: V, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    var writer = MMKVValueWriter(core: self, key: key, expiresInSeconds: expiresInSeconds)
    return value.write(to: &writer)
  }
}
