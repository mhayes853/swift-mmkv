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
  ) -> MMKVValues<V> {
    MMKVValues(store: self, key: key)
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
  ) -> MMKVDecodedValues<T, Decoder> where Decoder.Input: MMKVValue {
    MMKVDecodedValues(store: self, key: key, decoder: decoder)
  }
}

// MARK: - MMKVValues

/// The values of one key of an ``MMKVStore`` over time, from ``MMKVStore/values(forKey:as:)``.
public struct MMKVValues<Value: MMKVValue & Sendable>: AsyncSequence, Sendable {
  public typealias Element = Value?

  private let store: MMKVStore
  private let key: String

  fileprivate init(store: MMKVStore, key: String) {
    self.store = store
    self.key = key
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(store: self.store, key: self.key)
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    private var values: KeyValueIterator

    fileprivate init(store: MMKVStore, key: String) {
      self.values = KeyValueIterator(store: store, key: key)
    }

    public mutating func next() async -> Value?? {
      await self.values.next(Self.read)
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func next(isolation actor: isolated (any Actor)?) async -> Value?? {
      await self.values.next(isolation: actor, Self.read)
    }

    /// Reads the value, or returns `nil` if the store is suspended and turned the read away.
    private static func read(from store: MMKVStore, key: String) -> Value?? {
      let value = store.value(forKey: key, as: Value.self)
      return value == nil && store.isSuspended ? nil : .some(value)
    }
  }
}

// MARK: - MMKVDecodedValues

/// The decoded values of one key of an ``MMKVStore`` over time, from
/// ``MMKVStore/values(forKey:as:with:)``.
public struct MMKVDecodedValues<
  Value: Decodable & Sendable,
  Decoder: MMKVTopLevelDecoder & Sendable
>: AsyncSequence, Sendable where Decoder.Input: MMKVValue {
  public typealias Element = Value?

  private let store: MMKVStore
  private let key: String
  private let decoder: Decoder

  fileprivate init(store: MMKVStore, key: String, decoder: Decoder) {
    self.store = store
    self.key = key
    self.decoder = decoder
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(store: self.store, key: self.key, decoder: self.decoder)
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    private let decoder: Decoder
    private var values: KeyValueIterator

    fileprivate init(store: MMKVStore, key: String, decoder: Decoder) {
      self.decoder = decoder
      self.values = KeyValueIterator(store: store, key: key)
    }

    public mutating func next() async throws -> Value?? {
      let decoder = self.decoder
      return try await self.values.next { store, key in
        try Self.decode(from: store, key: key, with: decoder)
      }
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func next(isolation actor: isolated (any Actor)?) async throws -> Value?? {
      let decoder = self.decoder
      return try await self.values.next(isolation: actor) { store, key in
        try Self.decode(from: store, key: key, with: decoder)
      }
    }

    /// Decodes the value, or returns `nil` if the store is suspended and turned the read away.
    /// A value that cannot be decoded is thrown, which ends the sequence.
    private static func decode(
      from store: MMKVStore,
      key: String,
      with decoder: Decoder
    ) throws -> Value?? {
      do {
        return .some(try store.decode(Value.self, forKey: key, with: decoder))
      } catch MMKVError.storeIsSuspended {
        return nil
      }
    }
  }
}
