/// An integer stored as a `Double`, which is how JavaScript stores every number.
///
/// An integer is otherwise stored in its own encoding, which JavaScript cannot read. This type
/// is for a key that both sides use, and is spelled through the integer it holds:
///
/// ```swift
/// extension MMKVStore.DefaultedKey where Value == Int.MMKVNumber {
///   static let launches = Self("launches", default: 0)
/// }
///
/// store[.launches] = Int.MMKVNumber(store[.launches].value + 1)
/// ```
///
/// An integer that a `Double` cannot hold exactly, which starts beyond 2 to the power of 53, is
/// not stored. A stored number that is not a whole number, or that does not fit the integer
/// type, reads as `nil`. In a coder it encodes as the integer alone.
///
/// A type with an integer raw value stores itself the same way by setting
/// ``MMKVValue/integerEncoding``.
public struct MMKVNumber<Integer: BinaryInteger>: Hashable {
  public var value: Integer

  public init(_ value: Integer) {
    self.value = value
  }
}

extension BinaryInteger {
  /// This integer type stored as a `Double`, which is how JavaScript stores every number.
  public typealias MMKVNumber = SwiftMMKV.MMKVNumber<Self>
}

extension MMKVNumber: Sendable where Integer: Sendable {}

extension MMKVNumber: MMKVValue {
  @inlinable
  public init?(from reader: borrowing MMKVValueReader) {
    guard let value = reader.number(as: Integer.self) else { return nil }
    self.init(value)
  }

  @inlinable
  public func write(to writer: inout MMKVValueWriter) -> Bool {
    writer.set(number: self.value)
  }
}

extension MMKVNumber: ExpressibleByIntegerLiteral {
  @inlinable
  public init(integerLiteral value: Integer.IntegerLiteralType) {
    self.init(Integer(integerLiteral: value))
  }
}

extension MMKVNumber: Decodable where Integer: Decodable {
  public init(from decoder: any Decoder) throws {
    self.init(try decoder.singleValueContainer().decode(Integer.self))
  }
}

extension MMKVNumber: Encodable where Integer: Encodable {
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(self.value)
  }
}
