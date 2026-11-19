extension MMKVStore {
  /// A ``CodedKey`` together with the value to read when the store has none for it.
  ///
  /// ```swift
  /// extension MMKVStore.DefaultedCodedKey where Value == Settings {
  ///   static let settings = Self(
  ///     "settings",
  ///     default: Settings(),
  ///     encoder: JSONEncoder(),
  ///     decoder: JSONDecoder()
  ///   )
  /// }
  ///
  /// let settings = try store.value(for: .settings)  // Settings() until one is stored
  /// ```
  ///
  /// The default is read only when the store has no value for the key. A stored value that
  /// does not decode is an error, not a reason to read the default, so that a later write does
  /// not silently replace data the app could not read.
  ///
  /// The default is not written to the store, and storing a value equal to the default stores
  /// it like any other.
  ///
  /// Give a defaulted key a different name from any plain key over the same value type.
  /// `store.contains(.volume)` is ambiguous when both `CodedKey.volume` and `DefaultedCodedKey.volume` exist.
  public struct DefaultedCodedKey<Value: Codable & Sendable>: Sendable {
    /// The key the value is stored under.
    public let key: CodedKey<Value>

    /// The value to read when the store has no value for ``key``.
    public let defaultValue: Value

    /// Creates a key that reads `defaultValue` when the store has no value for `key`.
    public init(_ key: CodedKey<Value>, default defaultValue: Value) {
      self.key = key
      self.defaultValue = defaultValue
    }

    /// Creates a key that reads `defaultValue` when the store has no value for `name`.
    ///
    /// - Parameters:
    ///   - name: The key in the store, which must not be empty.
    ///   - defaultValue: The value to read when the store has none.
    ///   - encoder: The encoder that writes the value.
    ///   - decoder: The decoder that reads the value.
    public init<
      Encoder: MMKVTopLevelEncoder & AnyObject & Sendable,
      Decoder: MMKVTopLevelDecoder & AnyObject & Sendable
    >(
      _ name: String,
      default defaultValue: Value,
      encoder: Encoder,
      decoder: Decoder
    ) where Encoder.Output: MMKVValue, Decoder.Input: MMKVValue {
      self.init(CodedKey(name, encoder: encoder, decoder: decoder), default: defaultValue)
    }
  }
}

extension MMKVStore.DefaultedCodedKey: Equatable where Value: Equatable {}
extension MMKVStore.DefaultedCodedKey: Hashable where Value: Hashable {}

// MARK: - Values

extension MMKVStore {
  /// Reads the value of `key` and decodes it with the key's decoder.
  ///
  /// - Returns: The value, or the key's default if the key has no value.
  /// - Throws: Whatever the decoder throws when the stored value does not decode, or
  ///   ``MMKVError/storeIsSuspended(id:)`` if the store is suspended.
  public func value<V>(for key: DefaultedCodedKey<V>) throws -> V {
    try self.value(for: key.key) ?? key.defaultValue
  }

  /// Encodes `value` with the key's encoder and stores the result under `key`, replacing any
  /// existing value.
  ///
  /// - Parameters:
  ///   - value: The value to encode. It is stored even when it equals the key's default.
  ///   - key: The key.
  ///   - expiringIn: How long to keep the value. See ``set(_:forKey:expiringIn:)``.
  /// - Returns: Whether the encoded value was stored.
  /// - Throws: Whatever the encoder throws, in which case nothing is stored, or
  ///   ``MMKVError/storeIsSuspended(id:)`` if the store is suspended.
  @discardableResult
  public func set<V>(
    _ value: V,
    for key: DefaultedCodedKey<V>,
    expiringIn: Duration? = nil
  ) throws -> Bool {
    try self.set(value, for: key.key, expiringIn: expiringIn)
  }

  /// Whether the store has a value for `key`, rather than the key's default being read. The
  /// value is not decoded.
  public func contains<V>(_ key: DefaultedCodedKey<V>) -> Bool {
    self.contains(key.key)
  }

  /// Removes `key` and its value, so that the key's default is read again.
  ///
  /// - Returns: Whether the store accepted the removal. See ``removeValue(forKey:)``.
  @discardableResult
  public func removeValue<V>(for key: DefaultedCodedKey<V>) -> Bool {
    self.removeValue(for: key.key)
  }

  /// Calls `onChange` with the decoded value of `key`, once before this function returns and
  /// then whenever the value may have changed, until the returned subscription is cancelled or
  /// released.
  ///
  /// The result is a success of the key's default whenever the store has no value for the
  /// key. A stored value that does not decode is still a failure. In other respects this
  /// behaves like the subscription of a ``CodedKey``.
  public func subscribe<V>(
    for key: DefaultedCodedKey<V>,
    _ onChange: @escaping @Sendable (Result<V, any Error>) -> Void
  ) -> MMKVSubscription {
    self.subscribe(for: key.key) { result in
      onChange(result.map { $0 ?? key.defaultValue })
    }
  }
}

// MARK: - Batches

extension MMKVStore {
  /// Reads and decodes the values of several keys at once, reading each key's default when the
  /// store has no value for it.
  ///
  /// ```swift
  /// let (settings, feed) = try store.values(forKeys: .settings, .feed)  // (Settings, Feed)
  /// ```
  ///
  /// The store is locked once for the whole read.
  ///
  /// - Throws: Whatever a key's decoder throws when its stored value does not decode, or
  ///   ``MMKVError/storeIsSuspended(id:)`` if the store is suspended.
  public func values<each V>(
    forKeys keys: repeat DefaultedCodedKey<each V>
  ) throws -> (repeat each V) {
    try self.withExclusiveLock { store in
      (repeat try store.value(for: each keys))
    }
  }

  /// Encodes several values and stores each under its key, replacing any existing values, all
  /// at once.
  ///
  /// ```swift
  /// try store.set((.settings, settings), (.feed, feed))
  /// ```
  ///
  /// Every value is encoded before anything is stored, so nothing is stored when one of them
  /// does not encode. The store is then locked once for the whole write, and listeners are
  /// told about each key after every value has been written. A value is stored even when it
  /// equals its key's default.
  ///
  /// - Parameters:
  ///   - values: Each key with the value to store under it.
  ///   - expiringIn: How long to keep the values. See ``set(_:forKey:expiringIn:)``.
  /// - Returns: Whether every encoded value was stored.
  /// - Throws: Whatever an encoder throws, in which case nothing is stored, or
  ///   ``MMKVError/storeIsSuspended(id:)`` if the store is suspended.
  @discardableResult
  public func set<each V>(
    _ values: repeat (DefaultedCodedKey<each V>, each V),
    expiringIn: Duration? = nil
  ) throws -> Bool {
    try self.set(repeat ((each values).0.key, (each values).1), expiringIn: expiringIn)
  }
}
