// MARK: - Sequences

extension MMKVStore {
  /// The values of `key` over time, starting with the value the store holds when iteration
  /// begins.
  ///
  /// ```swift
  /// for await volume in store.values(forKey: "volume", as: Double.self) {
  ///   player.volume = volume ?? 1
  /// }
  /// ```
  ///
  /// An element is `nil` when the store has no value for `key`, or when its value is not a
  /// valid `V`. The sequence never finishes on its own. It ends when the task iterating it is
  /// cancelled.
  ///
  /// Each iteration observes the store separately, so the sequence can be iterated more than
  /// once, and by several tasks at a time. A consumer that falls behind skips to the newest
  /// value rather than receiving every one in between.
  ///
  /// While the store is suspended the sequence produces nothing, and it produces the store's
  /// value again when the store resumes.
  ///
  /// ## Repeated values
  ///
  /// The sequence produces an element whenever `key` is written, even with the value it
  /// already had, and whenever a change from another process is noticed, since such a change
  /// does not say which keys it touched. To see only actual changes, drop the repeats, for
  /// instance with `removeDuplicates()` from
  /// [swift-async-algorithms](https://github.com/apple/swift-async-algorithms):
  ///
  /// ```swift
  /// for await volume in store.values(forKey: "volume", as: Double.self).removeDuplicates() {
  ///   player.volume = volume ?? 1
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - key: The key to observe.
  ///   - type: The type to read the value as.
  public func values<V: MMKVValue & Sendable>(
    forKey key: String,
    as type: V.Type = V.self
  ) -> MMKVValues<V?> {
    MMKVValues(store: self, key: key) { store in
      let value = store.value(forKey: key, as: V.self)
      return value == nil && store.isSuspended ? nil : .some(value)
    }
  }

  /// The `Decodable` values of `key` over time, read with `decoder`, starting with the value
  /// the store holds when iteration begins.
  ///
  /// ```swift
  /// for try await settings in store.values(forKey: "settings", as: Settings.self, with: decoder) {
  ///   apply(settings ?? Settings())
  /// }
  /// ```
  ///
  /// An element is `nil` when the store has no value for `key`. A value that `decoder` cannot
  /// read is thrown from the iteration, which ends the sequence. In every other respect this
  /// behaves like ``values(forKey:as:)``, including producing repeated values.
  ///
  /// - Parameters:
  ///   - key: The key to observe.
  ///   - type: The type to decode.
  ///   - decoder: The decoder that reads the value.
  public func values<T: Decodable & Sendable, Decoder: MMKVTopLevelDecoder & Sendable>(
    forKey key: String,
    as type: T.Type = T.self,
    with decoder: Decoder
  ) -> MMKVThrowingValues<T?> where Decoder.Input: MMKVValue {
    MMKVThrowingValues(store: self, key: key) { store in
      try store.decode(T.self, forKey: key, with: decoder)
    }
  }
}

// MARK: - Typed Keys

extension MMKVStore {
  /// The values of `key` over time, starting with the value the store holds when iteration
  /// begins.
  ///
  /// ```swift
  /// for await volume in store.values(for: .volume) {
  ///   player.volume = volume
  /// }
  /// ```
  ///
  /// An element is the key's default whenever the store has no value for the key. In every
  /// other respect this behaves like ``values(forKey:as:)``, including producing repeated
  /// values.
  public func values<V>(for key: DefaultedKey<V>) -> MMKVValues<V> {
    MMKVValues(store: self, key: key.key.name) { store in
      let value = store.value(for: key.key)
      return value == nil && store.isSuspended ? nil : value ?? key.defaultValue
    }
  }

  /// The decoded values of `key` over time, starting with the value the store holds when
  /// iteration begins.
  ///
  /// ```swift
  /// for try await settings in store.values(for: .settings) {
  ///   apply(settings ?? Settings())
  /// }
  /// ```
  ///
  /// An element is `nil` when the store has no value for `key`. A value that the key's decoder
  /// cannot read is thrown from the iteration, which ends the sequence. In every other respect
  /// this behaves like ``values(forKey:as:)``, including producing repeated values.
  public func values<V>(for key: CodedKey<V>) -> MMKVThrowingValues<V?> {
    MMKVThrowingValues(store: self, key: key.name) { store in
      try store.value(for: key)
    }
  }

