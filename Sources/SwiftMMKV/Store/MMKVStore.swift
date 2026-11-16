import CSwiftMMKVCore

/// A key-value store backed by MMKV's memory-mapped files.
///
/// A store is safe to use from any thread. Values are read and written by naming a type that
/// conforms to ``MMKVValue``, because the file itself records no types:
///
/// ```swift
/// let store = try MMKVStore(
///   MMKVConfiguration(rootDirectory: "/path/to/app/files/mmkv", mode: .singleProcess)
/// )
///
/// store.set("blob", forKey: "username")
/// store.set(0.8, forKey: "volume")
///
/// let username = store.value(forKey: "username", as: String.self)
/// let volume = store["volume", as: Double.self] ?? 1
/// ```
///
/// Opening the same root directory and identifier again returns a store over the same underlying
/// instance, so both see each other's writes and share change listeners. A store's files stay
/// open for the rest of the process.
///
/// ## Sharing a store with React Native
///
/// An app that links react-native-mmkv has two copies of MMKV in one process. Open the store
/// with ``MMKVConfiguration/Mode-swift.enum/multiProcess`` here and `mode: 'multi-process'` in
/// JavaScript, and write the types JavaScript reads: `Double` for numbers, `Bool`, `String`, and
/// raw bytes for an `ArrayBuffer`.
public final class MMKVStore: Sendable {
  nonisolated(unsafe) let handle: OpaquePointer
  let state: MMKVStoreState
  private let currentConfiguration: Lock<MMKVConfiguration>

  /// Opens the store described by `configuration`, creating its files if they do not exist.
  ///
  /// - Throws: ``MMKVError/invalidEncryptionKey`` if the encryption key is empty or too long,
  ///   or ``MMKVError/openFailed(id:rootDirectory:)`` if the store cannot be opened.
  public init(_ configuration: MMKVConfiguration) throws(MMKVError) {
    if let encryption = configuration.encryption, !encryption.isValid {
      throw .invalidEncryptionKey
    }
    let handle = configuration.withCConfiguration { swiftmmkv_open(&$0) }
    guard let handle else {
      throw .openFailed(id: configuration.id, rootDirectory: configuration.rootDirectory)
    }
    self.handle = handle
    self.state = MMKVStoreState.shared(for: handle, id: configuration.id)
    self.currentConfiguration = Lock(configuration)
  }

  /// The store's identifier.
  public var id: String {
    self.state.id
  }

  /// The configuration this store was opened with, updated by ``rekey(_:)``.
  ///
  /// If the store was already open, the underlying instance keeps the configuration of its
  /// first open, which this value does not reflect.
  public var configuration: MMKVConfiguration {
    self.currentConfiguration.withLock { $0 }
  }

  /// Runs once an operation has returned, to tell listeners about anything the core noticed
  /// while it held its locks.
  func operationDidFinish() {
    self.state.deliverPendingExternalChange()
  }
}

// MARK: - Values

extension MMKVStore {
  /// Stores `value` under `key`, replacing any existing value.
  ///
  /// ```swift
  /// store.set(true, forKey: "hasOnboarded")
  /// store.set("123456", forKey: "otp", expiringIn: .seconds(30))
  /// ```
  ///
  /// - Parameters:
  ///   - value: The value to store.
  ///   - key: The key, which must not be empty.
  ///   - expiringIn: How long to keep the value, rounded up to a whole second, or `nil` to keep
  ///     it until it is removed. The first expiring write switches the store's file to a format
  ///     that react-native-mmkv has no option for, so avoid it on a store shared with
  ///     JavaScript.
  /// - Returns: Whether the value was stored. A write fails when the key is empty, the store is
  ///   read-only, or the pair exceeds the store's item size limit.
  @discardableResult
  public func set<V: MMKVValue>(
    _ value: V,
    forKey key: String,
    expiringIn: Duration? = nil
  ) -> Bool {
    self.write(forKey: key, expiringIn: expiringIn) { value.write(to: &$0) }
  }

