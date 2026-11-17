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
    let handle = MMKVStorage(path: configuration.directory.path)
      .opening(id: configuration.id) {
        configuration.withCConfiguration { mmkv_open(&$0) }
      }
    guard let handle else {
      throw .openFailed(id: configuration.id, directory: configuration.directory)
    }
    self.handle = handle
    self.state = MMKVStoreState.shared(
      for: handle,
      id: configuration.id,
      isMultiProcess: configuration.mode == .multiProcess
    )
  }

  /// Runs an operation that takes the store's file lock, unless the store is suspended.
  ///
  /// - Returns: `nil`, without running `body`, if the store is suspended.
  private func perform<R, E: Error>(
    _ body: (OpaquePointer) throws(E) -> R
  ) throws(E) -> R? {
    guard let gate = self.state.suspensionGate else { return try body(self.handle) }
    guard gate.enter() else { return nil }
    defer { gate.leave() }
    return try body(self.handle)
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
    self.perform { handle in
      var value = false
      return key.withMMKVBytes { mmkv_get_bool(handle, $0, &value) } ? value : nil
    } ?? nil
  }

  func int32(forKey key: String) -> Int32? {
    self.perform { handle in
      var value: Int32 = 0
      return key.withMMKVBytes { mmkv_get_int32(handle, $0, &value) } ? value : nil
    } ?? nil
  }

  func uint32(forKey key: String) -> UInt32? {
    self.perform { handle in
      var value: UInt32 = 0
      return key.withMMKVBytes { mmkv_get_uint32(handle, $0, &value) } ? value : nil
    } ?? nil
  }

  func int64(forKey key: String) -> Int64? {
    self.perform { handle in
      var value: Int64 = 0
      return key.withMMKVBytes { mmkv_get_int64(handle, $0, &value) } ? value : nil
    } ?? nil
  }

  func uint64(forKey key: String) -> UInt64? {
    self.perform { handle in
      var value: UInt64 = 0
      return key.withMMKVBytes { mmkv_get_uint64(handle, $0, &value) } ? value : nil
    } ?? nil
  }

  func float(forKey key: String) -> Float? {
    self.perform { handle in
      var value: Float = 0
      return key.withMMKVBytes { mmkv_get_float(handle, $0, &value) } ? value : nil
    } ?? nil
  }

  func double(forKey key: String) -> Double? {
    self.perform { handle in
      var value: Double = 0
      return key.withMMKVBytes { mmkv_get_double(handle, $0, &value) } ? value : nil
    } ?? nil
  }

  func string(forKey key: String) -> String? {
    self.perform { handle in
      key.withMMKVBytes { key in
        withCallbackBytes { context, callback in
          mmkv_get_string(handle, key, context, callback)
        } _: { buffer in
          String(decoding: buffer, as: UTF8.self)
        }
      }
    } ?? nil
  }

  func strings(forKey key: String) -> [String]? {
    var strings = [String]()
    let hasValue = self.perform { handle in
      key.withMMKVBytes { key in
        forEachCallbackBytes { context, callback in
          mmkv_get_strings(handle, key, context, callback)
        } _: { buffer in
          strings.append(String(decoding: buffer, as: UTF8.self))
        }
      }
    }
    return hasValue == true ? strings : nil
  }

  func withBytes<R, E: Error>(
    forKey key: String,
    _ body: (RawSpan) throws(E) -> R
  ) throws(E) -> R? {
    try self.perform { (handle: OpaquePointer) throws(E) -> R? in
      try key
        .withMMKVBytes { key in
          Result { () throws(E) -> R? in
            try withCallbackBytes { context, callback in
              mmkv_get_bytes(handle, key, context, callback)
            } _: { (buffer: UnsafeRawBufferPointer) throws(E) -> R in
              try body(buffer.bytes)
            }
          }
        }
        .get()
    } ?? nil
  }
}

// MARK: - Writes

extension MMKVCore {
  func set(_ value: Bool, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { handle in
      key.withMMKVBytes { mmkv_set_bool(handle, $0, value, expiresInSeconds) }
    } ?? false
  }

  func set(_ value: Int32, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { handle in
      key.withMMKVBytes { mmkv_set_int32(handle, $0, value, expiresInSeconds) }
    } ?? false
  }

  func set(_ value: UInt32, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { handle in
      key.withMMKVBytes { mmkv_set_uint32(handle, $0, value, expiresInSeconds) }
    } ?? false
  }

  func set(_ value: Int64, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { handle in
      key.withMMKVBytes { mmkv_set_int64(handle, $0, value, expiresInSeconds) }
    } ?? false
  }

  func set(_ value: UInt64, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { handle in
      key.withMMKVBytes { mmkv_set_uint64(handle, $0, value, expiresInSeconds) }
    } ?? false
  }

