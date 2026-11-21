#if Foundation
  import _SwiftMMKVFoundation

  // MARK: - Date

  /// Stored as an ISO 8601 string with milliseconds, such as `"2026-11-21T08:30:00.000Z"`.
  ///
  /// It is the form JavaScript's `toISOString()` writes and `new Date(string)` reads. The string
  /// keeps milliseconds, so a date read back can differ from the one stored by under a
  /// millisecond.
  ///
  /// A date stored as a number is read with ``Foundation/Date/MMKVMillisecondsSince1970``,
  /// ``Foundation/Date/MMKVSecondsSince1970`` or
  /// ``Foundation/Date/MMKVSecondsSinceReferenceDate``, which name the number's unit.
  extension Date: MMKVValue {
    /// Reads a date from its ISO 8601 string, with or without fractional seconds. The result is
    /// `nil` if the value is not such a string, which includes a date stored as a number.
    public init?(from reader: borrowing MMKVValueReader) {
      guard let date = reader.date() else { return nil }
      self = date
    }

    public func write(to writer: inout MMKVValueWriter) -> Bool {
      writer.set(self)
    }

    /// Parses a whole string as an ISO 8601 date and time with a time zone.
    ///
    /// Foundation's parser accepts a string that only starts with a date, which would read a
    /// value of another type as a date.
    fileprivate init?(mmkvISO8601 string: String) {
      var last: UInt8?
      for byte in string.utf8 {
        guard last != UInt8(ascii: "Z") else { return nil }
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: ":"),
          UInt8(ascii: "."), UInt8(ascii: "+"), UInt8(ascii: "T"), UInt8(ascii: "Z"):
          last = byte
        default:
          return nil
        }
      }
      guard let last, last == UInt8(ascii: "Z") || (UInt8(ascii: "0")...UInt8(ascii: "9") ~= last),
        let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
      else { return nil }
      self = date
    }

    fileprivate var mmkvISO8601: String {
      Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(self)
    }

    /// Reads a number, unless the value is an ISO 8601 string, which is read as one.
    fileprivate init?(
      from reader: borrowing MMKVValueReader,
      number: (Double) -> Date
    ) {
      if let date = reader.date() {
        self = date
        return
      }
      guard let double = reader.double(), double.isFinite else { return nil }
      self = number(double)
    }
  }

  extension MMKVValueReader {
    /// Reads the key as a date from its ISO 8601 string, with or without fractional seconds.
    /// The result is `nil` if the value is not such a string.
    public func date() -> Date? {
      self.string().flatMap { Date(mmkvISO8601: $0) }
    }
  }

  extension MMKVValueWriter {
    /// Stores a date as an ISO 8601 string with milliseconds, such as
    /// `"2026-11-21T08:30:00.000Z"`.
    public mutating func set(_ value: Date) -> Bool {
      self.set(value.mmkvISO8601)
    }
  }

  // MARK: - Dates As Numbers

  extension Date {
    /// A date stored as a `Double` of milliseconds since 1970, which is what JavaScript's
    /// `Date.now()` gives and `new Date(number)` takes.
    ///
    /// ```swift
    /// store.set(Date.MMKVMillisecondsSince1970(Date()), forKey: "lastSync")
    /// let lastSync = store.value(forKey: "lastSync", as: Date.MMKVMillisecondsSince1970.self)?.date
    /// ```
    ///
    /// It also reads a date stored as an ISO 8601 string. In a coder it encodes as the number
    /// alone.
    public struct MMKVMillisecondsSince1970: Hashable, Sendable {
      public var date: Date

      public init(_ date: Date) {
        self.date = date
      }
    }

    /// A date stored as a `Double` of seconds since 1970, which is what upstream MMKV's
    /// Objective-C `setDate:` stores.
    ///
    /// It also reads a date stored as an ISO 8601 string. In a coder it encodes as the number
    /// alone.
    public struct MMKVSecondsSince1970: Hashable, Sendable {
      public var date: Date

      public init(_ date: Date) {
        self.date = date
      }
    }

    /// A date stored as a `Double` of seconds since the start of 2001, which is what a `Date`
    /// encodes itself as by default.
    ///
    /// It also reads a date stored as an ISO 8601 string. In a coder it encodes as the number
    /// alone.
    public struct MMKVSecondsSinceReferenceDate: Hashable, Sendable {
      public var date: Date

      public init(_ date: Date) {
        self.date = date
      }
    }
  }

  extension Date.MMKVMillisecondsSince1970: MMKVValue {
    public init?(from reader: borrowing MMKVValueReader) {
      guard
        let date = Date(from: reader, number: { Date(timeIntervalSince1970: $0 / 1000) })
      else { return nil }
      self.date = date
    }

    public func write(to writer: inout MMKVValueWriter) -> Bool {
      writer.set(self.date.timeIntervalSince1970 * 1000)
    }
  }

  extension Date.MMKVMillisecondsSince1970: Codable {
    public init(from decoder: any Decoder) throws {
      let milliseconds = try decoder.singleValueContainer().decode(Double.self)
      self.date = Date(timeIntervalSince1970: milliseconds / 1000)
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(self.date.timeIntervalSince1970 * 1000)
    }
  }

  extension Date.MMKVSecondsSince1970: MMKVValue {
    public init?(from reader: borrowing MMKVValueReader) {
      guard let date = Date(from: reader, number: { Date(timeIntervalSince1970: $0) })
      else { return nil }
      self.date = date
    }

    public func write(to writer: inout MMKVValueWriter) -> Bool {
      writer.set(self.date.timeIntervalSince1970)
    }
  }

  extension Date.MMKVSecondsSince1970: Codable {
    public init(from decoder: any Decoder) throws {
      let seconds = try decoder.singleValueContainer().decode(Double.self)
      self.date = Date(timeIntervalSince1970: seconds)
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(self.date.timeIntervalSince1970)
    }
  }

  extension Date.MMKVSecondsSinceReferenceDate: MMKVValue {
    public init?(from reader: borrowing MMKVValueReader) {
      guard
        let date = Date(from: reader, number: { Date(timeIntervalSinceReferenceDate: $0) })
      else { return nil }
      self.date = date
    }

    public func write(to writer: inout MMKVValueWriter) -> Bool {
      writer.set(self.date.timeIntervalSinceReferenceDate)
    }
  }

  extension Date.MMKVSecondsSinceReferenceDate: Codable {
    public init(from decoder: any Decoder) throws {
      let seconds = try decoder.singleValueContainer().decode(Double.self)
      self.date = Date(timeIntervalSinceReferenceDate: seconds)
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(self.date.timeIntervalSinceReferenceDate)
    }
  }
#endif
