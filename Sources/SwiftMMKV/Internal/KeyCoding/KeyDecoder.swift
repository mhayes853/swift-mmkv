#if Foundation
  import _SwiftMMKVFoundation
#endif

/// Reads a value that is spread over several keys of a store.
final class KeyDecodingContext {
  let store: MMKVStore
  let names: KeyNames
  let numbers: MMKVKeyCodingOptions.Numbers
  let arrays: KeyArrayCoding

  /// Every key in the store, read once, when something first needs to know which keys exist
  /// under another.
  private(set) lazy var storeKeys = Array(self.store.keys)

  init(store: MMKVStore, options: MMKVKeyCodingOptions) {
    self.store = store
    self.names = KeyNames(separator: options.separator)
    self.numbers = options.numbers
    self.arrays = KeyArrayCoding(options.arrays)
  }

  /// Whether `key` has a value, or is the start of the key of one.
  func contains(_ key: String) -> Bool {
    if !key.isEmpty && self.store.contains(key) { return true }
    return self.storeKeys.contains { self.names.firstPart(of: $0, under: key) != nil }
  }

  func decode<T: Decodable>(_ type: T.Type, at key: String, codingPath: [any CodingKey]) throws -> T
  {
    if let value = try self.primitive(type, at: key, codingPath: codingPath) { return value }
    do {
      return try T(
        from: KeyDecoder(key: key, codingPath: codingPath, context: self)
      )
    } catch is ArrayRequested {
      return try self.array(type, at: key, codingPath: codingPath)
    }
  }

  private func primitive<T: Decodable>(
    _ type: T.Type,
    at key: String,
    codingPath: [any CodingKey]
  ) throws -> T? {
    if type == Bool.self { return try self.stored(Bool.self, key, codingPath) as? T }
    if type == String.self { return try self.stored(String.self, key, codingPath) as? T }
    if type == Double.self { return try self.stored(Double.self, key, codingPath) as? T }
    if type == [UInt8].self { return try self.stored([UInt8].self, key, codingPath) as? T }
    if type == Float.self {
      guard self.numbers == .double else {
        return try self.stored(Float.self, key, codingPath) as? T
      }
      return Float(try self.stored(Double.self, key, codingPath)) as? T
    }
    if let type = type as? any FixedWidthInteger.Type {
      return try self.integer(type, key, codingPath) as? T
    }
    #if Foundation
      if type == Data.self { return try self.stored(Data.self, key, codingPath) as? T }
      if type == URL.self { return try self.stored(URL.self, key, codingPath) as? T }
      if type == UUID.self { return try self.stored(UUID.self, key, codingPath) as? T }
      if type == Decimal.self { return try self.stored(Decimal.self, key, codingPath) as? T }
    #endif
    return nil
  }

  private func integer<I: FixedWidthInteger>(
    _ type: I.Type,
    _ key: String,
    _ codingPath: [any CodingKey]
  ) throws -> I {
    let integer: I?
    let description: String
    switch (self.numbers, I.isSigned, I.bitWidth <= 32) {
    case (.double, _, _):
      let stored = try self.stored(Double.self, key, codingPath)
      (integer, description) = (I(exactly: stored), "\(stored)")
    case (.native, true, true):
      let stored = try self.stored(Int32.self, key, codingPath)
      (integer, description) = (I(exactly: stored), "\(stored)")
    case (.native, true, false):
      let stored = try self.stored(Int64.self, key, codingPath)
      (integer, description) = (I(exactly: stored), "\(stored)")
    case (.native, false, true):
      let stored = try self.stored(UInt32.self, key, codingPath)
      (integer, description) = (I(exactly: stored), "\(stored)")
    case (.native, false, false):
      let stored = try self.stored(UInt64.self, key, codingPath)
      (integer, description) = (I(exactly: stored), "\(stored)")
    }
    guard let integer else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: codingPath,
          debugDescription:
            "The number \(description) stored for '\(key)' is not a valid \(I.self)."
        )
      )
    }
    return integer
  }

  private func array<T: Decodable>(
    _ type: T.Type,
    at key: String,
    codingPath: [any CodingKey]
  ) throws -> T {
    switch self.arrays {
    case .coded(_, let decode):
      guard let value = try decode(type, self.store, key) as? T else {
        throw self.missing(key, codingPath)
      }
      return value
    case .native:
      if type == [String].self, let strings = try self.stored([String].self, key, codingPath) as? T
      {
        return strings
      }
      throw DecodingError.typeMismatch(
        type,
        DecodingError.Context(
          codingPath: codingPath,
          debugDescription: """
            Only arrays of strings and of bytes can be read without a coder for arrays. Set one \
            with MMKVKeyCodingOptions.arrays.
            """
        )
      )
    }
  }

  private func stored<V: MMKVValue>(
    _ type: V.Type,
    _ key: String,
    _ codingPath: [any CodingKey]
  ) throws -> V {
    if let value = self.store.value(forKey: key, as: type) { return value }
    guard self.store.contains(key) else { throw self.missing(key, codingPath) }
    throw DecodingError.dataCorrupted(
      DecodingError.Context(
        codingPath: codingPath,
        debugDescription: "The value stored for '\(key)' is not a valid \(type)."
      )
    )
  }

  /// The error for a key that has no value. A read that a suspended store turned away looks
  /// the same, so the store is asked.
  private func missing(_ key: String, _ codingPath: [any CodingKey]) -> any Error {
    if self.store.isSuspended {
      return MMKVError.storeIsSuspended(id: self.store.id)
    }
    return DecodingError.keyNotFound(
      codingPath.last ?? StoreCodingKey(stringValue: key),
      DecodingError.Context(
        codingPath: Array(codingPath.dropLast()),
        debugDescription: "The store has no value for '\(key)'."
      )
    )
  }
}