  /// Reads the value stored under `key` as a `V`.
  ///
  /// The file stores no type information, so `type` must be the type the value was written
  /// with. Numeric types return a value for any key that exists.
  ///
  /// - Returns: The value, or `nil` if the key has no value or its value is not a valid `V`.
  public func value<V: MMKVValue>(forKey key: String, as type: V.Type = V.self) -> V? {
    defer { self.operationDidFinish() }
    return V(from: MMKVValueReader(store: self, key: key))
  }

  /// Reads or writes the value stored under `key` as a `V`. Assigning `nil` removes the key.
  ///
  /// ```swift
  /// store["volume"] = 0.5
  /// let volume = store["volume", as: Double.self]
  /// ```
  public subscript<V: MMKVValue>(key: String, as type: V.Type = V.self) -> V? {
    get {
      self.value(forKey: key, as: type)
    }
    set {
      if let newValue {
        self.set(newValue, forKey: key)
      } else {
        self.removeValue(forKey: key)
      }
    }
  }

  /// Stores raw bytes under `key`, replacing any existing value.
  ///
  /// - Returns: Whether the bytes were stored.
  @discardableResult
  public func set(bytes: RawSpan, forKey key: String, expiringIn: Duration? = nil) -> Bool {
    bytes.withUnsafeBytes { buffer in
      self.write(forKey: key, expiringIn: expiringIn) { $0.set(buffer: buffer) }
    }
  }

  /// Reads the raw bytes stored under `key`, which are only valid for the duration of `body`.
  ///
  /// ```swift
  /// let count = store.withBytes(forKey: "avatar") { $0.byteCount }
  /// ```
  ///
  /// - Returns: The result of `body`, or `nil` if the key has no value.
  public func withBytes<R, E: Error>(
    forKey key: String,
    _ body: (RawSpan) throws(E) -> R
  ) throws(E) -> R? {
    defer { self.operationDidFinish() }
    return try MMKVValueReader(store: self, key: key).withBytes(body)
  }

  func write(
    forKey key: String,
    expiringIn: Duration?,
    _ body: (inout MMKVValueWriter) -> Bool
  ) -> Bool {
    var writer = MMKVValueWriter(
      store: self,
      key: key,
      expiresInSeconds: expiringIn?.mmkvExpirySeconds ?? 0
    )
    let didWrite = body(&writer)
    self.operationDidFinish()
    if didWrite {
      self.state.notify(.key(key))
    }
    return didWrite
  }
}

// MARK: - Keys

extension MMKVStore {
  /// Every key in the store. MMKV keeps keys in no particular order.
  public var keys: Set<String> {
    defer { self.operationDidFinish() }
    return self.unnotifiedKeys
  }

  /// The number of keys in the store.
  public var count: Int {
    defer { self.operationDidFinish() }
    return swiftmmkv_count(self.handle)
  }

  /// Whether `key` has a value.
  public func contains(_ key: String) -> Bool {
    defer { self.operationDidFinish() }
    return key.withMMKVBytes { swiftmmkv_contains(self.handle, $0) }
  }

  var unnotifiedKeys: Set<String> {
    var keys = Set<String>()
    _ = forEachCallbackBytes { context, callback in
      swiftmmkv_keys(self.handle, context, callback)
      return true
    } _: { buffer in
      keys.insert(String(decoding: buffer, as: UTF8.self))
    }
    return keys
  }
}

// MARK: - Removal

extension MMKVStore {
  /// Removes `key` and its value.
  ///
  /// - Returns: Whether the store accepted the removal. MMKV also reports success for a key
  ///   that had no value.
  @discardableResult
  public func removeValue(forKey key: String) -> Bool {
    let (didRemove, didExist) = self.locked {
      let didExist = key.withMMKVBytes { swiftmmkv_contains(self.handle, $0) }
      return (key.withMMKVBytes { swiftmmkv_remove(self.handle, $0) }, didExist)
    }
    self.operationDidFinish()
    if didRemove && didExist {
      self.state.notify(.key(key))
    }
    return didRemove
  }

