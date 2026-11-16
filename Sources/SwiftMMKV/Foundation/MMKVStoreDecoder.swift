#if Foundation
  import _SwiftMMKVFoundation

  extension MMKVStore {
    /// How numeric properties are read when decoding a whole store.
    public enum NumberDecodingStrategy: Sendable, Hashable {
      /// Each numeric type reads its own encoding: `Double` a double, `Int32` a 32-bit integer,
      /// and so on. `Int` and `UInt` read 64-bit integers, and the 8- and 16-bit types read
      /// 32-bit integers.
      case exact

      /// Every numeric property is read as a `Double` and converted, which is how JavaScript
      /// stores every number. A value that the property's type cannot represent exactly fails to
      /// decode.
      case javaScript
    }

    /// Decodes the whole store as one keyed value, reading each property from the key named by
    /// its coding key.
    ///
    /// The store records no types, so the properties' declared types decide how each key is
    /// read:
    ///
    /// - `Bool`, `String`, and the numeric types use the matching typed read.
    /// - Types conforming to ``MMKVValue``, including `Data`, read themselves.
    /// - Any other `Decodable` type is read as a JSON string and decoded with `JSONDecoder`,
    ///   which is how React Native apps store objects.
    /// - An optional property is `nil` when its key has no value.
    ///
    /// ```swift
    /// struct AppState: Decodable {
    ///   var hasOnboarded: Bool
    ///   var launchCount: Int
    ///   var username: String?
    ///   var settings: Settings
    /// }
    ///
    /// let state = try store.decode(AppState.self, numbers: .javaScript)
    /// ```
    ///
    /// The store is locked for the duration, so the value is one consistent snapshot.
    ///
    /// - Parameters:
    ///   - type: The type to decode, which must decode from a keyed container.
    ///   - numbers: How numeric properties are read.
    /// - Throws: A `DecodingError` if a required key has no value, a value does not decode, or
    ///   `type` does not decode from a keyed container.
    public func decode<T: Decodable>(
      _ type: T.Type = T.self,
      numbers: NumberDecodingStrategy = .exact
    ) throws -> T {
      try self.withExclusiveLock { store in
        try T(from: MMKVStoreDecoder(store: store, numbers: numbers))
      }
    }
  }

  private struct MMKVStoreDecoder: Decoder {
    let store: MMKVStore
    let numbers: MMKVStore.NumberDecodingStrategy
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(
      keyedBy type: Key.Type
    ) throws -> KeyedDecodingContainer<Key> {
      KeyedDecodingContainer(KeyedContainer<Key>(store: self.store, numbers: self.numbers))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
      throw self.notKeyed([Any].self)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
      throw self.notKeyed(Any.self)
    }

    private func notKeyed(_ type: Any.Type) -> DecodingError {
      .typeMismatch(
        type,
        DecodingError.Context(
          codingPath: [],
          debugDescription: "An MMKV store is a flat key-value map, so it only decodes as a "
            + "keyed container."
        )
      )
    }
  }

  private struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let store: MMKVStore
    let numbers: MMKVStore.NumberDecodingStrategy
    var codingPath: [any CodingKey] { [] }

    var allKeys: [Key] {
      self.store.keys.compactMap { Key(stringValue: $0) }
    }

    func contains(_ key: Key) -> Bool {
      self.store.contains(key.stringValue)
    }

    func decodeNil(forKey key: Key) throws -> Bool {
      !self.contains(key)
    }

    // MARK: Reading

    private func read<V: MMKVValue>(_ type: V.Type, forKey key: Key) throws -> V {
      if let value = self.store.value(forKey: key.stringValue, as: type) {
        return value
      }
      guard self.contains(key) else {
        throw DecodingError.keyNotFound(
          key,
          DecodingError.Context(
            codingPath: [],
            debugDescription: "The store has no value for the key \"\(key.stringValue)\"."
          )
        )
      }
      throw self.corrupted(key, "The value is not a valid \(type).")
    }

    private func corrupted(_ key: Key, _ description: String) -> DecodingError {
      .dataCorrupted(DecodingError.Context(codingPath: [key], debugDescription: description))
    }

    private func integer<Stored: MMKVValue & BinaryInteger, T: BinaryInteger>(
      _ type: T.Type,
      storedAs stored: Stored.Type,
      forKey key: Key
    ) throws -> T {
      switch self.numbers {
      case .exact:
        let value = try self.read(stored, forKey: key)
        guard let converted = T(exactly: value) else {
          throw self.corrupted(key, "The stored integer \(value) does not fit in \(type).")
        }
        return converted
      case .javaScript:
        let value = try self.read(Double.self, forKey: key)
        guard let converted = T(exactly: value) else {
          throw self.corrupted(
            key,
            "The stored number \(value) cannot be represented exactly as \(type)."
          )
        }
        return converted
      }
    }

    // MARK: Primitives

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
      try self.read(type, forKey: key)
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
      try self.read(type, forKey: key)
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
      try self.read(type, forKey: key)
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
      switch self.numbers {
      case .exact: try self.read(type, forKey: key)
      case .javaScript: Float(try self.read(Double.self, forKey: key))
      }
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
      try self.integer(type, storedAs: Int64.self, forKey: key)
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
      try self.integer(type, storedAs: Int32.self, forKey: key)
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
      try self.integer(type, storedAs: Int32.self, forKey: key)
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
      try self.integer(type, storedAs: Int32.self, forKey: key)
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
      try self.integer(type, storedAs: Int64.self, forKey: key)
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
      try self.integer(type, storedAs: UInt64.self, forKey: key)
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
      try self.integer(type, storedAs: UInt32.self, forKey: key)
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
      try self.integer(type, storedAs: UInt32.self, forKey: key)
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
      try self.integer(type, storedAs: UInt32.self, forKey: key)
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
      try self.integer(type, storedAs: UInt64.self, forKey: key)
    }

    // MARK: Other types

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
      if let type = type as? any MMKVValue.Type {
        return try self.readExistential(type, forKey: key) as! T
      }
      let data = try self.read(JSONStringData.self, forKey: key).data
      do {
        return try JSONDecoder().decode(type, from: data)
      } catch let error as DecodingError {
        throw error.prefixingCodingPath(with: key)
      }
    }

    private func readExistential<V: MMKVValue>(_ type: V.Type, forKey key: Key) throws -> Any {
      try self.read(type, forKey: key)
    }

    // MARK: Nesting

    func nestedContainer<NestedKey: CodingKey>(
      keyedBy type: NestedKey.Type,
      forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
      throw self.notNested(key)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
      throw self.notNested(key)
    }

    func superDecoder() throws -> any Decoder {
      throw self.notNested(nil)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
      throw self.notNested(key)
    }

    private func notNested(_ key: Key?) -> DecodingError {
      .dataCorrupted(
        DecodingError.Context(
          codingPath: key.map { [$0] } ?? [],
          debugDescription: "An MMKV store is a flat key-value map with no nested containers. "
            + "Decode a nested value as a property of its own type instead."
        )
      )
    }
  }

  /// The UTF-8 bytes of a string value, without building a `String` from them.
  private struct JSONStringData: MMKVValue {
    let data: Data

    init?(from reader: borrowing MMKVValueReader) {
      let data = reader.withBytes { span in
        span.withUnsafeBytes { Data($0) }
      }
      guard let data else { return nil }
      self.data = data
    }

    func write(to writer: inout MMKVValueWriter) -> Bool { false }
  }

  extension DecodingError {
    /// The same error with `key` in front of its coding path, so that an error from decoding a
    /// nested JSON value names the store key the JSON was read from.
    fileprivate func prefixingCodingPath(with key: any CodingKey) -> DecodingError {
      func prefixed(_ context: Context) -> Context {
        Context(
          codingPath: [key] + context.codingPath,
          debugDescription: context.debugDescription,
          underlyingError: context.underlyingError
        )
      }
      return switch self {
      case .typeMismatch(let type, let context): .typeMismatch(type, prefixed(context))
      case .valueNotFound(let type, let context): .valueNotFound(type, prefixed(context))
      case .keyNotFound(let missing, let context): .keyNotFound(missing, prefixed(context))
      case .dataCorrupted(let context): .dataCorrupted(prefixed(context))
      @unknown default: self
      }
    }
  }
#endif
