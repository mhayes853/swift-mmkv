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
/// store[.launches] += 1
/// ```
///
/// It is itself a `BinaryInteger`, so it does arithmetic, compares, and converts to and from
/// other integers as the integer it holds does.
///
/// An integer that a `Double` cannot hold exactly, which starts beyond 2 to the power of 53, is
/// not stored. A stored number that is not a whole number, or that does not fit the integer
/// type, reads as `nil`. In a coder it encodes as the integer alone.
///
/// A type with an integer raw value stores itself the same way by setting
/// ``MMKVValue/integerEncoding``.
public struct MMKVNumber<Integer: BinaryInteger>: Hashable {
  public var value: Integer

  @inlinable
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

// MARK: - BinaryInteger

extension MMKVNumber: ExpressibleByIntegerLiteral {
  @inlinable
  public init(integerLiteral value: Integer.IntegerLiteralType) {
    self.init(Integer(integerLiteral: value))
  }
}

extension MMKVNumber: Comparable {
  @inlinable
  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.value < rhs.value
  }
}

extension MMKVNumber: AdditiveArithmetic {
  @inlinable
  public static func + (lhs: Self, rhs: Self) -> Self {
    Self(lhs.value + rhs.value)
  }

  @inlinable
  public static func += (lhs: inout Self, rhs: Self) {
    lhs.value += rhs.value
  }

  @inlinable
  public static func - (lhs: Self, rhs: Self) -> Self {
    Self(lhs.value - rhs.value)
  }

  @inlinable
  public static func -= (lhs: inout Self, rhs: Self) {
    lhs.value -= rhs.value
  }
}

extension MMKVNumber: Numeric {
  public typealias Magnitude = MMKVNumber<Integer.Magnitude>

  @inlinable
  public init?<T: BinaryInteger>(exactly source: T) {
    guard let value = Integer(exactly: source) else { return nil }
    self.init(value)
  }

  @inlinable
  public var magnitude: Magnitude {
    Magnitude(self.value.magnitude)
  }

  @inlinable
  public static func * (lhs: Self, rhs: Self) -> Self {
    Self(lhs.value * rhs.value)
  }

  @inlinable
  public static func *= (lhs: inout Self, rhs: Self) {
    lhs.value *= rhs.value
  }
}

/// Arithmetic is that of the integer it holds, so it traps on overflow where that integer does.
extension MMKVNumber: BinaryInteger {
  public typealias Words = Integer.Words

  @inlinable
  public static var isSigned: Bool { Integer.isSigned }

  @inlinable
  public init?<T: BinaryFloatingPoint>(exactly source: T) {
    guard let value = Integer(exactly: source) else { return nil }
    self.init(value)
  }

  @inlinable
  public init<T: BinaryFloatingPoint>(_ source: T) {
    self.init(Integer(source))
  }

  @inlinable
  public init<T: BinaryInteger>(_ source: T) {
    self.init(Integer(source))
  }

  @inlinable
  public init<T: BinaryInteger>(truncatingIfNeeded source: T) {
    self.init(Integer(truncatingIfNeeded: source))
  }

  @inlinable
  public init<T: BinaryInteger>(clamping source: T) {
    self.init(Integer(clamping: source))
  }

  @inlinable
  public var words: Words { self.value.words }

  @inlinable
  public var bitWidth: Int { self.value.bitWidth }

  @inlinable
  public var trailingZeroBitCount: Int { self.value.trailingZeroBitCount }

  @inlinable
  public static func / (lhs: Self, rhs: Self) -> Self {
    Self(lhs.value / rhs.value)
  }

  @inlinable
  public static func /= (lhs: inout Self, rhs: Self) {
    lhs.value /= rhs.value
  }

  @inlinable
  public static func % (lhs: Self, rhs: Self) -> Self {
    Self(lhs.value % rhs.value)
  }

  @inlinable
  public static func %= (lhs: inout Self, rhs: Self) {
    lhs.value %= rhs.value
  }

  @inlinable
  public static func &= (lhs: inout Self, rhs: Self) {
    lhs.value &= rhs.value
  }

  @inlinable
  public static func |= (lhs: inout Self, rhs: Self) {
    lhs.value |= rhs.value
  }

  @inlinable
  public static func ^= (lhs: inout Self, rhs: Self) {
    lhs.value ^= rhs.value
  }

  @inlinable
  public static prefix func ~ (number: Self) -> Self {
    Self(~number.value)
  }

  @inlinable
  public static func <<= <RHS: BinaryInteger>(lhs: inout Self, rhs: RHS) {
    lhs.value <<= rhs
  }

  @inlinable
  public static func >>= <RHS: BinaryInteger>(lhs: inout Self, rhs: RHS) {
    lhs.value >>= rhs
  }
}

extension MMKVNumber: SignedNumeric, SignedInteger where Integer: SignedInteger {}

extension MMKVNumber: UnsignedInteger where Integer: UnsignedInteger {}

// MARK: - Codable

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
