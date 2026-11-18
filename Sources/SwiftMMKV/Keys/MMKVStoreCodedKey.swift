extension MMKVStore {
  /// A key of a store for a `Codable` value, together with the coders that store it.
  ///
  /// ```swift
  /// extension MMKVStore.CodedKey where Value == Settings {
  ///   static let settings = Self("settings", encoder: JSONEncoder(), decoder: JSONDecoder())
  /// }
  ///
  /// try store.set(Settings(theme: .dark), for: .settings)
  /// let settings = try store.value(for: .settings)
  /// ```
  ///
  /// The whole value is stored under the one key, as whatever the encoder produces. A key
  /// reads and writes exactly what ``MMKVStore/encode(_:forKey:expiringIn:with:)`` and
  /// ``MMKVStore/decode(_:forKey:with:)`` do with the same name and coders.
  ///
  /// Reading and writing throw what the coders throw, which is why a coded key has no
  /// subscript.
  ///
  /// ## Equality
  ///
  /// Two keys are equal when they have the same name and the same encoder and decoder
  /// objects. A key built in a function is therefore only equal to another one built by that
  /// function when both are given the same coders, rather than each a new one:
  ///
  /// ```swift
  /// extension MMKVStore.CodedKey where Value == Draft {
  ///   private static let coders = (JSONEncoder(), JSONDecoder())
  ///
  ///   static func draft(_ postID: Int) -> Self {
  ///     Self("draft.\(postID)", encoder: coders.0, decoder: coders.1)
  ///   }
  /// }
  /// ```
  public struct CodedKey<Value: Codable & Sendable>: Sendable {
    /// The key in the store.
    public let name: String

    private let encoder: ObjectIdentifier
    private let decoder: ObjectIdentifier
    fileprivate let read: @Sendable (MMKVStore) throws -> Value?
    fileprivate let write: @Sendable (Value, MMKVStore, Duration?) throws -> Bool

    /// Creates a key.
    ///
    /// - Parameters:
    ///   - name: The key in the store, which must not be empty.
    ///   - type: The type the value is read and written as.
    ///   - encoder: The encoder that writes the value.
    ///   - decoder: The decoder that reads the value.
    public init<
      Encoder: MMKVTopLevelEncoder & AnyObject & Sendable,
      Decoder: MMKVTopLevelDecoder & AnyObject & Sendable
    >(
      _ name: String,
      as type: Value.Type = Value.self,
      encoder: Encoder,
      decoder: Decoder
    ) where Encoder.Output: MMKVValue, Decoder.Input: MMKVValue {
      self.name = name
      self.encoder = ObjectIdentifier(encoder)
      self.decoder = ObjectIdentifier(decoder)
      self.read = { store in
        try store.decode(Value.self, forKey: name, with: decoder)
      }
      self.write = { value, store, expiringIn in
        try store.encode(value, forKey: name, expiringIn: expiringIn, with: encoder)
      }
    }
  }
}

extension MMKVStore.CodedKey: Hashable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.name == rhs.name && lhs.encoder == rhs.encoder && lhs.decoder == rhs.decoder
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(self.name)
    hasher.combine(self.encoder)
    hasher.combine(self.decoder)
  }
}

extension MMKVStore.CodedKey: CustomStringConvertible {
  public var description: String {
    self.name
  }
}

// MARK: - Values

extension MMKVStore {
  /// Reads the value of `key` and decodes it with the key's decoder.
  ///
  /// - Returns: The value, or `nil` if the key has no value.
  /// - Throws: Whatever the decoder throws when the stored value does not decode, or
  ///   ``MMKVError/storeIsSuspended(id:)`` if the store is suspended.
  public func value<V>(for key: CodedKey<V>) throws -> V? {
    try key.read(self)
  }

  /// Encodes `value` with the key's encoder and stores the result under `key`, replacing any
  /// existing value.
  ///
  /// - Parameters:
  ///   - value: The value to encode.
  ///   - key: The key.
  ///   - expiringIn: How long to keep the value. See ``set(_:forKey:expiringIn:)``.
  /// - Returns: Whether the encoded value was stored.
  /// - Throws: Whatever the encoder throws, in which case nothing is stored, or
  ///   ``MMKVError/storeIsSuspended(id:)`` if the store is suspended.
  @discardableResult
  public func set<V>(
    _ value: V,
    for key: CodedKey<V>,
    expiringIn: Duration? = nil
  ) throws -> Bool {
    try key.write(value, self, expiringIn)
  }

  /// Whether `key` has a value. The value is not decoded.
  public func contains<V>(_ key: CodedKey<V>) -> Bool {
    self.contains(key.name)
  }

  /// Removes `key` and its value.
  ///
  /// - Returns: Whether the store accepted the removal. See ``removeValue(forKey:)``.
  @discardableResult
  public func removeValue<V>(for key: CodedKey<V>) -> Bool {
    self.removeValue(forKey: key.name)
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
  public func values<V>(for key: CodedKey<V>) -> MMKVCodedValues<V> {
    MMKVCodedValues(store: self, key: key)
  }
}

// MARK: - MMKVCodedValues

/// The decoded values of one ``MMKVStore/CodedKey`` over time, from the store's
/// `values(for:)`.
public struct MMKVCodedValues<Value: Codable & Sendable>: AsyncSequence, Sendable {
  public typealias Element = Value?

  private let store: MMKVStore
  private let key: MMKVStore.CodedKey<Value>

  fileprivate init(store: MMKVStore, key: MMKVStore.CodedKey<Value>) {
    self.store = store
    self.key = key
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(store: self.store, key: self.key)
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    private let store: MMKVStore
    private let key: MMKVStore.CodedKey<Value>
    private var signals: KeyChangeSignals?

    fileprivate init(store: MMKVStore, key: MMKVStore.CodedKey<Value>) {
      self.store = store
      self.key = key
      self.signals = KeyChangeSignals(store: store, key: key.name)
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
        return .some(try self.store.value(for: self.key))
      } catch MMKVError.storeIsSuspended {
        return nil
      } catch {
        self.signals = nil
        throw error
      }
    }
  }
}