  /// Removes every key in `keys` and its value.
  public func removeValues(forKeys keys: some Sequence<String>) {
    let removed = self.locked {
      let existing = keys.filter { key in
        key.withMMKVBytes { swiftmmkv_contains(self.handle, $0) }
      }
      self.remove(existing)
      return existing
    }
    self.didRemove(removed)
  }

  /// Removes every key and value.
  ///
  /// - Parameter keepingCapacity: Whether to keep the file at its current size, which is faster
  ///   and saves growing it again. By default the file shrinks back to its initial size.
  public func removeAll(keepingCapacity: Bool = false) {
    let removed = self.locked {
      // The keys are only needed to tell listeners what changed.
      let keys = self.state.hasListeners ? Array(self.unnotifiedKeys) : []
      swiftmmkv_remove_all(self.handle, keepingCapacity)
      return keys
    }
    self.didRemove(removed)
  }

  /// Removes every key for which `shouldRemove` returns `true`.
  ///
  /// The predicate only sees keys, because a value cannot be read without knowing its type. It
  /// runs with the store locked, so nothing can add or remove keys in between.
  ///
  /// ```swift
  /// store.removeAll { $0.hasPrefix("cache.") }
  /// ```
  ///
  /// - Parameters:
  ///   - keepingCapacity: Whether to leave the file as it is. Removing keys never shrinks an
  ///     MMKV file by itself, so by default the file is trimmed afterwards.
  ///   - shouldRemove: Returns whether to remove a key.
  public func removeAll<E: Error>(
    keepingCapacity: Bool = false,
    where shouldRemove: (String) throws(E) -> Bool
  ) throws(E) {
    let removed = try self.locked { () throws(E) -> [String] in
      var matches = [String]()
      for key in self.unnotifiedKeys where try shouldRemove(key) {
        matches.append(key)
      }
      self.remove(matches)
      if !keepingCapacity && !matches.isEmpty {
        swiftmmkv_trim(self.handle)
      }
      return matches
    }
    self.didRemove(removed)
  }

  private func remove(_ keys: [String]) {
    guard !keys.isEmpty else { return }
    keys.withMMKVBytes { keys in
      _ = swiftmmkv_remove_many(self.handle, keys.baseAddress, keys.count)
    }
  }

  private func didRemove(_ keys: [String]) {
    self.operationDidFinish()
    for key in keys {
      self.state.notify(.key(key))
    }
  }
}

// MARK: - Locking

extension MMKVStore {
  /// Runs `body` with exclusive access to the store.
  ///
  /// Nothing else can read or write the store until `body` returns: not another thread, and,
  /// for a multi-process store, not another process or another copy of MMKV in this process.
  /// Use it for a read-modify-write that must not be interleaved. The lock is recursive, so
  /// `body` may call any method of the store it is given, including this one.
  ///
  /// ```swift
  /// store.withExclusiveLock { store in
  ///   let count = store.value(forKey: "launchCount", as: Double.self) ?? 0
  ///   store.set(count + 1, forKey: "launchCount")
  /// }
  /// ```
  ///
  /// - Returns: The result of `body`.
  public func withExclusiveLock<R, E: Error>(
    _ body: (MMKVStore) throws(E) -> R
  ) throws(E) -> R {
    try self.locked { () throws(E) -> R in try body(self) }
  }

  func locked<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
    swiftmmkv_lock(self.handle)
    defer { swiftmmkv_unlock(self.handle) }
    return try body()
  }
}

// MARK: - Changes

extension MMKVStore {
  /// A change to a store's contents.
  public enum Change: Sendable, Hashable {
    /// The value of a key was set or removed through this package, in this process.
    case key(String)

