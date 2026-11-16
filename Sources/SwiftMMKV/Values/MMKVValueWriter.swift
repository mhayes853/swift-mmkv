import CSwiftMMKVCore

/// Writes the value of one key of an ``MMKVStore``, in whichever encoding the caller names.
///
/// A writer is handed to ``MMKVValue/write(to:)`` and cannot outlive that call. Every method
/// returns whether the value was stored. A write fails when the key is empty, the store is
/// read-only, or the pair is larger than the store's item size limit.
public struct MMKVValueWriter: ~Copyable, ~Escapable {
  let store: MMKVStore
  let key: String
  let expiresInSeconds: UInt32

  @_lifetime(immortal)
  init(store: MMKVStore, key: String, expiresInSeconds: UInt32) {
    self.store = store
    self.key = key
    self.expiresInSeconds = expiresInSeconds
  }

  /// Stores a Boolean.
  public mutating func set(_ value: Bool) -> Bool {
    self.key.withMMKVBytes {
      swiftmmkv_set_bool(self.store.handle, $0, value, self.expiresInSeconds)
    }
  }

  /// Stores a signed 32-bit integer.
  public mutating func set(_ value: Int32) -> Bool {
    self.key.withMMKVBytes {
      swiftmmkv_set_int32(self.store.handle, $0, value, self.expiresInSeconds)
    }
  }

  /// Stores an unsigned 32-bit integer.
  public mutating func set(_ value: UInt32) -> Bool {
    self.key.withMMKVBytes {
      swiftmmkv_set_uint32(self.store.handle, $0, value, self.expiresInSeconds)
    }
  }

  /// Stores a signed 64-bit integer.
  public mutating func set(_ value: Int64) -> Bool {
    self.key.withMMKVBytes {
      swiftmmkv_set_int64(self.store.handle, $0, value, self.expiresInSeconds)
    }
  }

  /// Stores an unsigned 64-bit integer.
  public mutating func set(_ value: UInt64) -> Bool {
    self.key.withMMKVBytes {
      swiftmmkv_set_uint64(self.store.handle, $0, value, self.expiresInSeconds)
    }
  }

  /// Stores a single-precision floating-point number.
  public mutating func set(_ value: Float) -> Bool {
    self.key.withMMKVBytes {
      swiftmmkv_set_float(self.store.handle, $0, value, self.expiresInSeconds)
    }
  }

  /// Stores a double-precision floating-point number, which is how JavaScript numbers are
  /// stored.
  public mutating func set(_ value: Double) -> Bool {
    self.key.withMMKVBytes {
      swiftmmkv_set_double(self.store.handle, $0, value, self.expiresInSeconds)
    }
  }

  /// Stores a string as UTF-8.
  public mutating func set(_ value: String) -> Bool {
    value.withMMKVBytes { value in
      self.key.withMMKVBytes {
        swiftmmkv_set_string(self.store.handle, $0, value, self.expiresInSeconds)
      }
    }
  }

  /// Stores a list of strings.
  public mutating func set(_ value: [String]) -> Bool {
    value.withMMKVBytes { values in
      self.key.withMMKVBytes {
        swiftmmkv_set_strings(
          self.store.handle,
          $0,
          values.baseAddress,
          values.count,
          self.expiresInSeconds
        )
      }
    }
  }

  /// Stores raw bytes, which MMKV copies into its file before this returns.
  public mutating func set(bytes: RawSpan) -> Bool {
    bytes.withUnsafeBytes { self.set(buffer: $0) }
  }

  /// Stores raw bytes as a string value, for bytes that are already UTF-8.
  mutating func set(utf8 buffer: UnsafeRawBufferPointer) -> Bool {
    self.key.withMMKVBytes {
      swiftmmkv_set_string(
        self.store.handle,
        $0,
        swiftmmkv_bytes(bytes: buffer.baseAddress, count: buffer.count),
        self.expiresInSeconds
      )
    }
  }

  mutating func set(buffer: UnsafeRawBufferPointer) -> Bool {
    self.key.withMMKVBytes {
      swiftmmkv_set_bytes(
        self.store.handle,
        $0,
        swiftmmkv_bytes(bytes: buffer.baseAddress, count: buffer.count),
        self.expiresInSeconds
      )
    }
  }
}
