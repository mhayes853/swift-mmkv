#if Tagged
  import Tagged

  /// Stored as its raw value, in whichever encoding the raw value's type has. A value reads
  /// back as the raw value's type, and the other way around.
  ///
  /// The raw value's type alone decides the encoding, and ``MMKVValue/integerEncoding`` is not
  /// read. An integer that shares its key with JavaScript therefore has ``MMKVNumber`` as its
  /// raw value:
  ///
  /// ```swift
  /// struct User {
  ///   typealias ID = Tagged<User, Int>                   // A 64-bit integer.
  ///   typealias SharedID = Tagged<User, Int.MMKVNumber>  // A `Double`, which JavaScript reads.
  /// }
  /// ```
  extension Tagged: MMKVValue where RawValue: MMKVValue {
    @inlinable
    public init?(from reader: borrowing MMKVValueReader) {
      guard let rawValue = RawValue(from: reader) else { return nil }
      self.init(rawValue: rawValue)
    }

    @inlinable
    public func write(to writer: inout MMKVValueWriter) -> Bool {
      self.rawValue.write(to: &writer)
    }
  }
#endif
