extension MMKVStore {
  /// A ``Key`` together with the value to read when the store has none for it.
  ///
  /// ```swift
  /// extension MMKVStore.DefaultedKey where Value == Double {
  ///   static let volume = Self("volume", default: 0.5)
  /// }
  ///
  /// let volume = store[.volume]  // 0.5 until a volume is stored
  /// store[.volume] = 0.8
  /// ```
  ///
  /// The default is only ever read. It is not written to the store, and storing a value equal
  /// to the default stores it like any other.
  ///
  /// Give a defaulted key a different name from any plain key over the same value type.
  /// `store.contains(.volume)` is ambiguous when both `Key.volume` and `DefaultedKey.volume` exist.
  public struct DefaultedKey<Value: MMKVValue & Sendable>: Sendable {
    /// The key the value is stored under.
    public let key: Key<Value>

    /// The value to read when the store has no value for ``key``.
    public let defaultValue: Value

    /// Creates a key that reads `defaultValue` when the store has no value for `key`.
    public init(_ key: Key<Value>, default defaultValue: Value) {
      self.key = key
      self.defaultValue = defaultValue
    }

    /// Creates a key that reads `defaultValue` when the store has no value for `name`.
    ///
    /// - Parameters:
    ///   - name: The key in the store, which must not be empty.
    ///   - defaultValue: The value to read when the store has none.
    public init(_ name: String, default defaultValue: Value) {
      self.init(Key(name), default: defaultValue)
    }
  }
}

extension MMKVStore.DefaultedKey: Equatable where Value: Equatable {}
extension MMKVStore.DefaultedKey: Hashable where Value: Hashable {}

// MARK: - Values

extension MMKVStore {
  /// Reads or writes the value of `key`, reading the key's default when the store has no
  /// value for it.
  ///
  /// ```swift
  /// store[.volume] = 0.8
  /// let volume = store[.volume]
  /// ```
  ///
  /// To remove the key use `removeValue(for:)`.
  public subscript<V>(key: DefaultedKey<V>) -> V {
    get {
      self.value(for: key)
    }
    set {
      self.set(newValue, for: key.key)
    }
  }

  /// Reads the value of `key`.
  ///
  /// - Returns: The value, or the key's default if the key has no value, its value is not a
  ///   valid `V`, or the store is suspended.
  public func value<V>(for key: DefaultedKey<V>) -> V {
    self.value(for: key.key) ?? key.defaultValue
  }

  /// Stores `value` under `key`, replacing any existing value.
  ///
  /// - Parameters:
  ///   - value: The value to store. It is stored even when it equals the key's default.
  ///   - key: The key.
  ///   - expiringIn: How long to keep the value. See ``set(_:forKey:expiringIn:)``.
  /// - Returns: Whether the value was stored.
  @discardableResult
  public func set<V>(_ value: V, for key: DefaultedKey<V>, expiringIn: Duration? = nil) -> Bool {
    self.set(value, for: key.key, expiringIn: expiringIn)
  }

  /// Whether the store has a value for `key`, rather than the key's default being read.
  public func contains<V>(_ key: DefaultedKey<V>) -> Bool {
    self.contains(key.key)
  }

  /// Removes `key` and its value, so that the key's default is read again.
  ///
  /// - Returns: Whether the store accepted the removal. See ``removeValue(forKey:)``.
  @discardableResult
  public func removeValue<V>(for key: DefaultedKey<V>) -> Bool {
    self.removeValue(for: key.key)
  }

  /// Calls `onChange` with the value of `key`, once before this function returns and then
  /// whenever the value may have changed, until the returned subscription is cancelled or
  /// released.
  ///
  /// `onChange` is given the key's default whenever the store has no value for the key. In
  /// other respects this behaves like ``subscribe(forKey:as:_:)``.
  public func subscribe<V>(
    for key: DefaultedKey<V>,
    _ onChange: @escaping @Sendable (V) -> Void
  ) -> MMKVSubscription {
    self.subscribe(for: key.key) { onChange($0 ?? key.defaultValue) }
  }
}
