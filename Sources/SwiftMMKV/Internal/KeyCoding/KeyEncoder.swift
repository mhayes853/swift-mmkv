#if Foundation
  import _SwiftMMKVFoundation
#endif

/// What encoding a value into store keys asks of the store. Nothing is written until the whole
/// value has encoded.
enum KeyEncodingOperation {
  case set(key: String, write: KeyWrite)
  /// Removes `key` and the keys of its parts.
  case removeAtOrUnder(key: String)
}

/// Collects the operations of one value.
final class KeyEncodingBuffer {
  var operations = [KeyEncodingOperation]()
  /// Whether the value asked to be encoded as an array, which is stored whole instead.
  var isArray = false
  var error: (any Error)?
}

struct KeyEncodingContext {
  let names: KeyNames
  let numbers: MMKVKeyCodingOptions.Numbers
  let arrays: KeyArrayCoding

  init(_ options: MMKVKeyCodingOptions) {
    self.names = KeyNames(separator: options.separator)
    self.numbers = options.numbers
    self.arrays = KeyArrayCoding(options.arrays)
  }

  /// Encodes `value` at `key`, adding its operations to `buffer`.
  func encode<T: Encodable>(
    _ value: T,
    at key: String,
    codingPath: [any CodingKey],
    into buffer: KeyEncodingBuffer
  ) throws {
    // Nothing encoded inside an array is kept, since the array is encoded again as a whole.
    guard !buffer.isArray else { return }
    if let write = try self.primitiveWrite(value, codingPath: codingPath) {
      buffer.operations.append(.set(key: key, write: write))
      return
    }
    let child = KeyEncodingBuffer()
    try value.encode(
      to: KeyEncoder(key: key, codingPath: codingPath, buffer: child, context: self)
    )
    if let error = child.error { throw error }
    guard child.isArray else {
      buffer.operations.append(contentsOf: child.operations)
      return
    }
    buffer.operations.append(
      .set(key: key, write: try self.arrayWrite(value, codingPath: codingPath))
    )
  }

  private func primitiveWrite(
    _ value: any Encodable,
    codingPath: [any CodingKey]
  ) throws -> KeyWrite? {
    switch value {
    case let value as Bool: return Self.write(value)
    case let value as String: return Self.write(value)
    case let value as Double: return Self.write(value)
    case let value as Float:
      return self.numbers == .double ? Self.write(Double(value)) : Self.write(value)
    case let value as [UInt8]: return Self.write(value)
    case let value as any FixedWidthInteger:
      return try self.integerWrite(value, codingPath: codingPath)
    default:
      #if Foundation
        // Stored as they are outside a coder. A URL and a decimal would otherwise encode
        // themselves as several keys, which is no use to another reader of the store, and a
        // date as seconds since 2001, which JavaScript does not use.
        if let value = value as? Data { return Self.write(value) }
        if let value = value as? URL { return Self.write(value) }
        if let value = value as? UUID { return Self.write(value) }
        if let value = value as? Date { return Self.write(value) }
        if let value = value as? Date.MMKVMillisecondsSince1970 { return Self.write(value) }
        if let value = value as? Date.MMKVSecondsSince1970 { return Self.write(value) }
        if let value = value as? Date.MMKVSecondsSinceReferenceDate { return Self.write(value) }
        if let value = value as? Decimal {
          guard !value.isNaN else {
            throw EncodingError.invalidValue(
              value,
              EncodingError.Context(
                codingPath: codingPath,
                debugDescription: "A decimal that is not a number cannot be stored."
              )
            )
          }
          return Self.write(value)
        }
      #endif
      return nil
    }
  }

