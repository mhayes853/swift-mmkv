import CSwiftMMKVCore

/// One underlying MMKV instance, and everything this package asks of it.
///
/// The public types hold one of these privately, so that none of them needs a member that is
/// visible to the rest of the module. Nothing here notifies listeners about writes; that is left
/// to ``MMKVStore``.
struct MMKVCore: Sendable {
  private nonisolated(unsafe) let handle: OpaquePointer
  let state: MMKVStoreState

  /// Opens the instance described by `configuration`, creating its files if they do not exist.
  init(_ configuration: MMKVConfiguration) throws(MMKVError) {
    if let encryption = configuration.encryption, !encryption.isValid {
      throw .invalidEncryptionKey
    }
    let handle = configuration.withCConfiguration { mmkv_open(&$0) }
    guard let handle else {
      throw .openFailed(id: configuration.id, directory: configuration.directory)
    }
    self.handle = handle
    self.state = MMKVStoreState.shared(for: handle, id: configuration.id)
  }

  /// Tells listeners about anything the core noticed while it held its locks. Called once an
  /// operation has returned.
  func operationDidFinish() {
    self.state.deliverPendingExternalChange()
  }
}

// MARK: - Reads

extension MMKVCore {
  func bool(forKey key: String) -> Bool? {
    var value = false
    return key.withMMKVBytes { mmkv_get_bool(self.handle, $0, &value) } ? value : nil
  }

  func int32(forKey key: String) -> Int32? {
    var value: Int32 = 0
    return key.withMMKVBytes { mmkv_get_int32(self.handle, $0, &value) } ? value : nil
  }

  func uint32(forKey key: String) -> UInt32? {
    var value: UInt32 = 0
    return key.withMMKVBytes { mmkv_get_uint32(self.handle, $0, &value) } ? value : nil
  }

  func int64(forKey key: String) -> Int64? {
    var value: Int64 = 0
    return key.withMMKVBytes { mmkv_get_int64(self.handle, $0, &value) } ? value : nil
  }

  func uint64(forKey key: String) -> UInt64? {
    var value: UInt64 = 0
    return key.withMMKVBytes { mmkv_get_uint64(self.handle, $0, &value) } ? value : nil
  }

  func float(forKey key: String) -> Float? {
    var value: Float = 0
    return key.withMMKVBytes { mmkv_get_float(self.handle, $0, &value) } ? value : nil
  }

  func double(forKey key: String) -> Double? {
    var value: Double = 0
    return key.withMMKVBytes { mmkv_get_double(self.handle, $0, &value) } ? value : nil
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

extension MMKVCore {
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

extension MMKVCore {
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
    guard !keys.isEmpty else { return }
    keys.withMMKVBytes { keys in
      _ = mmkv_remove_many(self.handle, keys.baseAddress, keys.count)
    }
  }

  func removeAll(keepingCapacity: Bool) {
    mmkv_remove_all(self.handle, keepingCapacity)
  }
}

// MARK: - Locking and maintenance

extension MMKVCore {
  /// Runs `body` with the instance's recursive lock held.
  ///
  /// Listeners are not told about an external change while the lock is held, because a listener
  /// that waits on another thread would deadlock against it. They are told once the outermost
  /// call releases the lock.
  func locked<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
    mmkv_lock(self.handle)
    self.state.beginDeferringExternalChanges()
    defer {
      self.state.endDeferringExternalChanges()
      mmkv_unlock(self.handle)
      self.state.deliverPendingExternalChange()
    }
    return try body()
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

  func rekey(_ encryption: MMKVConfiguration.Encryption?) throws(MMKVError) {
    if let encryption, !encryption.isValid {
      throw .invalidEncryptionKey
    }
    let didRekey = (encryption?.key ?? [])
      .withUnsafeBytes { key in
        mmkv_rekey(
          self.handle,
          encryption.cValue,
          mmkv_bytes(bytes: key.baseAddress, count: key.count)
        )
      }
    guard didRekey else { throw .rekeyFailed }
  }
}

// MARK: - C configuration

extension MMKVConfiguration.Encryption {
  fileprivate var key: [UInt8] {
    switch self {
    case .aes128(let key), .aes256(let key): key
    }
  }

  fileprivate var isValid: Bool {
    switch self {
    case .aes128(let key): (1...16).contains(key.count)
    case .aes256(let key): (1...32).contains(key.count)
    }
  }
}

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
    self.id.withMMKVBytes { id in
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
