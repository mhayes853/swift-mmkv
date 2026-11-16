/// A type that can be stored in an ``MMKVStore``.
///
/// MMKV files carry no type information, so a value is read by naming its type, and reading a key
/// as a different type than it was written with yields garbage rather than `nil`. A conforming
/// type picks one of the encodings MMKV understands by calling the matching method of the reader
/// and writer.
///
/// ```swift
/// struct UserID: MMKVValue {
///   var rawValue: Int64
///
///   init?(from reader: borrowing MMKVValueReader) {
///     guard let rawValue = reader.int64() else { return nil }
///     self.rawValue = rawValue
///   }
///
///   func write(to writer: inout MMKVValueWriter) -> Bool {
///     writer.set(self.rawValue)
///   }
/// }
/// ```
///
/// A type that is `RawRepresentable` by another `MMKVValue` conforms without any code:
///
/// ```swift
/// enum Theme: String, MMKVValue {
///   case light, dark
/// }
/// ```
///
/// `Int` and `UInt` deliberately do not conform. An integer literal would otherwise be stored as
/// a 64-bit integer, which JavaScript, where every number is a `Double`, cannot read back.
public protocol MMKVValue {
  /// Reads a value from the key the reader is bound to.
  ///
  /// - Returns: `nil` if the key has no value, or if its value is not a valid `Self`.
  init?(from reader: borrowing MMKVValueReader)

  /// Writes the value to the key the writer is bound to.
  ///
  /// - Returns: Whether the value was stored.
  func write(to writer: inout MMKVValueWriter) -> Bool
}

extension MMKVValue where Self: RawRepresentable, RawValue: MMKVValue {
  public init?(from reader: borrowing MMKVValueReader) {
    guard let rawValue = RawValue(from: reader) else { return nil }
    self.init(rawValue: rawValue)
  }

  public func write(to writer: inout MMKVValueWriter) -> Bool {
    self.rawValue.write(to: &writer)
  }
}

extension Bool: MMKVValue {
  public init?(from reader: borrowing MMKVValueReader) {
    guard let value = reader.bool() else { return nil }
    self = value
  }

  public func write(to writer: inout MMKVValueWriter) -> Bool {
    writer.set(self)
  }
}

extension Int32: MMKVValue {
  public init?(from reader: borrowing MMKVValueReader) {
    guard let value = reader.int32() else { return nil }
    self = value
  }

  public func write(to writer: inout MMKVValueWriter) -> Bool {
    writer.set(self)
  }
}

extension UInt32: MMKVValue {
  public init?(from reader: borrowing MMKVValueReader) {
    guard let value = reader.uint32() else { return nil }
    self = value
  }

  public func write(to writer: inout MMKVValueWriter) -> Bool {
    writer.set(self)
  }
}

extension Int64: MMKVValue {
  public init?(from reader: borrowing MMKVValueReader) {
    guard let value = reader.int64() else { return nil }
    self = value
  }

  public func write(to writer: inout MMKVValueWriter) -> Bool {
    writer.set(self)
  }
}

extension UInt64: MMKVValue {
  public init?(from reader: borrowing MMKVValueReader) {
    guard let value = reader.uint64() else { return nil }
    self = value
  }

  public func write(to writer: inout MMKVValueWriter) -> Bool {
    writer.set(self)
  }
}

extension Float: MMKVValue {
  public init?(from reader: borrowing MMKVValueReader) {
    guard let value = reader.float() else { return nil }
    self = value
  }

  public func write(to writer: inout MMKVValueWriter) -> Bool {
    writer.set(self)
  }
}

extension Double: MMKVValue {
  public init?(from reader: borrowing MMKVValueReader) {
    guard let value = reader.double() else { return nil }
    self = value
  }

  public func write(to writer: inout MMKVValueWriter) -> Bool {
    writer.set(self)
  }
}

extension String: MMKVValue {
  public init?(from reader: borrowing MMKVValueReader) {
    guard let value = reader.string() else { return nil }
    self = value
  }

  public func write(to writer: inout MMKVValueWriter) -> Bool {
    writer.set(self)
  }
}

/// An element type whose arrays MMKV can store: `UInt8` for raw bytes, and `String` for a list
/// of strings.
///
/// `Array` can only conform to ``MMKVValue`` once, so the two array encodings are reached
/// through this protocol. It is not meant to be conformed to outside this package.
public protocol _MMKVArrayElement {
  static func _readArray(from reader: borrowing MMKVValueReader) -> [Self]?
  static func _writeArray(_ array: [Self], to writer: inout MMKVValueWriter) -> Bool
}

extension UInt8: _MMKVArrayElement {
  public static func _readArray(from reader: borrowing MMKVValueReader) -> [UInt8]? {
    reader.withBytes { span in
      span.withUnsafeBytes { Array($0) }
    }
  }

  public static func _writeArray(_ array: [UInt8], to writer: inout MMKVValueWriter) -> Bool {
    // `Array.span` needs a newer OS than this package supports, so the bytes are borrowed the
    // older way.
    array.withUnsafeBytes { writer.set(buffer: $0) }
  }
}

extension String: _MMKVArrayElement {
  public static func _readArray(from reader: borrowing MMKVValueReader) -> [String]? {
    reader.strings()
  }

  public static func _writeArray(_ array: [String], to writer: inout MMKVValueWriter) -> Bool {
    writer.set(array)
  }
}

extension Array: MMKVValue where Element: _MMKVArrayElement {
  public init?(from reader: borrowing MMKVValueReader) {
    guard let value = Element._readArray(from: reader) else { return nil }
    self = value
  }

  public func write(to writer: inout MMKVValueWriter) -> Bool {
    Element._writeArray(self, to: &writer)
  }
}