  func set(_ value: Float, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { handle in
      key.withMMKVBytes { mmkv_set_float(handle, $0, value, expiresInSeconds) }
    } ?? false
  }

  func set(_ value: Double, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { handle in
      key.withMMKVBytes { mmkv_set_double(handle, $0, value, expiresInSeconds) }
    } ?? false
  }

  func set(_ value: String, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { handle in
      value.withMMKVBytes { value in
        key.withMMKVBytes { mmkv_set_string(handle, $0, value, expiresInSeconds) }
      }
    } ?? false
  }

  func set(_ value: [String], forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { handle in
      value.withMMKVBytes { values in
        key.withMMKVBytes {
          mmkv_set_strings(handle, $0, values.baseAddress, values.count, expiresInSeconds)
        }
      }
    } ?? false
  }

  func set(bytes: RawSpan, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { handle in
      bytes.withUnsafeBytes { buffer in
        key.withMMKVBytes {
          mmkv_set_bytes(
            handle,
            $0,
            mmkv_bytes(bytes: buffer.baseAddress, count: buffer.count),
            expiresInSeconds
          )
        }
      }
    } ?? false
  }
}

// MARK: - Keys

extension MMKVCore {
  var count: Int {
    self.perform { mmkv_count($0) } ?? 0
  }

  var keys: Set<String> {
    var keys = Set<String>()
    self.perform { handle in
      _ = forEachCallbackBytes { context, callback in
        mmkv_keys(handle, context, callback)
        return true
      } _: { buffer in
        keys.insert(String(decoding: buffer, as: UTF8.self))
      }
    }
    return keys
  }

  func contains(_ key: String) -> Bool {
    self.perform { handle in key.withMMKVBytes { mmkv_contains(handle, $0) } } ?? false
  }

  func remove(_ key: String) -> Bool {
    self.perform { handle in key.withMMKVBytes { mmkv_remove(handle, $0) } } ?? false
  }

  func remove(_ keys: [String]) {
    guard !keys.isEmpty else { return }
    self.perform { handle in
      keys.withMMKVBytes { keys in
        _ = mmkv_remove_many(handle, keys.baseAddress, keys.count)
      }
    }
  }

  func removeAll(keepingCapacity: Bool) {
    self.perform { mmkv_remove_all($0, keepingCapacity) }
  }
}

// MARK: - Import

extension MMKVCore {
  /// - Returns: The number of keys copied from `source`.
  func importAll(from source: MMKVCore) -> Int {
    self.perform { handle in
      source.perform { mmkv_import(handle, $0) } ?? 0
    } ?? 0
  }
}

// MARK: - Suspension

extension MMKVCore {
  var isSuspended: Bool {
    self.state.suspensionGate?.isSuspended ?? false
  }

  func suspend() {
    self.state.suspensionGate?.suspend()
  }

  /// - Returns: Whether the store was suspended.
  func resume() -> Bool {
    self.state.suspensionGate?.resume() ?? false
  }
}

// MARK: - Locking and maintenance

extension MMKVCore {
  /// Runs `body` with the instance's recursive lock held.
  ///
  /// Listeners are not told about an external change while the lock is held, because a listener
  /// that waits on another thread would deadlock against it. They are told once the outermost
  /// call releases the lock.
  ///
  /// While the store is suspended `body` runs without the lock, and every operation in it is
  /// turned away.
  func locked<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
    let gate = self.state.suspensionGate
    guard gate?.enter() ?? true else { return try body() }
    mmkv_lock(self.handle)
    self.state.beginDeferringExternalChanges()
    defer {
      self.state.endDeferringExternalChanges()
      mmkv_unlock(self.handle)
      gate?.leave()
      self.state.deliverPendingExternalChange()
    }
    return try body()
  }

  var totalSize: Int {
    self.perform { mmkv_total_size($0) } ?? 0
  }

  var actualSize: Int {
    self.perform { mmkv_actual_size($0) } ?? 0
  }

  func checkContentChanged() {
    self.perform { mmkv_check_content_changed($0) }
  }

  func trim() {
    self.perform { mmkv_trim($0) }
  }

  func sync() {
    self.perform { mmkv_sync($0) }
  }

  func rekey(_ encryption: MMKVConfiguration.Encryption?) throws(MMKVError) {
    if let encryption, !encryption.isValid {
      throw .invalidEncryptionKey
    }
    let didRekey = self.perform { handle in
      (encryption?.key ?? [])
        .withUnsafeBytes { key in
          mmkv_rekey(
            handle,
            encryption.cValue,
            mmkv_bytes(bytes: key.baseAddress, count: key.count)
          )
        }
    }
    guard let didRekey else { throw .storeIsSuspended(id: self.state.id) }
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
