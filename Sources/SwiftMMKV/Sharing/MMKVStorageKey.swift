#if Sharing
  import Dependencies
  import Sharing

  /// A swift-sharing key that keeps a piece of `@Shared` state under one key of an
  /// ``MMKVStore``, or spread over the keys under a prefix.
  ///
  /// Create one with the `mmkv` functions:
  ///
  /// ```swift
  /// @Shared(.mmkv("volume")) var volume = 1.0
  /// @Shared(.mmkv("username")) var username: String?
  /// @Shared(.mmkv("settings", encoder: JSONEncoder(), decoder: JSONDecoder()))
  /// var settings = Settings()
  /// @Shared(.mmkv(keysUnder: "profile")) var profile = Profile()
  /// ```
  ///
  /// The state uses the store in the `defaultMMKVStore` dependency unless a key names another.
  /// It follows writes made through this package as they happen. A write made by another
  /// process, or by another copy of MMKV such as react-native-mmkv's, is only seen when the
  /// store is next read or written, or when ``MMKVStore/checkForExternalChanges()`` is called.
  ///
  /// While the store is suspended the state keeps its value, and loading or saving reports
  /// ``MMKVError/Code/storeIsSuspended`` through `loadError` or `saveError`. The state loads
  /// again when the store resumes.
  public struct MMKVStorageKey<Value: Sendable>: SharedKey {
    private let store: MMKVStore
    private let key: String
    /// What joins `key` to the keys under it, for state that is spread over those keys, and
    /// `nil` for state that is kept under `key` alone.
    private let separator: String?
    private let loadValue: @Sendable (MMKVStore, String) throws -> Value?
    private let saveValue: @Sendable (Value, MMKVStore, String) throws -> Void

    fileprivate init(
      key: String,
      separatorOfKeysUnder separator: String? = nil,
      store: MMKVStore?,
      load: @escaping @Sendable (MMKVStore, String) throws -> Value?,
      save: @escaping @Sendable (Value, MMKVStore, String) throws -> Void
    ) {
      @Dependency(\.defaultMMKVStore) var defaultStore
      self.store = store ?? defaultStore
      self.key = key
      self.separator = separator
      self.loadValue = load
      self.saveValue = save
    }

    public var id: MMKVStorageKeyID {
      MMKVStorageKeyID(store: self.store, key: self.key, separator: self.separator)
    }

    public func load(context: LoadContext<Value>, continuation: LoadContinuation<Value>) {
      continuation.resume(with: Result { try self.loadUnlessSuspended() })
    }

    public func subscribe(
      context: LoadContext<Value>,
      subscriber: SharedSubscriber<Value>
    ) -> SharedSubscription {
      let onChange: @Sendable () -> Void = {
        subscriber.yield(with: Result { try self.loadUnlessSuspended() })
      }
      let subscription =
        if let separator = self.separator {
          self.store.subscribe(underKey: self.key, separator: separator, onChange)
        } else {
          self.store.subscribe(forKey: self.key, onChange)
        }
      return SharedSubscription { subscription.cancel() }
    }

    public func save(_ value: Value, context: SaveContext, continuation: SaveContinuation) {
      continuation.resume(with: Result { try self.saveValue(value, self.store, self.key) })
    }

    /// A suspended store turns reads away, which looks like the key having no value. The store
    /// is asked afterwards, so that the state keeps what it has instead of losing it. Resuming
    /// the store notifies the subscription, which loads the value again.
    private func loadUnlessSuspended() throws -> Value? {
      let value = try self.loadValue(self.store, self.key)
      if let error = MMKVErrors.unavailable(self.store) {
        throw error
      }
      return value
    }
  }

  /// Identifies the store and key behind an ``MMKVStorageKey``, so that every `@Shared` property
  /// over the same key of the same ``MMKVStore`` object holds the same state.
  ///
  /// Two ``MMKVStore`` objects opened over the same files are different stores to this type.
  /// Shared state over each still follows the other, because their listeners are shared.
  public struct MMKVStorageKeyID: Hashable, Sendable {
    private let store: MMKVStore
    private let key: String
    private let separator: String?

    fileprivate init(store: MMKVStore, key: String, separator: String?) {
      self.store = store
      self.key = key
      self.separator = separator
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.store === rhs.store && lhs.key == rhs.key && lhs.separator == rhs.separator
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(self.store))
      hasher.combine(self.key)
      hasher.combine(self.separator)
    }
  }

  // MARK: - Keys

  extension SharedReaderKey {
    /// A key for a value the store reads and writes natively, such as a `Double`, `Bool`,
    /// `String`, or any other ``MMKVValue``.
    ///
    /// When the store has no value for `key`, the state holds the `@Shared` property's default.
    ///
    /// - Parameters:
    ///   - key: The key in the store.
    ///   - store: The store to use, or `nil` for the `defaultMMKVStore` dependency.
    public static func mmkv<Value: MMKVValue & Sendable>(
      _ key: String,
      store: MMKVStore? = nil
    ) -> Self where Self == MMKVStorageKey<Value> {
      MMKVStorageKey(key: key, store: store) { store, key in
        store.value(forKey: key, as: Value.self)
      } save: { value, store, key in
        try store.write(key) { store.set(value, forKey: key) }
      }
    }

    /// A key for an optional value the store reads and writes natively. The state is `nil` when
    /// the store has no value for `key`, and setting it to `nil` removes the key.
    ///
    /// - Parameters:
    ///   - key: The key in the store.
    ///   - store: The store to use, or `nil` for the `defaultMMKVStore` dependency.
    public static func mmkv<Value: MMKVValue & Sendable>(
      _ key: String,
      store: MMKVStore? = nil
    ) -> Self where Self == MMKVStorageKey<Value?> {
      MMKVStorageKey(key: key, store: store) { store, key in
        .some(store.value(forKey: key, as: Value.self))
      } save: { value, store, key in
        try store.write(key) {
          guard let value else { return store.removeValue(forKey: key) }
          return store.set(value, forKey: key)
        }
      }
    }

    /// A key for a `Codable` value, stored whole under `key` in the form `encoder` gives it.
    ///
    /// When the store has no value for `key`, the state holds the `@Shared` property's default.
    /// An error from either coder is reported through the shared state's `loadError` or
    /// `saveError`.
    ///
    /// - Parameters:
    ///   - key: The key in the store.
    ///   - encoder: The encoder that writes the value.
    ///   - decoder: The decoder that reads the value.
    ///   - store: The store to use, or `nil` for the `defaultMMKVStore` dependency.
    public static func mmkv<
      Value: Codable & Sendable,
      Encoder: MMKVTopLevelEncoder & Sendable,
      Decoder: MMKVTopLevelDecoder & Sendable
    >(
      _ key: String,
      encoder: Encoder,
      decoder: Decoder,
      store: MMKVStore? = nil
    ) -> Self
    where Self == MMKVStorageKey<Value>, Encoder.Output: MMKVValue, Decoder.Input: MMKVValue {
      MMKVStorageKey(key: key, store: store) { store, key in
        try store.decode(Value.self, forKey: key, with: decoder)
      } save: { value, store, key in
        try store.write(key) { try store.encode(value, forKey: key, with: encoder) }
      }
    }

    /// A key for an optional `Codable` value, stored whole under `key` in the form `encoder`
    /// gives it. The state is `nil` when the store has no value for `key`, and setting it to
    /// `nil` removes the key.
    ///
    /// - Parameters:
    ///   - key: The key in the store.
    ///   - encoder: The encoder that writes the value.
    ///   - decoder: The decoder that reads the value.
    ///   - store: The store to use, or `nil` for the `defaultMMKVStore` dependency.
    public static func mmkv<
      Value: Codable & Sendable,
      Encoder: MMKVTopLevelEncoder & Sendable,
      Decoder: MMKVTopLevelDecoder & Sendable
    >(
      _ key: String,
      encoder: Encoder,
      decoder: Decoder,
      store: MMKVStore? = nil
    ) -> Self
    where Self == MMKVStorageKey<Value?>, Encoder.Output: MMKVValue, Decoder.Input: MMKVValue {
      MMKVStorageKey(key: key, store: store) { store, key in
        .some(try store.decode(Value.self, forKey: key, with: decoder))
      } save: { value, store, key in
        try store.write(key) {
          guard let value else { return store.removeValue(forKey: key) }
          return try store.encode(value, forKey: key, with: encoder)
        }
      }
    }
  }

  // MARK: - Typed keys

  extension SharedReaderKey {
    /// A key for the value of an ``MMKVStore/Key``.
    ///
    /// ```swift
    /// @Shared(.mmkv(.username)) var username = "blob"
    /// ```
    ///
    /// When the store has no value for `key`, the state holds the `@Shared` property's default.
    ///
    /// - Parameters:
    ///   - key: The key in the store.
    ///   - store: The store to use, or `nil` for the `defaultMMKVStore` dependency.
    public static func mmkv<Value: MMKVValue & Sendable>(
      _ key: MMKVStore.Key<Value>,
      store: MMKVStore? = nil
    ) -> Self where Self == MMKVStorageKey<Value> {
      .mmkv(key.name, store: store)
    }

    /// A key for the optional value of an ``MMKVStore/Key``. The state is `nil` when the store
    /// has no value for `key`, and setting it to `nil` removes the key.
    ///
    /// ```swift
    /// @Shared(.mmkv(.username)) var username: String?
    /// ```
    ///
    /// - Parameters:
    ///   - key: The key in the store.
    ///   - store: The store to use, or `nil` for the `defaultMMKVStore` dependency.
    public static func mmkv<Value: MMKVValue & Sendable>(
      _ key: MMKVStore.Key<Value>,
      store: MMKVStore? = nil
    ) -> Self where Self == MMKVStorageKey<Value?> {
      .mmkv(key.name, store: store)
    }

    /// A key for the value of an ``MMKVStore/DefaultedKey``, which supplies the state's default,
    /// so the `@Shared` property needs none.
    ///
    /// ```swift
    /// @Shared(.mmkv(.volume)) var volume
    /// ```
    ///
    /// - Parameters:
    ///   - key: The key in the store.
    ///   - store: The store to use, or `nil` for the `defaultMMKVStore` dependency.
    public static func mmkv<Value: MMKVValue & Sendable>(
      _ key: MMKVStore.DefaultedKey<Value>,
      store: MMKVStore? = nil
    ) -> Self where Self == MMKVStorageKey<Value>.Default {
      Self[.mmkv(key.key, store: store), default: key.defaultValue]
    }

    /// A key for the value of an ``MMKVStore/CodedKey``.
    ///
    /// ```swift
    /// @Shared(.mmkv(.settings)) var settings = Settings()
    /// ```
    ///
    /// When the store has no value for `key`, the state holds the `@Shared` property's default.
    /// A value that does not decode is reported through `loadError`.
    ///
    /// - Parameters:
    ///   - key: The key in the store.
    ///   - store: The store to use, or `nil` for the `defaultMMKVStore` dependency.
    public static func mmkv<Value>(
      _ key: MMKVStore.CodedKey<Value>,
      store: MMKVStore? = nil
    ) -> Self where Self == MMKVStorageKey<Value> {
      MMKVStorageKey(key: key.name, store: store) { store, _ in
        try store.value(for: key)
      } save: { value, store, name in
        try store.write(name) { try store.set(value, for: key) }
      }
    }

    /// A key for the optional value of an ``MMKVStore/CodedKey``. The state is `nil` when the
    /// store has no value for `key`, and setting it to `nil` removes the key.
    ///
    /// - Parameters:
    ///   - key: The key in the store.
    ///   - store: The store to use, or `nil` for the `defaultMMKVStore` dependency.
    public static func mmkv<Value>(
      _ key: MMKVStore.CodedKey<Value>,
      store: MMKVStore? = nil
    ) -> Self where Self == MMKVStorageKey<Value?> {
      MMKVStorageKey(key: key.name, store: store) { store, _ in
        .some(try store.value(for: key))
      } save: { value, store, name in
        try store.write(name) {
          guard let value else { return store.removeValue(for: key) }
          return try store.set(value, for: key)
        }
      }
    }

    /// A key for the value of an ``MMKVStore/DefaultedCodedKey``, which supplies the state's
    /// default, so the `@Shared` property needs none.
    ///
    /// ```swift
    /// @Shared(.mmkv(.settings)) var settings
    /// ```
    ///
    /// - Parameters:
    ///   - key: The key in the store.
    ///   - store: The store to use, or `nil` for the `defaultMMKVStore` dependency.
    public static func mmkv<Value>(
      _ key: MMKVStore.DefaultedCodedKey<Value>,
      store: MMKVStore? = nil
    ) -> Self where Self == MMKVStorageKey<Value>.Default {
      Self[.mmkv(key.key, store: store), default: key.defaultValue]
    }
  }

  // MARK: - Keys under a prefix

  extension SharedReaderKey {
    /// A key for a `Codable` value that is spread over the keys under `prefix`, one key for each
    /// of its properties, as ``MMKVStore/encode(_:intoKeysUnder:removingOtherKeys:expiry:options:)``
    /// stores it.
    ///
    /// ```swift
    /// @Shared(.mmkv(keysUnder: "profile")) var profile = Profile()
    /// ```
    ///
    /// When the store has neither `prefix` nor any key under it, the state holds the `@Shared`
    /// property's default. A value that cannot be decoded from the keys that are there is
    /// reported through `loadError`.
    ///
    /// Saving writes every key of the value and removes the other keys under `prefix`. The state
    /// follows a change to any key under `prefix`, loading once for each operation that changes
    /// them, however many keys it changes.
    ///
    /// - Parameters:
    ///   - prefix: The start of the keys the value is kept in.
    ///   - options: How the value is laid out in keys.
    ///   - store: The store to use, or `nil` for the `defaultMMKVStore` dependency.
    public static func mmkv<Value: Codable & Sendable>(
      keysUnder prefix: String,
      options: MMKVKeyCodingOptions = MMKVKeyCodingOptions(),
      store: MMKVStore? = nil
    ) -> Self where Self == MMKVStorageKey<Value> {
      MMKVStorageKey(
        key: prefix,
        separatorOfKeysUnder: options.separator,
        store: store
      ) { store, prefix in
        try store.decode(Value?.self, fromKeysUnder: prefix, options: options)
      } save: { value, store, prefix in
        try store.write(prefix) {
          try store.encode(value, intoKeysUnder: prefix, options: options)
        }
      }
    }

    /// A key for an optional `Codable` value that is spread over the keys under `prefix`. The
    /// state is `nil` when the store has neither `prefix` nor any key under it, and setting it
    /// to `nil` removes all of those keys.
    ///
    /// ```swift
    /// @Shared(.mmkv(keysUnder: "profile")) var profile: Profile?
    /// ```
    ///
    /// - Parameters:
    ///   - prefix: The start of the keys the value is kept in.
    ///   - options: How the value is laid out in keys.
    ///   - store: The store to use, or `nil` for the `defaultMMKVStore` dependency.
    public static func mmkv<Value: Codable & Sendable>(
      keysUnder prefix: String,
      options: MMKVKeyCodingOptions = MMKVKeyCodingOptions(),
      store: MMKVStore? = nil
    ) -> Self where Self == MMKVStorageKey<Value?> {
      MMKVStorageKey(
        key: prefix,
        separatorOfKeysUnder: options.separator,
        store: store
      ) { store, prefix in
        .some(try store.decode(Value?.self, fromKeysUnder: prefix, options: options))
      } save: { value, store, prefix in
        try store.write(prefix) {
          guard let value else {
            store.removeValues(underKey: prefix, separator: options.separator)
            return MMKVErrors.unavailable(store) == nil
          }
          return try store.encode(value, intoKeysUnder: prefix, options: options)
        }
      }
    }
  }

  extension MMKVStore {
    /// Runs a write to `key`, turning a write the store did not accept into an error.
    fileprivate func write(_ key: String, _ body: () throws -> Bool) throws {
      guard try body() else {
        throw MMKVErrors.unavailable(self) ?? MMKVErrors.writeFailed(key: key)
      }
    }
  }

  // MARK: - Default store

  extension DependencyValues {
    /// The store ``MMKVStorageKey`` uses when a key does not name one.
    ///
    /// There is no store an app could be given by default, because a store needs a directory.
    /// Set this once, as early as possible in the app's lifetime:
    ///
    /// ```swift
    /// @main
    /// struct MyApp: App {
    ///   init() {
    ///     prepareDependencies {
    ///       $0.defaultMMKVStore = try! MMKVStore(
    ///         MMKVConfiguration(directory: directory, mode: .multiProcess)
    ///       )
    ///     }
    ///   }
    /// }
    /// ```
    ///
    /// Until it is set, an app gets an empty store in a temporary directory and an issue is
    /// reported. Tests and previews get such a store without the issue.
    public var defaultMMKVStore: MMKVStore {
      get { self[DefaultMMKVStoreKey.self] }
      set { self[DefaultMMKVStoreKey.self] = newValue }
    }
  }

  private enum DefaultMMKVStoreKey: DependencyKey {
    static var liveValue: MMKVStore {
      reportIssue(
        """
        A temporary MMKV store is being used. Set 'defaultMMKVStore' with 'prepareDependencies' \
        as early as possible in the app's lifetime, or pass a store to the 'mmkv' shared key.
        """
      )
      return .temporaryDefault()
    }

    static var testValue: MMKVStore { .temporaryDefault() }
  }

  extension MMKVStore {
    /// An empty store in a temporary directory, for a default that has no way to fail.
    fileprivate static func temporaryDefault() -> MMKVStore {
      do {
        return try .temporary()
      } catch {
        fatalError("A temporary MMKV store could not be opened: \(error)")
      }
    }
  }
#endif
