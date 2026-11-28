// MARK: - ChangeBatch

extension MMKVStore {
  /// One change to a store, as ``MMKVStore/subscribe(_:)`` and ``MMKVStore/changes`` report
  /// it: the keys one operation set or removed, the keys another process set or removed, or a
  /// change that may have touched any key.
  ///
  /// An operation is one call, such as ``MMKVStore/set(_:forKey:expiry:)``, or everything the
  /// body of a ``MMKVStore/withExclusiveLock(_:)`` does.
  ///
  /// ```swift
  /// let subscription = store.subscribe { batch in
  ///   switch batch.kind {
  ///   case .localKeys(let keys): upload(keys)
  ///   case .externalKeys(let keys): refresh(keys)
  ///   case .wholeStore(.closed): stopObserving()
  ///   case .wholeStore: reloadEverything()
  ///   }
  /// }
  /// ```
  ///
  /// A batch is only ever one kind of change. An operation that notices another process's
  /// changes before making its own is reported as two batches: the external one first, and
  /// then its own.
  ///
  /// ## Reading values
  ///
  /// A batch reads from the store it came from, in every way the store itself is read. Each
  /// read gives the value the store holds when it is made. That is the value the change wrote
  /// unless something has written the key since, which another thread or process may have done
  /// by the time a listener runs.
  public struct ChangeBatch: Sendable {
    private let store: MMKVStore

    /// What changed.
    public let kind: Kind

    package init(store: MMKVStore, kind: Kind) {
      self.store = store
      self.kind = kind
    }
  }
}

// MARK: - Kind

extension MMKVStore.ChangeBatch {
  /// What a ``MMKVStore/ChangeBatch`` changed.
  public enum Kind: Hashable, Sendable {
    /// One operation set or removed these keys, through this package, in this process. Each
    /// key is here once, in the order it first changed.
    case localKeys([String])

    /// Another process, or another copy of MMKV in this process, set or removed these keys.
    /// Each key is here once.
    ///
    /// Only stores on the Swift engine report this. A store only notices such a change when it
    /// is next read or written, or when ``MMKVStore/checkForExternalChanges()`` is called, and
    /// the changes it notices together are reported together. The keys are those that may read
    /// differently: every key another process wrote since the store last looked, or, when that
    /// process rewrote the whole file, every key whose value is now different.
    case externalKeys([String])

    /// Any key may read differently, and the store can't say which.
    case wholeStore(WholeStoreReason)

    /// Whether the change came from another process, or another copy of MMKV in this process,
    /// rather than through this package.
    public var isExternal: Bool {
      switch self {
      case .localKeys: false
      case .externalKeys: true
      case .wholeStore(let reason): reason.isExternal
      }
    }
  }

  /// Why every key of a store may read differently, in a ``Kind/wholeStore(_:)`` batch.
  public struct WholeStoreReason: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
      self.rawValue = rawValue
    }

    /// Another process, or another copy of MMKV in this process, changed keys this store
    /// couldn't identify. A store on the C++ engine reports every external change this way.
    public static let externalChange = Self(rawValue: "external-change")

    /// The store was resumed. Reads were turned away while it was suspended, and another
    /// process may have changed it in the meantime.
    public static let resumed = Self(rawValue: "resumed")

    /// The store was overwritten with its copy in a backup.
    public static let restoredFromBackup = Self(rawValue: "restored-from-backup")

    /// The store was closed, so every value now reads as missing. This is the last batch a
    /// listener is given.
    public static let closed = Self(rawValue: "closed")

    /// Whether the reason is a change from outside this package: ``externalChange`` and
    /// ``resumed``.
    public var isExternal: Bool {
      self == .externalChange || self == .resumed
    }
  }
}

// MARK: - Candidates

extension MMKVStore.ChangeBatch {
  /// Whether the change came from another process, or another copy of MMKV in this process,
  /// rather than through this package.
  public var isExternal: Bool {
    self.kind.isExternal
  }

  /// Whether this batch may have changed the value of `key`: it names `key`, or it is a
  /// whole-store change.
  public func hasChangeCandidate(forKey key: String) -> Bool {
    self.kind.hasChangeCandidate(forKey: key)
  }

  /// Whether this batch may have changed the value of `prefix` or of any key under it: it
  /// names such a key, or it is a whole-store change.
  ///
  /// A key is under `prefix` when it starts with `prefix` and `separator`, as for
  /// ``MMKVStore/subscribe(underKey:separator:_:)``. An empty `prefix` has every key under it.
  public func hasChangeCandidates(underKey prefix: String, separator: String = ".") -> Bool {
    self.kind.hasChangeCandidates(underKey: prefix, separator: separator)
  }
}

extension MMKVStore.ChangeBatch.Kind {
  /// ``MMKVStore/ChangeBatch/hasChangeCandidate(forKey:)``, for the C interface.
  package func hasChangeCandidate(forKey key: String) -> Bool {
    self.hasChangeCandidate(where: { $0 == key })
  }

  /// ``MMKVStore/ChangeBatch/hasChangeCandidates(underKey:separator:)``, for the C interface.
  package func hasChangeCandidates(underKey prefix: String, separator: String) -> Bool {
    let names = KeyNames(separator: separator)
    return self.hasChangeCandidate(where: { names.isAtOrUnder($0, prefix) })
  }

  /// Whether the change names a key that satisfies `isCandidate`, or is a whole-store change.
  func hasChangeCandidate(where isCandidate: (String) -> Bool) -> Bool {
    switch self {
    case .localKeys(let keys), .externalKeys(let keys): keys.contains(where: isCandidate)
    case .wholeStore: true
    }
  }

  /// The change with only the keys that satisfy `isIncluded`, or `nil` if it names keys and
  /// none of them does. A whole-store change is kept as it is.
  func narrowed(to isIncluded: (String) -> Bool) -> Self? {
    switch self {
    case .localKeys(let keys):
      let narrowed = keys.filter(isIncluded)
      return narrowed.isEmpty ? nil : .localKeys(narrowed)
    case .externalKeys(let keys):
      let narrowed = keys.filter(isIncluded)
      return narrowed.isEmpty ? nil : .externalKeys(narrowed)
    case .wholeStore:
      return self
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