/// Thrown to a value that asks to be decoded as an array, to decode it whole instead.
private struct ArrayRequested: Error {}

// MARK: - Decoder

struct KeyDecoder: Decoder {
  let key: String
  let codingPath: [any CodingKey]
  let context: KeyDecodingContext

  var userInfo: [CodingUserInfoKey: Any] { [:] }

  func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
    KeyedDecodingContainer(KeyedContainer<Key>(decoder: self))
  }

  func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
    throw ArrayRequested()
  }

  func singleValueContainer() throws -> any SingleValueDecodingContainer {
    SingleValueContainer(decoder: self)
  }

  fileprivate func child(_ key: some CodingKey) -> KeyDecoder {
    KeyDecoder(
      key: self.context.names.child(key.stringValue, of: self.key),
      codingPath: self.codingPath + [key],
      context: self.context
    )
  }

  fileprivate func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try self.context.decode(type, at: self.key, codingPath: self.codingPath)
  }
}

// MARK: - Containers

extension KeyDecoder {
  private struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: KeyDecoder

    var codingPath: [any CodingKey] { self.decoder.codingPath }

    var allKeys: [Key] {
      var parts = Set<String>()
      for key in self.decoder.context.storeKeys {
        guard let part = self.decoder.context.names.firstPart(of: key, under: self.decoder.key)
        else { continue }
        parts.insert(part)
      }
      return parts.compactMap { Key(stringValue: $0) }
    }

    func contains(_ key: Key) -> Bool {
      self.decoder.context.contains(self.decoder.child(key).key)
    }

    func decodeNil(forKey key: Key) throws -> Bool { !self.contains(key) }
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try self.get(type, key) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try self.get(type, key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try self.get(type, key) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try self.get(type, key) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try self.get(type, key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try self.get(type, key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try self.get(type, key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try self.get(type, key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try self.get(type, key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try self.get(type, key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try self.get(type, key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try self.get(type, key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try self.get(type, key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try self.get(type, key) }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
      try self.get(type, key)
    }

    func nestedContainer<NestedKey: CodingKey>(
      keyedBy type: NestedKey.Type,
      forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
      try self.decoder.child(key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
      throw DecodingError.typeMismatch(
        [Any].self,
        DecodingError.Context(
          codingPath: self.codingPath + [key],
          debugDescription: """
            An array can only be decoded from store keys as a value of its own, not through \
            nestedUnkeyedContainer(forKey:).
            """
        )
      )
    }

    func superDecoder() throws -> any Decoder {
      self.decoder.child(StoreCodingKey(stringValue: "super"))
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
      self.decoder.child(key)
    }

    private func get<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T {
      try self.decoder.child(key).decode(type)
    }
  }

  private struct SingleValueContainer: SingleValueDecodingContainer {
    let decoder: KeyDecoder

    var codingPath: [any CodingKey] { self.decoder.codingPath }

    func decodeNil() -> Bool { !self.decoder.context.contains(self.decoder.key) }
    func decode(_ type: Bool.Type) throws -> Bool { try self.decoder.decode(type) }
    func decode(_ type: String.Type) throws -> String { try self.decoder.decode(type) }
    func decode(_ type: Double.Type) throws -> Double { try self.decoder.decode(type) }
    func decode(_ type: Float.Type) throws -> Float { try self.decoder.decode(type) }
    func decode(_ type: Int.Type) throws -> Int { try self.decoder.decode(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try self.decoder.decode(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try self.decoder.decode(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try self.decoder.decode(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try self.decoder.decode(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try self.decoder.decode(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try self.decoder.decode(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try self.decoder.decode(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try self.decoder.decode(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try self.decoder.decode(type) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try self.decoder.decode(type) }
  }
}
