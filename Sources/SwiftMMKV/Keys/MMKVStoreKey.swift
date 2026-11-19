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
  ///   - expiringIn: How long to keep the value. See ``set(_:forKey:expiringIn:)``.
  /// - Returns: Whether the value was stored.
  @discardableResult
  public func set<V>(_ value: V, for key: Key<V>, expiringIn: Duration? = nil) -> Bool {
    self.set(value, forKey: key.name, expiringIn: expiringIn)
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
