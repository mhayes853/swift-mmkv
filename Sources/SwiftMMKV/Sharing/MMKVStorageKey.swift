#if Sharing
  import Dependencies
  import Sharing

  /// A swift-sharing key that keeps a piece of `@Shared` state under one key of an
  /// ``MMKVStore``.
  ///
  /// Create one with the `mmkv` functions:
  ///
  /// ```swift
  /// @Shared(.mmkv("volume")) var volume = 1.0
  /// @Shared(.mmkv("username")) var username: String?
  /// @Shared(.mmkv("settings", encoder: JSONEncoder(), decoder: JSONDecoder()))
  /// var settings = Settings()
  /// ```
  ///
  /// The state uses the store in the `defaultMMKVStore` dependency unless a key names another.
  /// It follows writes made through this package as they happen. A write made by another
  /// process, or by another copy of MMKV such as react-native-mmkv's, is only seen when the
  /// store is next read or written, or when ``MMKVStore/checkForExternalChanges()`` is called.
  public struct MMKVStorageKey<Value: Sendable>: SharedKey {
    private let store: MMKVStore
    private let key: String
    private let loadValue: @Sendable (MMKVStore, String) throws -> Value?
    private let saveValue: @Sendable (Value, MMKVStore, String) throws -> Void

    fileprivate init(
      key: String,
      store: MMKVStore?,
      load: @escaping @Sendable (MMKVStore, String) throws -> Value?,
      save: @escaping @Sendable (Value, MMKVStore, String) throws -> Void
    ) {
      @Dependency(\.defaultMMKVStore) var defaultStore
      self.store = store ?? defaultStore
      self.key = key
      self.loadValue = load
      self.saveValue = save
    }

    public var id: MMKVStorageKeyID {
      MMKVStorageKeyID(store: self.store, key: self.key)
    }

    public func load(context: LoadContext<Value>, continuation: LoadContinuation<Value>) {
      continuation.resume(with: Result { try self.loadValue(self.store, self.key) })
    }

    public func subscribe(
      context: LoadContext<Value>,
      subscriber: SharedSubscriber<Value>
    ) -> SharedSubscription {
      let subscription = self.store.subscribe(forKey: self.key) {
        subscriber.yield(with: Result { try self.loadValue(self.store, self.key) })
      }
      return SharedSubscription { subscription.cancel() }
    }

    public func save(_ value: Value, context: SaveContext, continuation: SaveContinuation) {
      continuation.resume(with: Result { try self.saveValue(value, self.store, self.key) })
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

    fileprivate init(store: MMKVStore, key: String) {
      self.store = store
      self.key = key
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.store === rhs.store && lhs.key == rhs.key
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(self.store))
      hasher.combine(self.key)
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

  extension MMKVStore {
    /// Runs a write to `key`, turning a write the store did not accept into an error.
    fileprivate func write(_ key: String, _ body: () throws -> Bool) throws {
      guard try body() else { throw MMKVError.writeFailed(key: key) }
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
    ///         MMKVConfiguration(rootDirectory: directory, mode: .multiProcess)
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
      return .temporary()
    }

    static var testValue: MMKVStore { .temporary() }
  }

  extension MMKVStore {
    /// An empty store in a directory of its own, which the system cleans up.
    fileprivate static func temporary() -> MMKVStore {
      let directory =
        temporaryDirectory() + "swift-mmkv-sharing-"
        + String(UInt64.random(in: .min ... .max), radix: 16)
      do {
        return try MMKVStore(MMKVConfiguration(rootDirectory: directory, mode: .singleProcess))
      } catch {
        fatalError("A temporary MMKV store could not be opened: \(error)")
      }
    }
  }
#endif
