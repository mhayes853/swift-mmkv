import CSwiftMMKVCore

/// The C++ core this package vendors, reached through the C interface in `CSwiftMMKVCore.h`.
struct CxxEngine: MMKVEngine {
  private nonisolated(unsafe) let handle: OpaquePointer

  /// Opens the instance described by `configuration`, or returns the instance already open for
  /// its directory and identifier.
  init(_ configuration: MMKVConfiguration) throws(MMKVError) {
    Self.installContentChangedCallback
    guard let handle = configuration.withCConfiguration({ mmkv_open(&$0) }) else {
      throw MMKVErrors.openFailed(id: configuration.id, directory: configuration.directory)
    }
    self.handle = handle
  }

  var kind: MMKVConfiguration.Engine { .cxx }

  var instance: UInt {
    UInt(bitPattern: self.handle)
  }

  func close() {
    mmkv_close(self.handle)
  }

  // The core reports a change by store identifier alone, so every instance with that identifier
  // is marked. Stores with the same identifier in different directories are over-notified, which
  // only costs a spurious `.external`.
  private static let installContentChangedCallback: Void = {
    mmkv_set_content_changed_callback { id in
      MMKVStoreState.markExternalChange(
        id: String(decoding: UnsafeRawBufferPointer(id), as: UTF8.self)
      )
    }
  }()
}

// MARK: - Reads

extension CxxEngine {
  func bool(forKey key: String) -> Bool? {
    self.scalar(false, forKey: key, mmkv_get_bool)
  }

  func int32(forKey key: String) -> Int32? {
    self.scalar(0, forKey: key, mmkv_get_int32)
  }

  func uint32(forKey key: String) -> UInt32? {
    self.scalar(0, forKey: key, mmkv_get_uint32)
  }

  func int64(forKey key: String) -> Int64? {
    self.scalar(0, forKey: key, mmkv_get_int64)
  }

  func uint64(forKey key: String) -> UInt64? {
    self.scalar(0, forKey: key, mmkv_get_uint64)
  }

  func float(forKey key: String) -> Float? {
    self.scalar(0, forKey: key, mmkv_get_float)
  }

  func double(forKey key: String) -> Double? {
    self.scalar(0, forKey: key, mmkv_get_double)
  }

  /// Reads a fixed-size value with `get`, which writes it over `initial` when the key has one.
  private func scalar<T>(
    _ initial: T,
    forKey key: String,
    _ get: (OpaquePointer, mmkv_bytes, UnsafeMutablePointer<T>) -> Bool
  ) -> T? {
    var value = initial
    return key.withMMKVBytes { get(self.handle, $0, &value) } ? value : nil
  }

  func string(forKey key: String) -> String? {
    key.withMMKVBytes { key in
      withCallbackBytes { context, callback in
        mmkv_get_string(self.handle, key, context, callback)
      } _: { buffer in
        String(decoding: buffer, as: UTF8.self)
      }
    }
  }

  func strings(forKey key: String) -> [String]? {
    var strings = [String]()
    let hasValue = key.withMMKVBytes { key in
      forEachCallbackBytes { context, callback in
        mmkv_get_strings(self.handle, key, context, callback)
      } _: { buffer in
        strings.append(String(decoding: buffer, as: UTF8.self))
      }
    }
    return hasValue ? strings : nil
  }

  func withBytes<R, E: Error>(
    forKey key: String,
    _ body: (RawSpan) throws(E) -> R
  ) throws(E) -> R? {
    try key
      .withMMKVBytes { key in
        Result { () throws(E) -> R? in
          try withCallbackBytes { context, callback in
            mmkv_get_bytes(self.handle, key, context, callback)
          } _: { (buffer: UnsafeRawBufferPointer) throws(E) -> R in
            try body(buffer.bytes)
          }
        }
      }
      .get()
  }
}

// MARK: - Writes

extension CxxEngine {
  func set(_ value: Bool, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    key.withMMKVBytes { mmkv_set_bool(self.handle, $0, value, expiresInSeconds) }
  }

  func set(_ value: Int32, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    key.withMMKVBytes { mmkv_set_int32(self.handle, $0, value, expiresInSeconds) }
  }

  func set(_ value: UInt32, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    key.withMMKVBytes { mmkv_set_uint32(self.handle, $0, value, expiresInSeconds) }
  }

  func set(_ value: Int64, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    key.withMMKVBytes { mmkv_set_int64(self.handle, $0, value, expiresInSeconds) }
  }

  func set(_ value: UInt64, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    key.withMMKVBytes { mmkv_set_uint64(self.handle, $0, value, expiresInSeconds) }
  }

