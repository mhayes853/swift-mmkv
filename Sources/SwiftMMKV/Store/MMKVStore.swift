/// A key-value store backed by MMKV's memory-mapped files.
///
/// A store is safe to use from any thread. Values are read and written by naming a type that
/// conforms to ``MMKVValue``, because the file itself records no types:
///
/// ```swift
/// let store = try MMKVStore(
///   MMKVConfiguration(
///     directory: MMKVDirectory(path: "/path/to/app/files/mmkv"),
///     mode: .singleProcess
///   )
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
  private let core: MMKVCore
  private let currentConfiguration: Lock<MMKVConfiguration>

  /// Opens the store described by `configuration`, creating its files if they do not exist.
  ///
  /// - Throws: ``MMKVError/invalidEncryptionKey`` if the encryption key is empty or too long,
  ///   or ``MMKVError/openFailed(id:directory:)`` if the store cannot be opened.
  public init(_ configuration: MMKVConfiguration) throws(MMKVError) {
    self.core = try MMKVCore(configuration)
    self.currentConfiguration = Lock(configuration)
  }

  /// The store's identifier.
  public var id: String {
    self.core.state.id
  }

  /// The configuration this store was opened with, updated by ``rekey(_:)``.
  ///
  /// If the store was already open, the underlying instance keeps the configuration of its
  /// first open, which this value does not reflect.
  public var configuration: MMKVConfiguration {
    self.currentConfiguration.withLock { $0 }
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
    self.write(forKey: key) {
      self.core.set(value, forKey: key, expiresInSeconds: expiringIn.mmkvExpirySeconds)
    }
  }

  /// Reads the value stored under `key` as a `V`.
  ///
  /// The file stores no type information, so `type` must be the type the value was written
  /// with. Numeric types return a value for any key that exists.
  ///
  /// - Returns: The value, or `nil` if the key has no value or its value is not a valid `V`.
  public func value<V: MMKVValue>(forKey key: String, as type: V.Type = V.self) -> V? {
    defer { self.core.operationDidFinish() }
    return self.core.value(forKey: key, as: type)
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
    self.write(forKey: key) {
      self.core.set(bytes: bytes, forKey: key, expiresInSeconds: expiringIn.mmkvExpirySeconds)
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
    defer { self.core.operationDidFinish() }
    return try self.core.withBytes(forKey: key, body)
  }

  /// Stores the raw bytes in `unsafeBytes` under `key`, replacing any existing value.
  ///
  /// MMKV copies the bytes into its file before this returns, so the buffer only has to be
  /// valid for the duration of the call.
  ///
  /// - Returns: Whether the bytes were stored.
  @discardableResult
  public func set(
    unsafeBytes: UnsafeRawBufferPointer,
    forKey key: String,
    expiringIn: Duration? = nil
  ) -> Bool {
    self.set(bytes: RawSpan(_unsafeBytes: unsafeBytes), forKey: key, expiringIn: expiringIn)
  }

  /// Reads the raw bytes stored under `key` through a buffer pointer, which is only valid for
  /// the duration of `body`.
  ///
  /// Prefer ``withBytes(forKey:_:)`` unless the bytes are being handed to an API that takes a
  /// pointer.
  ///
  /// ```swift
  /// store.withUnsafeBytes(forKey: "avatar") { buffer in
  ///   write(fileDescriptor, buffer.baseAddress, buffer.count)
  /// }
  /// ```
  ///
  /// - Returns: The result of `body`, or `nil` if the key has no value.
  public func withUnsafeBytes<R, E: Error>(
    forKey key: String,
    _ body: (UnsafeRawBufferPointer) throws(E) -> R
  ) throws(E) -> R? {
    try self.withBytes(forKey: key) { (bytes: RawSpan) throws(E) -> R in
      try bytes.withUnsafeBytes(body)
    }
  }

  private func write(forKey key: String, _ body: () -> Bool) -> Bool {
    let didWrite = body()
    self.core.operationDidFinish()
    if didWrite {
      self.core.state.notify(.key(key))
    }
    return didWrite
  }
}

// MARK: - Keys

extension MMKVStore {
  /// Every key in the store. MMKV keeps keys in no particular order.
  public var keys: Set<String> {
    defer { self.core.operationDidFinish() }
    return self.core.keys
  }

  /// The number of keys in the store.
  public var count: Int {
    defer { self.core.operationDidFinish() }
    return self.core.count
  }

  /// Whether `key` has a value.
  public func contains(_ key: String) -> Bool {
    defer { self.core.operationDidFinish() }
    return self.core.contains(key)
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
    let (didRemove, didExist) = self.core.locked {
      let didExist = self.core.contains(key)
      return (self.core.remove(key), didExist)
    }
    if didRemove && didExist {
      self.core.state.notify(.key(key))
    }
    return didRemove
  }

