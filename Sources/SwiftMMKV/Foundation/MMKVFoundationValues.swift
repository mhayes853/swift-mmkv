#if Foundation
  import _SwiftMMKVFoundation

  // MARK: - URL

  /// Stored as the URL's absolute string, which JavaScript reads with `getString`.
  extension URL: MMKVValue {
    /// Reads a URL from its string. The result is `nil` if the string is not a valid URL.
    public init?(from reader: borrowing MMKVValueReader) {
      guard let string = reader.string(), let url = URL(string: string) else { return nil }
      self = url
    }

    public func write(to writer: inout MMKVValueWriter) -> Bool {
      writer.set(self.absoluteString)
    }
  }

  // MARK: - UUID

  /// Stored as the UUID's string, in uppercase, which JavaScript reads with `getString`.
  extension UUID: MMKVValue {
    /// Reads a UUID from its string, in uppercase or lowercase. The result is `nil` if the
    /// string is not a UUID.
    public init?(from reader: borrowing MMKVValueReader) {
      guard let string = reader.string(), let uuid = UUID(uuidString: string) else { return nil }
      self = uuid
    }

    public func write(to writer: inout MMKVValueWriter) -> Bool {
      writer.set(self.uuidString)
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
      if let string = reader.string(), let decimal = Decimal(mmkvLiteral: string) {
        self = decimal
        return
      }
      guard let double = reader.double(), double.isFinite,
        let decimal = Decimal(mmkvLiteral: "\(double)")
      else { return nil }
      self = decimal
    }

    /// Stores the decimal's string. A decimal that is not a number is not stored.
    public func write(to writer: inout MMKVValueWriter) -> Bool {
      guard !self.isNaN else { return false }
      return writer.set(self.description)
    }

    /// Parses a whole string as a decimal number, such as `-12.50` or `1e-7`.
    ///
    /// `Decimal(string:)` accepts a string that only starts with a number, which would read
    /// a value of another type as a decimal.
    private init?(mmkvLiteral string: String) {
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
#endif
