#if Foundation
  import _SwiftMMKVFoundation

  // MARK: - URL

  /// Stored as the URL's absolute string, which JavaScript reads with `getString`.
  extension URL: MMKVValue {
    /// Reads a URL from its string. The result is `nil` if the string is not a valid URL.
    public init?(from reader: borrowing MMKVValueReader) {
      guard let url = reader.url() else { return nil }
      self = url
    }

    public func write(to writer: inout MMKVValueWriter) -> Bool {
      writer.set(self)
    }
  }

  extension MMKVValueReader {
    /// Reads the key as a URL from its string. The result is `nil` if the string is not a valid
    /// URL.
    public func url() -> URL? {
      self.string().flatMap { URL(string: $0) }
    }
  }

  extension MMKVValueWriter {
    /// Stores a URL as its absolute string.
    public mutating func set(_ value: URL) -> Bool {
      self.set(value.absoluteString)
    }
  }

  // MARK: - UUID

  /// Stored as the UUID's string, in uppercase, which JavaScript reads with `getString`.
  extension UUID: MMKVValue {
    /// Reads a UUID from its string, in uppercase or lowercase. The result is `nil` if the
    /// string is not a UUID.
    public init?(from reader: borrowing MMKVValueReader) {
      guard let uuid = reader.uuid() else { return nil }
      self = uuid
    }

    public func write(to writer: inout MMKVValueWriter) -> Bool {
      writer.set(self)
    }
  }

  extension MMKVValueReader {
    /// Reads the key as a UUID from its string, in uppercase or lowercase. The result is `nil`
    /// if the string is not a UUID.
    public func uuid() -> UUID? {
      self.string().flatMap { UUID(uuidString: $0) }
    }
  }

  extension MMKVValueWriter {
    /// Stores a UUID as its string, in uppercase.
    public mutating func set(_ value: UUID) -> Bool {
      self.set(value.uuidString)
    }
  }

  // MARK: - Decimal

  /// Stored as a string such as `"12.50"`, which keeps every digit. JavaScript has no decimal
  /// type, and reads it with `getString`.
  extension Decimal: MMKVValue {
    /// Reads a decimal from its string, or from a `Double`, which is how JavaScript stores a
    /// number.
    ///
    /// A decimal read from a `Double` has the digits that the `Double` prints with, so `0.1`
    /// reads as exactly `0.1`.
    public init?(from reader: borrowing MMKVValueReader) {
      guard let decimal = reader.decimal() else { return nil }
      self = decimal
    }

    /// Stores the decimal's string. A decimal that is not a number is not stored.
    public func write(to writer: inout MMKVValueWriter) -> Bool {
      writer.set(self)
    }

    /// Parses a whole string as a decimal number, such as `-12.50` or `1e-7`.
    ///
    /// `Decimal(string:)` accepts a string that only starts with a number, which would read
    /// a value of another type as a decimal.
    fileprivate init?(mmkvLiteral string: String) {
      var digits = 0
      var hasPoint = false
      var hasExponent = false
      var previous: UInt8?
      for byte in string.utf8 {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
          digits += 1
        case UInt8(ascii: "+"), UInt8(ascii: "-"):
          guard previous == nil || previous == UInt8(ascii: "e") else { return nil }
        case UInt8(ascii: "."):
          guard !hasPoint, !hasExponent else { return nil }
          hasPoint = true
        case UInt8(ascii: "e"), UInt8(ascii: "E"):
          guard !hasExponent, digits > 0 else { return nil }
          hasExponent = true
          digits = 0
          previous = UInt8(ascii: "e")
          continue
        default:
          return nil
        }
        previous = byte
      }
      guard digits > 0, let decimal = Decimal(string: string, locale: nil), !decimal.isNaN
      else { return nil }
      self = decimal
    }
  }

  extension MMKVValueReader {
    /// Reads the key as a decimal from its string, or from a `Double`, which is how JavaScript
    /// stores a number.
    ///
    /// A decimal read from a `Double` has the digits that the `Double` prints with, so `0.1`
    /// reads as exactly `0.1`.
    public func decimal() -> Decimal? {
      if let string = self.string(), let decimal = Decimal(mmkvLiteral: string) {
        return decimal
      }
      guard let double = self.double(), double.isFinite else { return nil }
      return Decimal(mmkvLiteral: "\(double)")
    }
  }

  extension MMKVValueWriter {
    /// Stores a decimal as its string, such as `"12.5"`. A decimal that is not a number is not
    /// stored.
    public mutating func set(_ value: Decimal) -> Bool {
      guard !value.isNaN else { return false }
      return self.set(value.description)
    }
  }
#endif