    /// Another process, or another copy of MMKV in this process, changed the store. Which keys
    /// changed is not known.
    ///
    /// A store only notices such a change when it is next read or written, or when
    /// ``MMKVStore/checkForExternalChanges()`` is called. Several changes may be reported as
    /// one.
    case external
  }

  /// Calls `onChange` whenever the store's contents change, until the returned subscription is
  /// cancelled or released.
  ///
  /// The listener is shared with every ``MMKVStore`` opened over the same files in this process.
  /// It runs on the thread that made or noticed the change, after the operation has returned,
  /// and may read and write the store.
  ///
  /// ```swift
  /// let subscription = store.subscribe { change in
  ///   switch change {
  ///   case .key(let key): print("changed:", key)
  ///   case .external: print("changed elsewhere")
  ///   }
  /// }
  /// ```
  public func subscribe(
    _ onChange: @escaping @Sendable (Change) -> Void
  ) -> MMKVSubscription {
    self.state.subscribe(onChange)
  }

  /// Checks whether another process, or another copy of MMKV, changed the store, reloading it
  /// and notifying listeners with ``Change/external`` if so.
  ///
  /// Reads and writes make the same check, so this is only needed to notice a change while the
  /// store is otherwise idle. It does nothing for a single-process store.
  public func checkForExternalChanges() {
    swiftmmkv_check_content_changed(self.handle)
    self.operationDidFinish()
  }
}

// MARK: - Maintenance

extension MMKVStore {
  /// Rewrites the store's file without the space left behind by removed and overwritten values.
  public func trim() {
    swiftmmkv_trim(self.handle)
    self.operationDidFinish()
  }

  /// Blocks until the store's contents are flushed to disk.
  ///
  /// The operating system flushes a memory-mapped file by itself, even if the process crashes,
  /// so this only matters when the device may lose power.
  public func sync() {
    swiftmmkv_sync(self.handle)
    self.operationDidFinish()
  }

  /// Re-encrypts the store with `encryption`, or decrypts it when `encryption` is `nil`.
  ///
  /// - Throws: ``MMKVError/invalidEncryptionKey`` if the key is empty or too long, or
  ///   ``MMKVError/rekeyFailed`` if the store could not be rewritten.
  public func rekey(_ encryption: MMKVConfiguration.Encryption?) throws(MMKVError) {
    if let encryption, !encryption.isValid {
      throw .invalidEncryptionKey
    }
    let key = encryption?.key ?? []
    let didRekey = key.withUnsafeBytes { key in
      swiftmmkv_rekey(
        self.handle,
        encryption.cValue,
        swiftmmkv_bytes(bytes: key.baseAddress, count: key.count)
      )
    }
    self.operationDidFinish()
    guard didRekey else { throw .rekeyFailed }
    self.currentConfiguration.withLock { $0.encryption = encryption }
  }
}

// MARK: - C configuration

extension MMKVConfiguration.Encryption? {
  fileprivate var cValue: Int32 {
    switch self {
    case nil: Int32(SWIFTMMKV_ENCRYPTION_NONE)
    case .aes128: Int32(SWIFTMMKV_ENCRYPTION_AES128)
    case .aes256: Int32(SWIFTMMKV_ENCRYPTION_AES256)
    }
  }
}

extension MMKVConfiguration {
  fileprivate func withCConfiguration<R>(_ body: (inout swiftmmkv_configuration) -> R) -> R {
    self.id.withMMKVBytes { id in
      self.rootDirectory.withMMKVBytes { rootDirectory in
        (self.encryption?.key ?? []).withUnsafeBytes { key in
          var configuration = swiftmmkv_configuration(
            id: id,
            root_directory: rootDirectory,
            multi_process: self.mode == .multiProcess,
            read_only: self.isReadOnly,
            encryption: self.encryption.cValue,
            encryption_key: swiftmmkv_bytes(bytes: key.baseAddress, count: key.count),
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
