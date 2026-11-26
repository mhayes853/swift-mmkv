import CSwiftMMKVCore

/// One underlying MMKV instance, and everything this package asks of it.
///
/// The public types hold one of these privately, so that none of them needs a member that is
/// visible to the rest of the module. Nothing here notifies listeners about writes; that is left
/// to ``MMKVStore``.
struct MMKVCore: Sendable {
  private nonisolated(unsafe) let handle: OpaquePointer
  let state: MMKVStoreState
  private let defaultExpiry: MMKVExpiry

  /// Opens the instance described by `configuration`, creating its files if they do not exist.
  init(_ configuration: MMKVConfiguration) throws(MMKVError) {
    if let encryption = configuration.encryption, !encryption.isValid {
      throw MMKVErrors.invalidEncryptionKey
    }
    LogSink.prepare()
    let opened = MMKVStorage(path: configuration.directory.path)
      .opening(id: configuration.id) {
        configuration.withCConfiguration { mmkv_open(&$0) }
      } state: {
        MMKVStoreState.shared(
          for: $0,
          id: configuration.id,
          isMultiProcess: configuration.mode == .multiProcess
        )
      }
    guard let opened else {
      throw MMKVErrors.openFailed(id: configuration.id, directory: configuration.directory)
    }
    if !configuration.isReadOnly, let protectionClass = configuration.fileProtection.cValue {
      let failures = MMKVStorage(path: configuration.directory.path)
        .setProtectionClass(protectionClass, forID: configuration.id)
      for (path, error) in failures {
        LogSink.log(.warning, "failed to set the file protection of [\(path)], errno \(error)")
      }
    }
    self.handle = opened.handle
    self.defaultExpiry = configuration.defaultExpiry
    self.state = opened.state
  }

  /// Runs an operation on the store's instance, unless the store is suspended or closed.
  ///
  /// - Returns: `nil`, without running `body`, if the store is suspended or closed.
  private func perform<R, E: Error>(
    _ body: (OpaquePointer) throws(E) -> R
  ) throws(E) -> R? {
    guard let pass = self.state.gate.enter() else { return nil }
    defer { self.state.gate.leave(pass) }
    return try body(self.handle)
  }

  /// As ``perform(_:)``, for a `body` that runs the caller's code.
  private func performScope<R, E: Error>(
    _ body: (OpaquePointer) throws(E) -> R
  ) throws(E) -> R? {
    guard let pass = self.state.gate.enterScope() else { return nil }
    defer { self.state.gate.leaveScope(pass) }
    return try body(self.handle)
  }

  /// Tells listeners about anything the core noticed while it held its locks. Called once an
  /// operation has returned.
  func operationDidFinish() {
    self.state.deliverPendingChanges()
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
    try self.performScope { (handle: OpaquePointer) throws(E) -> R? in
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

  func copyBytes(forKey key: String, into buffer: UnsafeMutableRawBufferPointer) -> Int? {
    self.perform { handle in
      var count = 0
      let hasValue = key.withMMKVBytes {
        mmkv_copy_bytes(handle, $0, buffer.baseAddress, buffer.count, &count)
      }
      return hasValue ? count : nil
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
    self.state.gate.isSuspended
  }

  func suspend() {
    guard self.state.canSuspend else { return }
    self.state.gate.suspend()
  }

  /// - Returns: Whether the store was suspended.
  func resume() -> Bool {
    self.state.gate.resume()
  }
}

// MARK: - Closing

extension MMKVCore {
  var isClosed: Bool {
    self.state.gate.isClosed
  }

  /// Turns every operation away for good, and frees the instance once nothing is using it.
  /// Every ``MMKVCore`` over the instance holds its pointer, and none uses it again.
  ///
  /// - Returns: Whether this call closed the store, rather than finding it closed.
  func close() -> Bool {
    let handle = UInt(bitPattern: self.handle)
    return self.state.gate.close { MMKVStorage.close(handle: handle) }
  }
}

// MARK: - Locking and maintenance

extension MMKVCore {
  /// Runs `body` with the instance's recursive lock held.
  ///
  /// Listeners are not told about a change while the lock is held: about an external one because
  /// a listener that waits on another thread would deadlock against it, and about a key so that
  /// they never see part of what `body` writes. They are told once the outermost call releases
  /// the lock.
  ///
  /// While the store is suspended, and once it is closed, `body` runs without the lock, and
  /// every operation in it is turned away.
  func locked<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
    let gate = self.state.gate
    guard let pass = gate.enterScope() else { return try body() }
    mmkv_lock(self.handle)
    self.state.beginDeferringChanges()
    defer {
      self.state.endDeferringChanges()
      mmkv_unlock(self.handle)
      gate.leaveScope(pass)
      self.state.deliverPendingChanges()
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

  func clearMemoryCache() {
    self.perform { mmkv_clear_memory_cache($0) }
  }

  func sync() {
    self.perform { mmkv_sync($0) }
  }

  /// The number of seconds the core should keep a key written now with `expiry` for, or zero
  /// for good. A write that names no expiry has the one this store was opened with.
  func expirySeconds(for expiry: MMKVExpiry?) -> UInt32 {
    SwiftMMKV.expirySeconds(for: expiry ?? self.defaultExpiry)
  }

  /// Whether the store's file records when each key expires.
  var isExpiryEnabled: Bool {
    self.perform { handle in
      // Another process may have changed the file's format since it was last read.
      mmkv_check_content_changed(handle)
      return mmkv_is_expiry_enabled(handle)
    } ?? false
  }

  func disableExpiry() throws(MMKVError) {
    let didDisable = self.perform { handle in
      mmkv_lock(handle)
      defer { mmkv_unlock(handle) }
      // The core keeps every key it holds, and it holds an expired key until it is asked to
      // look for them, which counting the keys does.
      _ = mmkv_count(handle)
      return mmkv_disable_expiry(handle)
    }
    guard let didDisable else { throw MMKVErrors.unavailable(self.state) }
    guard didDisable else { throw MMKVErrors.disableExpiryFailed }
  }

  func rekey(_ encryption: MMKVConfiguration.Encryption?) throws(MMKVError) {
    if let encryption, !encryption.isValid {
      throw MMKVErrors.invalidEncryptionKey
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
    guard let didRekey else { throw MMKVErrors.unavailable(self.state) }
    guard didRekey else { throw MMKVErrors.rekeyFailed }
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

extension MMKVConfiguration.FileProtection {
  /// The number Darwin gives the class, or `nil` to leave a file's class alone.
  fileprivate var cValue: Int32? {
    switch self {
    case .completeUntilFirstUserAuthentication: 3
    case .none: 4
    case .unchanged: nil
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