  /// The decoded values of `key` over time, starting with the value the store holds when
  /// iteration begins.
  ///
  /// ```swift
  /// for try await settings in store.values(for: .settings) {
  ///   apply(settings)
  /// }
  /// ```
  ///
  /// An element is the key's default whenever the store has no value for the key. A value
  /// that the key's decoder cannot read is thrown from the iteration, which ends the sequence.
  /// In every other respect this behaves like ``values(forKey:as:)``, including producing
  /// repeated values.
  public func values<V>(for key: DefaultedCodedKey<V>) -> MMKVThrowingValues<V> {
    MMKVThrowingValues(store: self, key: key.key.name) { store in
      try store.value(for: key)
    }
  }
}

// MARK: - MMKVValues

/// The values of one key of an ``MMKVStore`` over time, from the store's `values` methods that
/// cannot fail, such as ``MMKVStore/values(forKey:as:)``.
///
/// `Element` is what each iteration produces: an optional for a key that may have no value,
/// and the value itself for a key with a default.
public struct MMKVValues<Element: Sendable>: AsyncSequence, Sendable {
  private let store: MMKVStore
  private let key: String
  private let read: Read

  /// Reads the element, or returns `nil` if the store is suspended and turned the read away.
  /// Resuming the store signals a change, which reads the element again.
  fileprivate typealias Read = @Sendable (MMKVStore) -> Element?

  fileprivate init(store: MMKVStore, key: String, read: @escaping Read) {
    self.store = store
    self.key = key
    self.read = read
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(store: self.store, key: self.key, read: self.read)
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    private let read: Read
    private var values: KeyValueIterator

    fileprivate init(store: MMKVStore, key: String, read: @escaping Read) {
      self.read = read
      self.values = KeyValueIterator(store: store, key: key)
    }

    public mutating func next() async -> Element? {
      await self.values.next(self.read)
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func next(isolation actor: isolated (any Actor)?) async -> Element? {
      await self.values.next(isolation: actor, self.read)
    }
  }
}

// MARK: - MMKVThrowingValues

/// The decoded values of one key of an ``MMKVStore`` over time, from the store's `values`
/// methods that can fail, such as ``MMKVStore/values(forKey:as:with:)``.
///
/// `Element` is what each iteration produces: an optional for a key that may have no value,
/// and the value itself for a key with a default. An error ends the sequence.
public struct MMKVThrowingValues<Element: Sendable>: AsyncSequence, Sendable {
  private let store: MMKVStore
  private let key: String
  private let read: Read

  fileprivate typealias Read = @Sendable (MMKVStore) throws -> Element

  fileprivate init(store: MMKVStore, key: String, read: @escaping Read) {
    self.store = store
    self.key = key
    self.read = read
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(store: self.store, key: self.key, read: self.read)
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    private let read: Read
    private var values: KeyValueIterator

    fileprivate init(store: MMKVStore, key: String, read: @escaping Read) {
      self.read = read
      self.values = KeyValueIterator(store: store, key: key)
    }

    public mutating func next() async throws -> Element? {
      let read = self.read
      return try await self.values.next { try Self.element(from: $0, reading: read) }
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func next(isolation actor: isolated (any Actor)?) async throws -> Element? {
      let read = self.read
      return try await self.values.next(isolation: actor) {
        try Self.element(from: $0, reading: read)
      }
    }

    /// Reads the element, or returns `nil` if the store is suspended and turned the read away.
    /// Resuming the store signals a change, which reads the element again.
    private static func element(from store: MMKVStore, reading read: Read) throws -> Element? {
      do {
        return try read(store)
      } catch MMKVError.storeIsSuspended {
        return nil
      }
    }
  }
}
