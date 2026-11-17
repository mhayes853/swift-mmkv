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
    private let store: MMKVStore
    private let key: String
    private var signals: KeyChangeSignals

    fileprivate init(store: MMKVStore, key: String) {
      self.store = store
      self.key = key
      self.signals = KeyChangeSignals(store: store, key: key)
    }

    public mutating func next() async -> Value?? {
      while await self.signals.next() {
        if let element = self.read() { return element }
      }
      return nil
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func next(isolation actor: isolated (any Actor)?) async -> Value?? {
      while await self.signals.next(isolation: actor) {
        if let element = self.read() { return element }
      }
      return nil
    }

    /// Reads the value, or returns `nil` if the store is suspended and turned the read away.
    /// Resuming the store signals a change, which reads the value again.
    private func read() -> Value?? {
      let value = self.store.value(forKey: self.key, as: Value.self)
      return value == nil && self.store.isSuspended ? nil : .some(value)
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
    private let store: MMKVStore
    private let key: String
    private let decoder: Decoder
    private var signals: KeyChangeSignals?

    fileprivate init(store: MMKVStore, key: String, decoder: Decoder) {
      self.store = store
      self.key = key
      self.decoder = decoder
      self.signals = KeyChangeSignals(store: store, key: key)
    }

    public mutating func next() async throws -> Value?? {
      while await self.signals?.next() == true {
        if let element = try self.decodeOrFinish() { return element }
      }
      return nil
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func next(isolation actor: isolated (any Actor)?) async throws -> Value?? {
      while await self.signals?.next(isolation: actor) == true {
        if let element = try self.decodeOrFinish() { return element }
      }
      return nil
    }

    /// Decodes the value, ending the sequence if it cannot be decoded.
    ///
    /// - Returns: `nil` if the store is suspended and turned the read away. Resuming the store
    ///   signals a change, which reads the value again.
    private mutating func decodeOrFinish() throws -> Value?? {
      do {
        return .some(try self.store.decode(Value.self, forKey: self.key, with: self.decoder))
      } catch MMKVError.storeIsSuspended {
        return nil
      } catch {
        self.signals = nil
        throw error
      }
    }
  }
}