  func set(_ value: Float, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    key.withMMKVBytes { mmkv_set_float(self.handle, $0, value, expiresInSeconds) }
  }

  func set(_ value: Double, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    key.withMMKVBytes { mmkv_set_double(self.handle, $0, value, expiresInSeconds) }
  }

  func set(_ value: String, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    value.withMMKVBytes { value in
      key.withMMKVBytes { mmkv_set_string(self.handle, $0, value, expiresInSeconds) }
    }
  }

  func set(_ value: [String], forKey key: String, expiresInSeconds: UInt32) -> Bool {
    value.withMMKVBytes { values in
      key.withMMKVBytes {
        mmkv_set_strings(self.handle, $0, values.baseAddress, values.count, expiresInSeconds)
      }
    }
  }

  func set(bytes: RawSpan, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    bytes.withUnsafeBytes { buffer in
      key.withMMKVBytes {
        mmkv_set_bytes(
          self.handle,
          $0,
          mmkv_bytes(bytes: buffer.baseAddress, count: buffer.count),
          expiresInSeconds
        )
      }
    }
  }
}

// MARK: - Keys

extension CxxEngine {
  var count: Int {
    mmkv_count(self.handle)
  }

  var keys: Set<String> {
    var keys = Set<String>()
    _ = forEachCallbackBytes { context, callback in
      mmkv_keys(self.handle, context, callback)
      return true
    } _: { buffer in
      keys.insert(String(decoding: buffer, as: UTF8.self))
    }
    return keys
  }

  func contains(_ key: String) -> Bool {
    key.withMMKVBytes { mmkv_contains(self.handle, $0) }
  }

  func remove(_ key: String) -> Bool {
    key.withMMKVBytes { mmkv_remove(self.handle, $0) }
  }

  func remove(_ keys: [String]) {
    keys.withMMKVBytes { keys in
      _ = mmkv_remove_many(self.handle, keys.baseAddress, keys.count)
    }
  }

  func removeAll(keepingCapacity: Bool) {
    mmkv_remove_all(self.handle, keepingCapacity)
  }

  func importAll(from source: any MMKVEngine) -> Int {
    // Both stores of an import are opened by one configuration's engine.
    guard let source = source as? CxxEngine else { return 0 }
    return mmkv_import(self.handle, source.handle)
  }
}

// MARK: - Locking and maintenance

extension CxxEngine {
  func lock() {
    mmkv_lock(self.handle)
  }

  func unlock() {
    mmkv_unlock(self.handle)
  }

  var totalSize: Int {
    mmkv_total_size(self.handle)
  }

  var actualSize: Int {
    mmkv_actual_size(self.handle)
  }

  func checkContentChanged() {
    mmkv_check_content_changed(self.handle)
  }

  func trim() {
    mmkv_trim(self.handle)
  }

  func sync() {
    mmkv_sync(self.handle)
  }

  var isExpiryEnabled: Bool {
    mmkv_is_expiry_enabled(self.handle)
  }

  func disableExpiry() -> Bool {
    mmkv_disable_expiry(self.handle)
  }

  func rekey(_ encryption: MMKVConfiguration.Encryption?) -> Bool {
    (encryption?.key ?? [])
      .withUnsafeBytes { key in
        mmkv_rekey(
          self.handle,
          encryption.cValue,
          mmkv_bytes(bytes: key.baseAddress, count: key.count)
        )
      }
  }
}

// MARK: - C configuration

extension MMKVConfiguration.Encryption? {
  fileprivate var cValue: Int32 {
    switch self {
    case nil: Int32(MMKV_ENCRYPTION_NONE)
    case .aes128: Int32(MMKV_ENCRYPTION_AES128)
    case .aes256: Int32(MMKV_ENCRYPTION_AES256)
    }
  }
}

extension MMKVConfiguration {
  fileprivate func withCConfiguration<R>(_ body: (inout mmkv_configuration) -> R) -> R {
    self.id.rawValue.withMMKVBytes { id in
      self.directory.path.withMMKVBytes { rootDirectory in
        (self.encryption?.key ?? [])
          .withUnsafeBytes { key in
            var configuration = mmkv_configuration(
              id: id,
              root_directory: rootDirectory,
              multi_process: self.mode == .multiProcess,
              read_only: self.isReadOnly,
              encryption: self.encryption.cValue,
              encryption_key: mmkv_bytes(bytes: key.baseAddress, count: key.count),
              expected_capacity: Swift.max(self.expectedCapacity, 0),
              recover_on_error: self.recovery == .recover,
              compare_before_set: self.compareBeforeSet,
              item_size_limit: UInt32(clamping: self.itemSizeLimit ?? 0)
            )
            return body(&configuration)
          }
      }
    }
  }
}
