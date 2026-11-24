extension MMKVStore {
  /// A key of a store together with the type of the value stored under it.
  ///
  /// Declare an app's keys as static members, so that each key's name and type are written
  /// once:
  ///
  /// ```swift
  /// extension MMKVStore.Key where Value == String {
  ///   static let username: Self = "username"
  ///   static func draft(_ postID: Int) -> Self { "draft.\(postID)" }
  /// }
  ///
  /// store[.username] = "blob"
  /// let draft = store[.draft(42)]
  /// ```
  ///
  /// A key reads and writes exactly what the string APIs do with the same name and type, so
  /// the two can be mixed, and a key can name a value react-native-mmkv wrote.
  ///
  /// For a key that reads a default instead of `nil` see ``DefaultedKey``, and for a `Codable`
  /// value see ``CodedKey``.
  public struct Key<Value: MMKVValue>: Hashable, Sendable {
    /// The key in the store.
    public let name: String

    /// Creates a key.
    ///
    /// - Parameters:
    ///   - name: The key in the store, which must not be empty.
    ///   - type: The type the value is read and written as.
    public init(_ name: String, as type: Value.Type = Value.self) {
      self.name = name
    }
  }
}

extension MMKVStore.Key: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
  public init(stringLiteral value: String) {
    self.init(value)
  }
}

extension MMKVStore.Key: CustomStringConvertible {
  public var description: String {
    self.name
  }
}

// MARK: - Values

extension MMKVStore {
  /// Reads or writes the value of `key`. Assigning `nil` removes the key.
  ///
  /// ```swift
  /// store[.username] = "blob"
  /// let username = store[.username]
  /// ```
  public subscript<V>(key: Key<V>) -> V? {
    get {
      self.value(forKey: key.name, as: V.self)
    }
    set {
      self[key.name, as: V.self] = newValue
    }
  }

  /// Reads the value of `key`.
  ///
  /// - Returns: The value, or `nil` if the key has no value or its value is not a valid `V`.
  public func value<V>(for key: Key<V>) -> V? {
    self.value(forKey: key.name, as: V.self)
  }

  /// Stores `value` under `key`, replacing any existing value.
  ///
  /// - Parameters:
  ///   - value: The value to store.
  ///   - key: The key.
  ///   - expiry: How long to keep the value. See ``set(_:forKey:expiry:)``.
  /// - Returns: Whether the value was stored.
  @discardableResult
  public func set<V>(_ value: V, for key: Key<V>, expiry: MMKVExpiry? = nil) -> Bool {
    self.set(value, forKey: key.name, expiry: expiry)
  }

  /// Whether `key` has a value.
  public func contains<V>(_ key: Key<V>) -> Bool {
    self.contains(key.name)
  }

  /// Removes `key` and its value.
  ///
  /// - Returns: Whether the store accepted the removal. See ``removeValue(forKey:)``.
  @discardableResult
  public func removeValue<V>(for key: Key<V>) -> Bool {
    self.removeValue(forKey: key.name)
  }
}

// MARK: - Observation

extension MMKVStore {
  /// Calls `onChange` with the value of `key`, once before this function returns and then
  /// whenever the value may have changed, until the returned subscription is cancelled or
  /// released.
  ///
  /// ```swift
  /// let subscription = store.subscribe(for: .username) { username in
  ///   label.text = username ?? "Signed out"
  /// }
  /// ```
  ///
  /// This behaves like ``subscribe(forKey:as:_:)``.
  public func subscribe<V: SendableMetatype>(
    for key: Key<V>,
    _ onChange: @escaping @Sendable (V?) -> Void
  ) -> MMKVSubscription {
    self.subscribe(forKey: key.name, as: V.self, onChange)
  }

  /// The values of `key` over time, starting with the value the store holds when iteration
  /// begins.
  ///
  /// ```swift
  /// for await username in store.values(for: .username) {
  ///   label.text = username ?? "Signed out"
  /// }
  /// ```
  ///
  /// This behaves like ``values(forKey:as:)``.
  public func values<V: Sendable>(for key: Key<V>) -> MMKVValues<V?> {
    self.values(forKey: key.name, as: V.self)
  }
}

// MARK: - Batches

extension MMKVStore {
  /// Reads the values of several keys at once.
  ///
  /// ```swift
  /// let (username, volume) = store.values(forKeys: .username, .volume)  // (String?, Double?)
  /// ```
  ///
  /// The store is locked once for the whole read, so the values are those the keys held at
  /// one moment, and for a multi-process store the file lock is taken once rather than once
  /// for each key. To read keys of different kinds together, use ``withExclusiveLock(_:)``.
  ///
  /// - Returns: The value of each key, in order. See ``value(forKey:as:)`` for when one is
  ///   `nil`.
  public func values<each V>(forKeys keys: repeat Key<each V>) -> (repeat (each V)?) {
    self.withExclusiveLock { store in
      (repeat store.value(for: each keys))
    }
  }

  /// Reads the values of several keys at once, each as its own type.
  ///
  /// ```swift
  /// let (username, volume) = store.values(
  ///   forKeys: ("username", String.self), ("volume", Double.self)
  /// )
  /// ```
  ///
  /// The store is locked once for the whole read, so the values are those the keys held at
  /// one moment, and for a multi-process store the file lock is taken once rather than once
  /// for each key.
  ///
  /// - Parameter keys: Each key with the type to read its value as.
  /// - Returns: The value of each key, in order. See ``value(forKey:as:)`` for when one is
  ///   `nil`.
  public func values<each V: MMKVValue>(
    forKeys keys: repeat (String, (each V).Type)
  ) -> (repeat (each V)?) {
    self.withExclusiveLock { store in
      (repeat store.value(forKey: (each keys).0, as: (each keys).1))
    }
  }

  /// Stores several values, each under its key, replacing any existing values, all at once.
  ///
  /// ```swift
  /// store.set((.username, "blob"), (.volume, 0.8))
  /// store.set(("username", "blob"), ("volume", 0.8))
  /// ```
  ///
  /// The store is locked once for the whole write, so nothing else reads or writes it part of
  /// the way through, and for a multi-process store the file lock is taken once rather than
  /// once for each key. Listeners are told about each key after every value has been written.
  /// To write keys of different kinds together, use ``withExclusiveLock(_:)``.
  ///
  /// The write is not atomic if the process is killed during it: the values written by then
  /// are kept.
  ///
  /// - Parameters:
  ///   - values: Each key with the value to store under it.
  ///   - expiry: How long to keep the values. See ``set(_:forKey:expiry:)``.
  /// - Returns: Whether every value was stored. A value that cannot be stored does not stop
  ///   the others from being stored.
  @discardableResult
  public func set<each V>(
    _ values: repeat (Key<each V>, each V),
    expiry: MMKVExpiry? = nil
  ) -> Bool {
    self.withExclusiveLock { store in
      var didStoreAll = true
      func write<T>(_ value: T, for key: Key<T>) {
        if !store.set(value, for: key, expiry: expiry) {
          didStoreAll = false
        }
      }
      repeat write((each values).1, for: (each values).0)
      return didStoreAll
    }
  }
}
