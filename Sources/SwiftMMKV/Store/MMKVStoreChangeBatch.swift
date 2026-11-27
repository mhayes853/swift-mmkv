// MARK: - ChangeBatch

extension MMKVStore {
  /// What one operation changed in a store, as ``MMKVStore/subscribe(_:)`` and
  /// ``MMKVStore/changes`` report it.
  ///
  /// An operation is one call, such as ``MMKVStore/set(_:forKey:expiry:)``, or everything the
  /// body of a ``MMKVStore/withExclusiveLock(_:)`` does.
  ///
  /// ```swift
  /// let subscription = store.subscribe { batch in
  ///   for key in batch.keys {
  ///     print(key, batch.value(forKey: key, as: String.self) ?? "removed")
  ///   }
  /// }
  /// ```
  ///
  /// ## Reading values
  ///
  /// A batch reads from the store it came from, in every way the store itself is read. Each
  /// read gives the value the store holds when it is made. That is the value the operation
  /// wrote unless something has written the key since, which another thread or process may
  /// have done by the time a listener runs.
  public struct ChangeBatch: Sendable {
    private let store: MMKVStore

    /// The keys that were set or removed through this package, in this process. Each key is
    /// here once, however often the operation changed it.
    ///
    /// The batch of a subscription to one key, or to the keys under a prefix, holds only the
    /// keys that subscription observes. It is empty when only an external change was noticed.
    public let keys: [String]

    /// Whether another process, or another copy of MMKV in this process, changed the store.
    /// Which keys it changed is not known, so any key may have changed and not only ``keys``.
    ///
    /// A store only notices such a change when it is next read or written, or when
    /// ``MMKVStore/checkForExternalChanges()`` is called. Several such changes may be reported
    /// as one. A store that is resumed, closed or restored from a backup also reports one,
    /// because any of its values may read differently afterwards.
    public let isExternal: Bool

    /// Creates a batch, as a store does for its listeners.
    ///
    /// This is of use for calling a listener directly, for instance in a test.
    ///
    /// - Parameters:
    ///   - store: The store the batch reads values from.
    ///   - keys: The keys that were set or removed.
    ///   - isExternal: Whether the store was changed from outside this package.
    public init(store: MMKVStore, keys: [String], isExternal: Bool = false) {
      self.store = store
      self.keys = keys
      self.isExternal = isExternal
    }
  }
}

// MARK: - Values

extension MMKVStore.ChangeBatch {
  /// Reads the value the store now holds for `key`, as ``MMKVStore/value(forKey:as:)`` does.
  ///
  /// - Returns: `nil` if the store has no value for `key`, which is the case once it is
  ///   removed, or if its value is not a valid `V`.
  public func value<V: MMKVValue>(forKey key: String, as type: V.Type = V.self) -> V? {
    self.store.value(forKey: key, as: type)
  }

  /// Reads the value the store now holds for `key`, as ``MMKVStore/value(for:)-(Key<V>)``
  /// does.
  public func value<V>(for key: MMKVStore.Key<V>) -> V? {
    self.store.value(for: key)
  }

  /// Reads the value the store now holds for `key`, or the key's default value, as
  /// ``MMKVStore/value(for:)-(DefaultedKey<V>)`` does.
  public func value<V>(for key: MMKVStore.DefaultedKey<V>) -> V {
    self.store.value(for: key)
  }

  /// Decodes the value the store now holds for `key`, as
  /// ``MMKVStore/value(for:)-(CodedKey<V>)`` does.
  ///
  /// - Throws: What the key's decoder throws for a value it cannot read, and an ``MMKVError``
  ///   when the store is suspended or closed.
  public func value<V>(for key: MMKVStore.CodedKey<V>) throws -> V? {
    try self.store.value(for: key)
  }

  /// Decodes the value the store now holds for `key`, or gives the key's default value, as
  /// ``MMKVStore/value(for:)-(DefaultedCodedKey<V>)`` does.
  ///
  /// - Throws: What the key's decoder throws for a value it cannot read, and an ``MMKVError``
  ///   when the store is suspended or closed.
  public func value<V>(for key: MMKVStore.DefaultedCodedKey<V>) throws -> V {
    try self.store.value(for: key)
  }
}

// MARK: - Decoding

extension MMKVStore.ChangeBatch {
  /// Decodes the value the store now holds for `key` with `decoder`, as
  /// ``MMKVStore/decode(_:forKey:with:)`` does.
  ///
  /// - Returns: `nil` if the store has no value for `key`.
  /// - Throws: What `decoder` throws for a value it cannot read, and an ``MMKVError`` when the
  ///   store is suspended or closed.
  public func decode<T: Decodable, Decoder: MMKVTopLevelDecoder>(
    _ type: T.Type = T.self,
    forKey key: String,
    with decoder: Decoder
  ) throws -> T? where Decoder.Input: MMKVValue {
    try self.store.decode(type, forKey: key, with: decoder)
  }

  /// Decodes the value the store now holds in `prefix` and the keys under it, as
  /// ``MMKVStore/decode(_:fromKeysUnder:options:)`` does.
  ///
  /// ```swift
  /// let subscription = store.subscribe(underKey: "settings") { batch in
  ///   settings = try? batch.decode(Settings.self, fromKeysUnder: "settings")
  /// }
  /// ```
  ///
  /// - Throws: What decoding throws, and an ``MMKVError`` when the store is suspended or
  ///   closed.
  public func decode<T: Decodable>(
    _ type: T.Type = T.self,
    fromKeysUnder prefix: String,
    options: MMKVKeyCodingOptions = MMKVKeyCodingOptions()
  ) throws -> T {
    try self.store.decode(type, fromKeysUnder: prefix, options: options)
  }
}