  private func integerWrite<I: FixedWidthInteger>(
    _ value: I,
    codingPath: [any CodingKey]
  ) throws -> KeyWrite {
    let write: KeyWrite?
    switch (self.numbers, I.isSigned, I.bitWidth <= 32) {
    case (.double, _, _): write = Double(exactly: value).map(Self.write)
    case (.native, true, true): write = Int32(exactly: value).map(Self.write)
    case (.native, true, false): write = Int64(exactly: value).map(Self.write)
    case (.native, false, true): write = UInt32(exactly: value).map(Self.write)
    case (.native, false, false): write = UInt64(exactly: value).map(Self.write)
    }
    guard let write else {
      let description =
        self.numbers == .double
        ? "\(value) cannot be stored as a Double without losing precision."
        : "\(value) does not fit in 64 bits."
      throw EncodingError.invalidValue(
        value,
        EncodingError.Context(codingPath: codingPath, debugDescription: description)
      )
    }
    return write
  }

  private func arrayWrite(_ value: any Encodable, codingPath: [any CodingKey]) throws -> KeyWrite {
    switch self.arrays {
    case .coded(let encode, _):
      return try encode(value)
    case .native:
      if let strings = value as? [String] { return Self.write(strings) }
      throw EncodingError.invalidValue(
        value,
        EncodingError.Context(
          codingPath: codingPath,
          debugDescription: """
            Only arrays of strings and of bytes can be stored without a coder for arrays. Set \
            one with MMKVKeyCodingOptions.arrays.
            """
        )
      )
    }
  }

  private static func write<V: MMKVValue>(_ value: V) -> KeyWrite {
    { store, key, expiringIn in store.set(value, forKey: key, expiringIn: expiringIn) }
  }
}

// MARK: - Encoder

struct KeyEncoder: Encoder {
  let key: String
  let codingPath: [any CodingKey]
  let buffer: KeyEncodingBuffer
  let context: KeyEncodingContext

  var userInfo: [CodingUserInfoKey: Any] { [:] }

  func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
    KeyedEncodingContainer(KeyedContainer<Key>(encoder: self))
  }

  func unkeyedContainer() -> any UnkeyedEncodingContainer {
    self.buffer.isArray = true
    return UnkeyedContainer(encoder: self)
  }

  func singleValueContainer() -> any SingleValueEncodingContainer {
    SingleValueContainer(encoder: self)
  }

  fileprivate func child(_ key: some CodingKey) -> KeyEncoder {
    KeyEncoder(
      key: self.context.names.child(key.stringValue, of: self.key),
      codingPath: self.codingPath + [key],
      buffer: self.buffer,
      context: self.context
    )
  }

  fileprivate func encode<T: Encodable>(_ value: T) throws {
    try self.context.encode(
      value,
      at: self.key,
      codingPath: self.codingPath,
      into: self.buffer
    )
  }

  fileprivate func encodeNil() {
    guard !self.buffer.isArray else { return }
    self.buffer.operations.append(.removeAtOrUnder(key: self.key))
  }

  /// Arrays are stored whole, which needs the array itself, and a container only sees its
  /// elements.
  fileprivate func refuseNestedArray() {
    guard self.buffer.error == nil else { return }
    self.buffer.error = EncodingError.invalidValue(
      [Any](),
      EncodingError.Context(
        codingPath: self.codingPath,
        debugDescription: """
          An array can only be encoded into store keys as a value of its own, not through \
          nestedUnkeyedContainer(forKey:).
          """
      )
    )
  }
}

// MARK: - Containers

extension KeyEncoder {
  private struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: KeyEncoder

    var codingPath: [any CodingKey] { self.encoder.codingPath }

