#if UUIDV7
  import UUIDV7

  /// Stored as the UUID's string, in uppercase, which JavaScript reads with `getString`. It is
  /// the form a Foundation `UUID` is stored in, so either type reads what the other wrote.
  extension UUIDV7: MMKVValue {
    /// Reads a UUID from its string, in uppercase or lowercase. The result is `nil` if the
    /// string is not a version 7 UUID.
    public init?(from reader: borrowing MMKVValueReader) {
      guard let string = reader.string(), let uuid = UUIDV7(uuidString: string) else { return nil }
      self = uuid
    }

    public func write(to writer: inout MMKVValueWriter) -> Bool {
      writer.set(self.uuidString)
    }
  }
#endif