  /// Removes every key in `keys` and its value.
  public func removeValues(forKeys keys: some Sequence<String>) {
    let removed = self.core.locked {
      let existing = keys.filter { self.core.contains($0) }
      self.core.remove(existing)
      return existing
    }
    self.didRemove(removed)
  }

  /// Removes every key and value.
  ///
  /// - Parameter keepingCapacity: Whether to keep the file at its current size, which is faster
  ///   and saves growing it again. By default the file shrinks back to its initial size.
  public func removeAll(keepingCapacity: Bool = false) {
    let removed = self.core.locked {
      // The keys are only needed to tell listeners what changed.
      let keys = self.core.state.hasListeners ? Array(self.core.keys) : []
      self.core.removeAll(keepingCapacity: keepingCapacity)
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
    let removed = try self.core.locked { () throws(E) -> [String] in
      var matches = [String]()
      for key in self.core.keys where try shouldRemove(key) {
        matches.append(key)
      }
      self.core.remove(matches)
      if !keepingCapacity && !matches.isEmpty {
        self.core.trim()
      }
      return matches
    }
    self.didRemove(removed)
  }

  private func didRemove(_ keys: [String]) {
    for key in keys {
      self.core.state.notify(.key(key))
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
    try self.core.locked { () throws(E) -> R in try body(self) }
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
    self.core.state.subscribe(onChange)
  }

  /// Calls `onChange` whenever the value of `key` may have changed, until the returned
  /// subscription is cancelled or released.
  ///
  /// That is whenever `key` is set or removed through this package, and whenever a
  /// ``Change/external`` change is noticed, since such a change does not say which keys it
  /// touched. In other respects this behaves like ``subscribe(_:)``.
  ///
  /// - Parameters:
  ///   - key: The key to observe.
  ///   - onChange: Runs after each change.
  public func subscribe(
    forKey key: String,
    _ onChange: @escaping @Sendable () -> Void
  ) -> MMKVSubscription {
    self.subscribe { change in
      if case .key(let changed) = change, changed != key { return }
      onChange()
    }
  }

  /// Calls `onChange` with the value of `key`, once before this function returns and then
  /// whenever the value may have changed, until the returned subscription is cancelled or
  /// released.
  ///
  /// ```swift
  /// let subscription = store.subscribe(forKey: "volume", as: Double.self) { volume in
  ///   player.volume = volume ?? 1
  /// }
  /// ```
  ///
  /// The value is `nil` when the store has no value for `key`, or when its value is not a
  /// valid `V`. `onChange` may be given the value it was last given: it runs whenever `key` is
  /// written, and whenever a ``Change/external`` change is noticed, since such a change does
  /// not say which keys it touched. In other respects this behaves like ``subscribe(_:)``.
  ///
  /// - Parameters:
  ///   - key: The key to observe.
  ///   - type: The type to read the value as.
  ///   - onChange: Runs with the current value, and again after each change.
  public func subscribe<V: MMKVValue & SendableMetatype>(
    forKey key: String,
    as type: V.Type = V.self,
    _ onChange: @escaping @Sendable (V?) -> Void
  ) -> MMKVSubscription {
    let subscription = self.subscribe(forKey: key) {
      onChange(self.value(forKey: key, as: V.self))
    }
    onChange(self.value(forKey: key, as: V.self))
    return subscription
  }

  /// Checks whether another process, or another copy of MMKV, changed the store, reloading it
  /// and notifying listeners with ``Change/external`` if so.
  ///
  /// Reads and writes make the same check, so this is only needed to notice a change while the
  /// store is otherwise idle. It does nothing for a single-process store.
  public func checkForExternalChanges() {
    self.core.checkContentChanged()
    self.core.operationDidFinish()
  }
}

// MARK: - Maintenance

extension MMKVStore {
  /// Rewrites the store's file without the space left behind by removed and overwritten values.
  public func trim() {
    self.core.trim()
    self.core.operationDidFinish()
  }

  /// Blocks until the store's contents are flushed to disk.
  ///
  /// The operating system flushes a memory-mapped file by itself, even if the process crashes,
  /// so this only matters when the device may lose power.
  public func sync() {
    self.core.sync()
    self.core.operationDidFinish()
  }

  /// Re-encrypts the store with `encryption`, or decrypts it when `encryption` is `nil`.
  ///
  /// - Throws: ``MMKVError/invalidEncryptionKey`` if the key is empty or too long, or
  ///   ``MMKVError/rekeyFailed`` if the store could not be rewritten.
  public func rekey(_ encryption: MMKVConfiguration.Encryption?) throws(MMKVError) {
    defer { self.core.operationDidFinish() }
    try self.core.rekey(encryption)
    self.currentConfiguration.withLock { $0.encryption = encryption }
  }
}
