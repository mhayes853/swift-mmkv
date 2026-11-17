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
    MMKVValues(store: self, key: key) { store, key in store.value(forKey: key, as: V.self) }
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
  ) -> MMKVThrowingValues<T> where Decoder.Input: MMKVValue {
    MMKVThrowingValues(store: self, key: key) { store, key in
      try store.decode(T.self, forKey: key, with: decoder)
    }
  }
}

// MARK: - MMKVValues

/// The values of one key of an ``MMKVStore`` over time, from ``MMKVStore/values(forKey:as:)``.
public struct MMKVValues<Value: Sendable>: AsyncSequence, Sendable {
  public typealias Element = Value?

  private let store: MMKVStore
  private let key: String
  private let read: @Sendable (MMKVStore, String) -> Value?

  fileprivate init(
    store: MMKVStore,
    key: String,
    read: @escaping @Sendable (MMKVStore, String) -> Value?
  ) {
    self.store = store
    self.key = key
    self.read = read
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(
      signals: KeyChangeSignals(store: self.store, key: self.key),
      read: { [store, key, read] in read(store, key) }
    )
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    private var signals: KeyChangeSignals
    private let read: @Sendable () -> Value?

    fileprivate init(signals: KeyChangeSignals, read: @escaping @Sendable () -> Value?) {
      self.signals = signals
      self.read = read
    }

    public mutating func next() async -> Value?? {
      guard await self.signals.next() else { return nil }
      return .some(self.read())
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func next(isolation actor: isolated (any Actor)?) async -> Value?? {
      guard await self.signals.next(isolation: actor) else { return nil }
      return .some(self.read())
    }
  }
}

// MARK: - MMKVThrowingValues

/// The decoded values of one key of an ``MMKVStore`` over time, from
/// ``MMKVStore/values(forKey:as:with:)``.
public struct MMKVThrowingValues<Value: Sendable>: AsyncSequence, Sendable {
  public typealias Element = Value?

  private let store: MMKVStore
  private let key: String
  private let read: @Sendable (MMKVStore, String) throws -> Value?

  fileprivate init(
    store: MMKVStore,
    key: String,
    read: @escaping @Sendable (MMKVStore, String) throws -> Value?
  ) {
    self.store = store
    self.key = key
    self.read = read
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(
      signals: KeyChangeSignals(store: self.store, key: self.key),
      read: { [store, key, read] in try read(store, key) }
    )
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    private var signals: KeyChangeSignals?
    private let read: @Sendable () throws -> Value?

    fileprivate init(signals: KeyChangeSignals, read: @escaping @Sendable () throws -> Value?) {
      self.signals = signals
      self.read = read
    }

    public mutating func next() async throws -> Value?? {
      guard await self.signals?.next() == true else { return nil }
      return .some(try self.readOrFinish())
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func next(isolation actor: isolated (any Actor)?) async throws -> Value?? {
      guard await self.signals?.next(isolation: actor) == true else { return nil }
      return .some(try self.readOrFinish())
    }

    /// Reads the value, ending the sequence if it cannot be read.
    private mutating func readOrFinish() throws -> Value? {
      do {
        return try self.read()
      } catch {
        self.signals = nil
        throw error
      }
    }
  }
}
