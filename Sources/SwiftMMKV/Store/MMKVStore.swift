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
  /// - Throws: ``MMKVError/Code/invalidEncryptionKey`` if the encryption key is empty or too long,
  ///   or ``MMKVError/Code/openFailed`` if the store cannot be opened.
  public init(_ configuration: MMKVConfiguration) throws(MMKVError) {
    self.core = try MMKVCore(configuration)
    self.currentConfiguration = Lock(configuration)
  }

  /// Opens a new, empty single-process store in a temporary directory, for a store that does
  /// not need to last, such as one for a test or a preview.
  ///
  /// ```swift
  /// let store = try MMKVStore.temporary()
  /// ```
  ///
  /// This opens ``MMKVConfiguration/temporary(id:)``. Start from that configuration to change
  /// anything else about the store. It is a store like any other, and lasts until the system
  /// clears its temporary directory.
  ///
  /// - Parameter id: The store's identifier.
  /// - Throws: ``MMKVError/Code/openFailed`` if the store cannot be opened, which is
  ///   the case where the system's temporary directory cannot be written to. See
  ///   ``MMKVDirectory/temporary()``.
  public static func temporary(id: MMKVStore.ID = .default) throws(MMKVError) -> MMKVStore {
    try MMKVStore(.temporary(id: id))
  }

  /// The store's identifier.
  public var id: MMKVStore.ID {
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
  /// store.set("123456", forKey: "otp", expiry: .after(.seconds(30)))
  /// ```
  ///
  /// - Parameters:
  ///   - value: The value to store.
  ///   - key: The key, which must not be empty.
  ///   - expiry: How long to keep the value, or `nil` for the store's
  ///     ``MMKVConfiguration/defaultExpiry``. The first write that expires switches the store's
  ///     file to a format that react-native-mmkv has no option for, so avoid it on a store
  ///     shared with JavaScript. ``disableExpiry()`` switches it back.
  /// - Returns: Whether the value was stored. A write fails when the key is empty, the store is
  ///   read-only, or the pair exceeds the store's item size limit.
  @discardableResult
  public func set<V: MMKVValue>(
    _ value: V,
    forKey key: String,
    expiry: MMKVExpiry? = nil
  ) -> Bool {
    self.write(forKey: key) {
      self.core.set(value, forKey: key, expiresInSeconds: self.core.expirySeconds(for: expiry))
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
  public func set(bytes: RawSpan, forKey key: String, expiry: MMKVExpiry? = nil) -> Bool {
    let expiresInSeconds = self.core.expirySeconds(for: expiry)
    return self.write(forKey: key) {
      self.core.set(bytes: bytes, forKey: key, expiresInSeconds: expiresInSeconds)
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
    expiry: MMKVExpiry? = nil
  ) -> Bool {
    self.set(bytes: RawSpan(_unsafeBytes: unsafeBytes), forKey: key, expiry: expiry)
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

  /// Copies the raw bytes stored under `key` into `buffer`, if they fit, without any other
  /// copy or allocation being made on the way.
  ///
  /// ```swift
  /// let count = store.copyBytes(forKey: "avatar", into: buffer)
  /// if let count, count > buffer.count {
  ///   // Nothing was copied. Read again with a buffer of `count` bytes.
  /// }
  /// ```
  ///
  /// The bytes of a string are its UTF-8, because MMKV stores the two the same way. MMKV does
  /// not record a value's type, so a key that holds anything else gives bytes that mean nothing.
  ///
  /// - Returns: The number of bytes the value has, or `nil` if the key has no value. The bytes
  ///   were copied to the start of `buffer` if there are no more of them than `buffer` has room
  ///   for, and otherwise `buffer` is left alone.
  public func copyBytes(forKey key: String, into buffer: UnsafeMutableRawBufferPointer) -> Int? {
    defer { self.core.operationDidFinish() }
    return self.core.copyBytes(forKey: key, into: buffer)
  }

  /// The number of bytes stored under `key`, without reading them.
  ///
  /// - Returns: The count, which for a string is that of its UTF-8, or `nil` if the key has no
  ///   value.
  public func byteCount(forKey key: String) -> Int? {
    self.copyBytes(forKey: key, into: UnsafeMutableRawBufferPointer(start: nil, count: 0))
  }

  private func write(forKey key: String, _ body: () -> Bool) -> Bool {
    let didWrite = body()
    self.core.operationDidFinish()
    if didWrite {
      self.core.state.notify(key: key)
    }
    return didWrite
  }
}

// MARK: - Batches

extension MMKVStore {
  /// Reads the values stored under `keys` as `V`s, all at once.
  ///
  /// ```swift
  /// let scores = store.values(forKeys: ["score.1", "score.2"], as: Double.self)
  /// ```
  ///
  /// The store is locked once for the whole read, so the values are those the keys held at
  /// one moment, and for a multi-process store the file lock is taken once rather than once
  /// for each key.
  ///
  /// - Parameters:
  ///   - keys: The keys to read.
  ///   - type: The type to read each value as. See ``value(forKey:as:)``.
  /// - Returns: The values by key. A key is left out when it has no value or its value is not
  ///   a valid `V`.
  public func values<V: MMKVValue>(
    forKeys keys: some Sequence<String>,
    as type: V.Type = V.self
  ) -> [String: V] {
    self.core.locked {
      var values = [String: V]()
      for key in keys {
        values[key] = self.core.value(forKey: key, as: type)
      }
      return values
    }
  }

  /// Stores each value of `values` under its key, replacing any existing values, all at once.
  ///
  /// ```swift
  /// store.set(["score.1": 10.0, "score.2": 12.5])
  /// ```
  ///
  /// The store is locked once for the whole write, so nothing else reads or writes it part of
  /// the way through, and for a multi-process store the file lock is taken once rather than
  /// once for each key. Listeners are told about each key after every value has been written.
  ///
  /// The write is not atomic if the process is killed during it: the values written by then
  /// are kept.
  ///
  /// - Parameters:
  ///   - values: The values to store, by key.
  ///   - expiry: How long to keep the values. See ``set(_:forKey:expiry:)``.
  /// - Returns: Whether every value was stored. A value that cannot be stored does not stop
  ///   the others from being stored. See ``set(_:forKey:expiry:)`` for why a write fails.
  @discardableResult
  public func set<V: MMKVValue>(_ values: [String: V], expiry: MMKVExpiry? = nil) -> Bool {
    let expiresInSeconds = self.core.expirySeconds(for: expiry)
    let stored = self.core.locked {
      values.keys.filter { key in
        self.core.set(values[key]!, forKey: key, expiresInSeconds: expiresInSeconds)
      }
    }
    self.core.state.notify(keys: stored)
    return stored.count == values.count
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
  /// - Returns: Whether there was a value to remove. That is `false` for a key that had no
  ///   value, and when the store turns the removal away as it does a write.
  @discardableResult
  public func removeValue(forKey key: String) -> Bool {
    let (didRemove, didExist) = self.core.locked {
      let didExist = self.core.contains(key)
      return (self.core.remove(key), didExist)
    }
    if didRemove && didExist {
      self.core.state.notify(key: key)
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
    self.core.state.notify(keys: keys)
  }
}

// MARK: - Import

extension MMKVStore {
  /// Copies every key and value of `other` into this store, replacing the keys this store
  /// already has and leaving its other keys alone.
  ///
  /// ```swift
  /// let imported = store.importAll(from: legacyStore)
  /// ```
  ///
  /// The two stores may differ in mode and encryption. Nothing is copied when this store is
  /// read-only, or when both stores are over the same files.
  ///
  /// Listeners of this store are told about each key `other` holds.
  ///
  /// - Returns: The number of keys copied.
  @discardableResult
  public func importAll(from other: MMKVStore) -> Int {
    // The core locks both stores in an order of its own, so neither lock can be held here to
    // pin down exactly which keys it copies. A key that `other` gains or loses during the
    // import is one of those it held either before or after.
    let hasListeners = self.core.state.hasListeners
    var keys = hasListeners ? other.core.keys : []
    let count = self.core.importAll(from: other.core)
    if hasListeners && count > 0 {
      keys.formUnion(other.core.keys)
      self.core.state.notify(keys: Array(keys))
    }
    self.core.operationDidFinish()
    other.core.operationDidFinish()
    return count
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
  /// ## Batches
  ///
  /// The lock is taken once however much `body` does, which for a multi-process store means
  /// taking the file lock once rather than once for each read and write. Listeners are told
  /// about the keys `body` changed once it returns, each key once, so they never see part of
  /// what it writes. That makes this the way to read or write a batch that mixes kinds of key:
  ///
  /// ```swift
  /// try store.withExclusiveLock { store in
  ///   store[.username] = "blob"
  ///   try store.set(settings, for: .settings)
  ///   store.removeValue(forKey: "legacy")
  /// }
  /// ```
  ///
  /// The writes are not atomic if the process is killed during `body`: those made by then are
  /// kept.
  ///
  /// - Returns: The result of `body`.
  public func withExclusiveLock<R, E: Error>(
    _ body: (MMKVStore) throws(E) -> R
  ) throws(E) -> R {
    try self.core.locked { () throws(E) -> R in try body(self) }
  }

  /// Takes exclusive access to the store as ``withExclusiveLock(_:)`` does, until a matching
  /// ``unlockExclusive()`` on the same thread.
  ///
  /// This is for the package's C interface, which serves languages whose scopes are not
  /// closures. It is not public because nothing stops a caller from leaving it unbalanced.
  package func lockExclusive() {
    self.core.lockExclusive()
  }

  /// Gives up what the calling thread's last unmatched ``lockExclusive()`` took, and tells
  /// listeners about the keys that were changed once the thread has given up all it took.
  package func unlockExclusive() {
    self.core.unlockExclusive()
  }
}

// MARK: - Changes

extension MMKVStore {
  /// Calls `onChange` once for each operation that changes the store's contents, until the
  /// returned subscription is cancelled or released.
  ///
  /// ```swift
  /// let subscription = store.subscribe { batch in
  ///   if batch.isExternal { print("changed elsewhere") }
  ///   for key in batch.keys { print("changed:", key) }
  /// }
  /// ```
  ///
  /// An operation is one call, such as ``set(_:forKey:expiry:)`` or ``removeValues(forKeys:)``,
  /// or everything the body of a ``withExclusiveLock(_:)`` does. So a body that writes three
  /// keys runs `onChange` once, after all three are written, with a batch of the three.
  ///
  /// The listener is shared with every ``MMKVStore`` opened over the same files in this process.
  /// It runs on the thread that made or noticed the change, after the operation has returned,
  /// and may read and write the store.
  ///
  /// - Parameter onChange: Runs after each operation that changes the store, with what it
  ///   changed.
  public func subscribe(
    _ onChange: @escaping @Sendable (ChangeBatch) -> Void
  ) -> MMKVSubscription {
    self.core.state.subscribe { changes in
      onChange(ChangeBatch(store: self, keys: changes.keys, isExternal: changes.isExternal))
    }
  }

  /// Calls `onChange` once for each operation that may have changed the value of `key`, until
  /// the returned subscription is cancelled or released.
  ///
  /// That is each operation that sets or removes `key` through this package, and each external
  /// change that is noticed, since such a change does not say which keys it touched. The
  /// batch's ``ChangeBatch/keys`` holds `key` alone, or nothing when only an external change
  /// was noticed. In other respects this behaves like ``subscribe(_:)``.
  ///
  /// - Parameters:
  ///   - key: The key to observe.
  ///   - onChange: Runs after each such operation.
  public func subscribe(
    forKey key: String,
    _ onChange: @escaping @Sendable (ChangeBatch) -> Void
  ) -> MMKVSubscription {
    self.core.state.subscribe { changes in
      let keys = changes.keys.contains(key) ? [key] : []
      guard !keys.isEmpty || changes.isExternal else { return }
      onChange(ChangeBatch(store: self, keys: keys, isExternal: changes.isExternal))
    }
  }

  /// Calls `onChange` once for each operation that may have changed `prefix` or a key under
  /// it, until the returned subscription is cancelled or released.
  ///
  /// ```swift
  /// let subscription = store.subscribe(underKey: "settings") { batch in
  ///   settings = try? batch.decode(Settings.self, fromKeysUnder: "settings")
  /// }
  /// ```
  ///
  /// That is each operation that sets or removes such a key through this package, and each
  /// external change that is noticed, since such a change does not say which keys it touched.
  /// The batch's ``ChangeBatch/keys`` holds only the keys at or under `prefix`. An
  /// ``encode(_:intoKeysUnder:removingOtherKeys:expiry:options:)`` that writes three keys runs
  /// `onChange` once, after all three are written, and so does a ``withExclusiveLock(_:)``
  /// whose body writes them one at a time. In other respects this behaves like
  /// ``subscribe(_:)``.
  ///
  /// A key is under `prefix` when it starts with `prefix` and `separator`. An empty `prefix`
  /// has every key under it.
  ///
  /// To be given the value those keys hold, use
  /// ``subscribe(fromKeysUnder:as:options:_:)``.
  ///
  /// - Parameters:
  ///   - prefix: The start of the keys to observe.
  ///   - separator: What joins a prefix and the rest of a key.
  ///   - onChange: Runs after each such operation.
  public func subscribe(
    underKey prefix: String,
    separator: String = ".",
    _ onChange: @escaping @Sendable (ChangeBatch) -> Void
  ) -> MMKVSubscription {
    let names = KeyNames(separator: separator)
    return self.core.state.subscribe { changes in
      let keys = changes.keys.filter { names.isAtOrUnder($0, prefix) }
      guard !keys.isEmpty || changes.isExternal else { return }
      onChange(ChangeBatch(store: self, keys: keys, isExternal: changes.isExternal))
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
  /// written, and whenever an external change is noticed, since such a change does not say
  /// which keys it touched. In other respects this behaves like ``subscribe(_:)``.
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
    let subscription = self.subscribe(forKey: key) { _ in
      onChange(self.value(forKey: key, as: V.self))
    }
    onChange(self.value(forKey: key, as: V.self))
    return subscription
  }

  /// Calls `onChange` with the `Decodable` value of `key`, read with `decoder`, once before this
  /// function returns and then whenever the value may have changed, until the returned
  /// subscription is cancelled or released.
  ///
  /// ```swift
  /// let subscription = store.subscribe(forKey: "settings", as: Settings.self, with: decoder) {
  ///   switch $0 {
  ///   case .success(let settings): apply(settings ?? Settings())
  ///   case .failure(let error): report(error)
  ///   }
  /// }
  /// ```
  ///
  /// The result is a success of `nil` when the store has no value for `key`. It is a failure
  /// with whatever `decoder` throws when the stored value does not decode, and with
  /// ``MMKVError/Code/storeIsSuspended`` while the store is suspended. The subscription
  /// carries on after a failure, so a later write that decodes is delivered as a success.
  ///
  /// In other respects this behaves like ``subscribe(forKey:as:_:)``, including running with a
  /// value it was already given.
  ///
  /// - Parameters:
  ///   - key: The key to observe.
  ///   - type: The type to decode.
  ///   - decoder: The decoder that reads the value.
  ///   - onChange: Runs with the current value, and again after each change.
  public func subscribe<T: Decodable & SendableMetatype, Decoder: MMKVTopLevelDecoder & Sendable>(
    forKey key: String,
    as type: T.Type = T.self,
    with decoder: Decoder,
    _ onChange: @escaping @Sendable (Result<T?, any Error>) -> Void
  ) -> MMKVSubscription where Decoder.Input: MMKVValue {
    let subscription = self.subscribe(forKey: key) { _ in
      onChange(Result { try self.decode(T.self, forKey: key, with: decoder) })
    }
    onChange(Result { try self.decode(T.self, forKey: key, with: decoder) })
    return subscription
  }

  /// Checks whether another process, or another copy of MMKV, changed the store, reloading it
  /// and telling listeners of an external change if so.
  ///
  /// Reads and writes make the same check, so this is only needed to notice a change while the
  /// store is otherwise idle. It does nothing for a single-process store.
  public func checkForExternalChanges() {
    self.core.checkContentChanged()
    self.core.operationDidFinish()
  }
}

// MARK: - Suspension

extension MMKVStore {
  /// Whether the store is suspended.
  ///
  /// The Observation framework tracks this property, so a SwiftUI view that reads it is drawn
  /// again when the store is suspended or resumed, and `withObservationTracking` reports the
  /// change. That needs iOS 17, macOS 14, tvOS 17, watchOS 10 or visionOS 1. Observers are told
  /// on the thread that suspends or resumes the store.
  ///
  /// ```swift
  /// Text(store.isSuspended ? "Paused" : "Live")
  /// ```
  ///
  /// It is the only property the framework tracks. Use a subscription or ``changes`` for the
  /// store's values.
  public var isSuspended: Bool {
    self.core.state.observationRegistrar.access(self, keyPath: \.isSuspended)
    return self.core.isSuspended
  }

  /// Stops the store from taking its file lock, so that the process can be suspended safely.
  ///
  /// iOS terminates an app that is suspended while it holds a lock on a file in a container it
  /// shares with other processes, such as an app group's. A multi-process store takes such a
  /// lock for the length of every read and write. Suspend the store when the app is about to
  /// stop running, and resume it when the app runs again.
  ///
  /// This turns new operations away, waits for those other threads have under way, and
  /// returns once nothing holds the lock. Until ``resume()``:
  ///
  /// - Reads return `nil`, and ``keys`` and ``count`` are empty.
  /// - Writes and removals do nothing, and return `false` where they return a result.
  /// - Throwing operations throw ``MMKVError/Code/storeIsSuspended``.
  /// - ``withExclusiveLock(_:)`` runs its body without the lock.
  ///
  /// Every ``MMKVStore`` over the same files is suspended together. Suspending twice has no
  /// further effect. A single-process store takes no file lock, so suspending one does nothing
  /// and it never reports being suspended.
  ///
  /// Do not call this from inside ``withExclusiveLock(_:)``: the lock is then held until the
  /// body returns.
  public func suspend() {
    // Suspending a store that already is, or that has nothing to suspend, tells no observer.
    guard self.core.state.canSuspend, !self.core.isSuspended, !self.core.isClosed else { return }
    self.core.state.observationRegistrar.withMutation(of: self, keyPath: \.isSuspended) {
      self.core.suspend()
    }
  }

  /// Lets the store take its file lock again.
  ///
  /// Listeners are told of an external change if the store was suspended, because reads were
  /// turned away in the meantime and another process may have changed the store.
  public func resume() {
    guard self.core.isSuspended else { return }
    let didResume = self.core.state.observationRegistrar
      .withMutation(of: self, keyPath: \.isSuspended) { self.core.resume() }
    if didResume {
      self.core.state.notifyExternalChange()
    }
  }
}

// MARK: - Closing

extension MMKVStore {
  /// Whether the store has been closed.
  ///
  /// The Observation framework tracks this property as it tracks ``isSuspended``, so a SwiftUI
  /// view that reads it is drawn again when the store is closed. Observers are told on the
  /// thread that closes the store.
  public var isClosed: Bool {
    self.core.state.observationRegistrar.access(self, keyPath: \.isClosed)
    return self.core.isClosed
  }

  /// Closes the store for good, releasing its memory and its files.
  ///
  /// An open store cannot be removed, and a directory cannot restore over it. Close it first:
  ///
  /// ```swift
  /// userStore.close()
  /// try directory.removeStore(id: "user-42")
  /// ```
  ///
  /// This turns new operations away, waits for those other threads have under way, and
  /// returns once the store's files are closed. From then on:
  ///
  /// - Reads return `nil`, and ``keys`` and ``count`` are empty.
  /// - Writes and removals do nothing, and return `false` where they return a result.
  /// - Throwing operations throw ``MMKVError/Code/storeIsClosed``.
  /// - ``withExclusiveLock(_:)`` runs its body without the lock.
  /// - ``isSuspended`` is `false`, and ``suspend()`` and ``resume()`` do nothing.
  ///
  /// A closed store stays closed. Open the store again by making a new ``MMKVStore`` from its
  /// configuration, which reads the files as they then are.
  ///
  /// Every ``MMKVStore`` over the same files is closed together, including one that is made
  /// while this is waiting. Closing twice has no further effect.
  ///
  /// Listeners are told once more, of an external change, because every value now reads as
  /// `nil`. They are told nothing after that, and ``changes`` and the sequences of a key's
  /// values end.
  ///
  /// An operation that is under way finishes first, so a value another thread is in the
  /// middle of encoding into several keys is written whole. That holds for the calling thread
  /// too: called from inside ``withExclusiveLock(_:)``, or from the body of
  /// ``withBytes(forKey:_:)``, this lets the rest of that body read and write, and the store's
  /// files are closed when the body returns. Avoid calling it there all the same: if another
  /// thread is waiting for the lock, this waits for that thread, and neither can go on.
  public func close() {
    guard !self.core.isClosed else {
      // Another thread may be closing the store. This returns once it has.
      _ = self.core.close()
      return
    }
    let registrar = self.core.state.observationRegistrar
    let wasSuspended = self.core.isSuspended
    let didClose = registrar.withMutation(of: self, keyPath: \.isClosed) {
      guard wasSuspended else { return self.core.close() }
      return registrar.withMutation(of: self, keyPath: \.isSuspended) { self.core.close() }
    }
    if didClose {
      self.core.state.finishListeners()
    }
  }
}

// MARK: - Observable

/// The Observation framework tracks ``MMKVStore/isSuspended``, and none of the store's values.
///
/// The conformance lets a store be passed where SwiftUI asks for an observable object, such as
/// `environment(_:)` and `@Environment(MMKVStore.self)`.
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
extension MMKVStore: _Observable {}

// MARK: - Maintenance

extension MMKVStore {
  /// The size of the store's file in bytes, including the space no value occupies.
  ///
  /// The file grows as values are written and only shrinks when it is trimmed, by ``trim()``
  /// or by removing every key.
  public var byteSize: Int {
    defer { self.core.operationDidFinish() }
    return self.core.totalSize
  }

  /// The number of bytes of the store's file that hold data.
  ///
  /// This includes the values that removed and overwritten keys leave behind until the file is
  /// next rewritten, so it is not the size of the store's current values.
  public var usedByteSize: Int {
    defer { self.core.operationDidFinish() }
    return self.core.actualSize
  }

  /// Rewrites the store's file without the space left behind by removed and overwritten values.
  public func trim() {
    self.core.trim()
    self.core.operationDidFinish()
  }

  /// Lets go of the memory the store holds: its in-memory copy of its contents, and its mapping
  /// of its file. Nothing is lost, and the next read or write loads the file again.
  ///
  /// ```swift
  /// // On a memory warning.
  /// cacheStore.releaseMemory()
  /// ```
  ///
  /// This is for a store that is large or seldom used, when the system reports that memory is
  /// short. Loading the file again costs as much as opening the store did, so calling this on a
  /// store that is about to be read gains nothing.
  ///
  /// The store's contents do not change, so listeners are not told anything. Every
  /// ``MMKVStore`` over the same files shares the memory this lets go of. A suspended or closed
  /// store turns this away like any other operation, so it does nothing to either.
  public func releaseMemory() {
    self.core.clearMemoryCache()
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

  /// Whether the store's file records when each key expires, which it does from the first
  /// write that expires until ``disableExpiry()``. A suspended store answers `false`.
  public var isExpiryEnabled: Bool {
    defer { self.core.operationDidFinish() }
    return self.core.isExpiryEnabled
  }

  /// Rewrites the store's file in the format it had before its first expiring write, which is
  /// the format react-native-mmkv reads.
  ///
  /// Keys that have expired are dropped, and every other key is kept until it is removed,
  /// whatever expiry it was written with. The next write that expires switches the file back,
  /// so a store with a ``MMKVConfiguration/defaultExpiry`` stays this way only until it is
  /// next written to.
  ///
  /// - Throws: ``MMKVError/Code/disableExpiryFailed`` if the store could not be rewritten, or
  ///   ``MMKVError/Code/storeIsSuspended`` if the store is suspended.
  public func disableExpiry() throws(MMKVError) {
    defer { self.core.operationDidFinish() }
    try self.core.disableExpiry()
  }

  /// Re-encrypts the store with `encryption`, or decrypts it when `encryption` is `nil`.
  ///
  /// - Throws: ``MMKVError/Code/invalidEncryptionKey`` if the key is empty or too long,
  ///   ``MMKVError/Code/rekeyFailed`` if the store could not be rewritten, or
  ///   ``MMKVError/Code/storeIsSuspended`` if the store is suspended.
  public func rekey(_ encryption: MMKVConfiguration.Encryption?) throws(MMKVError) {
    defer { self.core.operationDidFinish() }
    try self.core.rekey(encryption)
    self.currentConfiguration.withLock { $0.encryption = encryption }
  }
}

// MARK: - Backups

extension MMKVStore {
  /// Copies the store's files into `backup`, replacing a copy that is already there.
  ///
  /// ```swift
  /// let backups = MMKVDirectory(path: documentsPath + "/mmkv-backup")
  /// try store.backUp(to: backups)
  /// ```
  ///
  /// See ``MMKVDirectory/backUpStore(id:to:)``.
  ///
  /// - Throws: ``MMKVError/Code/backupFailed`` if the files could not be
  ///   copied, ``MMKVError/Code/storeIsOpen`` if this process has the copy in `backup`
  ///   open, ``MMKVError/Code/storeIsSuspended`` if the store is suspended, or
  ///   ``MMKVError/Code/backupIsStoreDirectory`` if `backup` is the store's directory.
  public func backUp(to backup: MMKVDirectory) throws(MMKVError) {
    try self.checkIsNotClosed()
    let configuration = self.configuration
    guard try configuration.directory.backUpStore(id: configuration.id, to: backup) else {
      throw MMKVErrors.backupFailed(
        id: configuration.id,
        directory: configuration.directory,
        backup: backup
      )
    }
  }

  /// Replaces the store's contents with those of its copy in `backup`.
  ///
  /// Every ``MMKVStore`` over the same files reads the restored values afterwards, and the
  /// store's listeners are told of an external change. See
  /// ``MMKVDirectory/restoreStore(id:from:)``.
  ///
  /// - Returns: Whether `backup` held a copy of the store.
  /// - Throws: ``MMKVError/Code/backupInvalid`` if the copy does not match its
  ///   checksum, ``MMKVError/Code/restoreFailed`` if the store could not be
  ///   overwritten, which includes a read-only store, ``MMKVError/Code/storeIsSuspended`` if
  ///   the store is suspended, or ``MMKVError/Code/backupIsStoreDirectory`` if `backup` is the
  ///   store's directory.
  @discardableResult
  public func restore(from backup: MMKVDirectory) throws(MMKVError) -> Bool {
    try self.checkIsNotClosed()
    let configuration = self.configuration
    return try configuration.directory.restoreStore(id: configuration.id, from: backup)
  }

  /// The directory would otherwise copy the files of a store that this one no longer is.
  private func checkIsNotClosed() throws(MMKVError) {
    if self.core.isClosed {
      throw MMKVErrors.storeIsClosed(id: self.id)
    }
  }
}