    mutating func encodeNil(forKey key: Key) throws { self.encoder.child(key).encodeNil() }
    mutating func encode(_ value: Bool, forKey key: Key) throws { try self.put(value, key) }
    mutating func encode(_ value: String, forKey key: Key) throws { try self.put(value, key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { try self.put(value, key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { try self.put(value, key) }
    mutating func encode(_ value: Int, forKey key: Key) throws { try self.put(value, key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { try self.put(value, key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { try self.put(value, key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { try self.put(value, key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { try self.put(value, key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { try self.put(value, key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { try self.put(value, key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { try self.put(value, key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { try self.put(value, key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { try self.put(value, key) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
      try self.put(value, key)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
      keyedBy keyType: NestedKey.Type,
      forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
      self.encoder.child(key).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
      let child = self.encoder.child(key)
      child.refuseNestedArray()
      return UnkeyedContainer(encoder: child)
    }

    mutating func superEncoder() -> any Encoder {
      self.encoder.child(StoreCodingKey(stringValue: "super"))
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
      self.encoder.child(key)
    }

    private func put<T: Encodable>(_ value: T, _ key: Key) throws {
      try self.encoder.child(key).encode(value)
    }
  }

  /// Keeps nothing: an array is stored whole, from the value that asked for this container.
  private struct UnkeyedContainer: UnkeyedEncodingContainer {
    let encoder: KeyEncoder
    private(set) var count = 0

    init(encoder: KeyEncoder) {
      self.encoder = encoder
    }

    var codingPath: [any CodingKey] { self.encoder.codingPath }

    mutating func encodeNil() throws { self.count += 1 }
    mutating func encode(_ value: Bool) throws { self.count += 1 }
    mutating func encode(_ value: String) throws { self.count += 1 }
    mutating func encode(_ value: Double) throws { self.count += 1 }
    mutating func encode(_ value: Float) throws { self.count += 1 }
    mutating func encode(_ value: Int) throws { self.count += 1 }
    mutating func encode(_ value: Int8) throws { self.count += 1 }
    mutating func encode(_ value: Int16) throws { self.count += 1 }
    mutating func encode(_ value: Int32) throws { self.count += 1 }
    mutating func encode(_ value: Int64) throws { self.count += 1 }
    mutating func encode(_ value: UInt) throws { self.count += 1 }
    mutating func encode(_ value: UInt8) throws { self.count += 1 }
    mutating func encode(_ value: UInt16) throws { self.count += 1 }
    mutating func encode(_ value: UInt32) throws { self.count += 1 }
    mutating func encode(_ value: UInt64) throws { self.count += 1 }
    mutating func encode<T: Encodable>(_ value: T) throws { self.count += 1 }

    mutating func nestedContainer<NestedKey: CodingKey>(
      keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
      self.count += 1
      return self.discarding.container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
      self.count += 1
      return self.discarding.unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
      self.count += 1
      return self.discarding
    }

    private var discarding: KeyEncoder {
      let buffer = KeyEncodingBuffer()
      buffer.isArray = true
      return KeyEncoder(
        key: self.encoder.key,
        codingPath: self.encoder.codingPath,
        buffer: buffer,
        context: self.encoder.context
      )
    }
  }

  private struct SingleValueContainer: SingleValueEncodingContainer {
    let encoder: KeyEncoder

    var codingPath: [any CodingKey] { self.encoder.codingPath }

    mutating func encodeNil() throws { self.encoder.encodeNil() }
    mutating func encode(_ value: Bool) throws { try self.encoder.encode(value) }
    mutating func encode(_ value: String) throws { try self.encoder.encode(value) }
    mutating func encode(_ value: Double) throws { try self.encoder.encode(value) }
    mutating func encode(_ value: Float) throws { try self.encoder.encode(value) }
    mutating func encode(_ value: Int) throws { try self.encoder.encode(value) }
    mutating func encode(_ value: Int8) throws { try self.encoder.encode(value) }
    mutating func encode(_ value: Int16) throws { try self.encoder.encode(value) }
    mutating func encode(_ value: Int32) throws { try self.encoder.encode(value) }
    mutating func encode(_ value: Int64) throws { try self.encoder.encode(value) }
    mutating func encode(_ value: UInt) throws { try self.encoder.encode(value) }
    mutating func encode(_ value: UInt8) throws { try self.encoder.encode(value) }
    mutating func encode(_ value: UInt16) throws { try self.encoder.encode(value) }
    mutating func encode(_ value: UInt32) throws { try self.encoder.encode(value) }
    mutating func encode(_ value: UInt64) throws { try self.encoder.encode(value) }
    mutating func encode<T: Encodable>(_ value: T) throws { try self.encoder.encode(value) }
  }
}
