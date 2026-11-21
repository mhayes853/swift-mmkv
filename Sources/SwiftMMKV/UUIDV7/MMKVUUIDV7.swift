#if UUIDV7
  import UUIDV7

  /// Stored as the UUID's string, in uppercase, which JavaScript reads with `getString`. It is
  /// the form a Foundation `UUID` is stored in, so either type reads what the other wrote.
  extension UUIDV7: MMKVValue {
    /// Reads a UUID from its string, in uppercase or lowercase. The result is `nil` if the
    /// string is not a version 7 UUID.
    public init?(from reader: borrowing MMKVValueReader) {
      guard let uuid = reader.uuidV7() else { return nil }
      self = uuid
    }

    public func write(to writer: inout MMKVValueWriter) -> Bool {
      writer.set(self)
    }
  }

  extension MMKVValueReader {
    /// Reads the key as a version 7 UUID from its string, in uppercase or lowercase. The result
    /// is `nil` if the string is not a version 7 UUID.
    @inlinable
    public func uuidV7() -> UUIDV7? {
      self.string().flatMap { UUIDV7(uuidString: $0) }
    }
  }

  extension MMKVValueWriter {
    /// Stores a version 7 UUID as its string, in uppercase.
    @inlinable
    public mutating func set(_ value: UUIDV7) -> Bool {
      self.set(value.uuidString)
    }
  }
#endif
