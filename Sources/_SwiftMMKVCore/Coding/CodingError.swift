/// A failure to encode or decode MMKV's protobuf-like format. MMKV's C++ core throws an exception
/// in each of these cases and treats it as the value, or the rest of the file, being unreadable.
package enum CodingError: Error, Equatable {
  /// A write did not fit in the space left.
  case outOfSpace

  /// A read ran past the end of the input.
  case truncated

  /// A varint ran on for longer than its type allows.
  case malformedVarint

  /// A length-delimited field claimed more bytes than remain, or exactly the remaining bytes were
  /// required and it claimed a different number.
  case invalidLength

  /// A key is longer than ``keySizeLimit``, or a key and its value's length prefix take more than
  /// 65,535 bytes, which the index cannot represent.
  case entryTooLarge
}
