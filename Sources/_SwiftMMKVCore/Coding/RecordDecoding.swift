// Decoding the records of a data file into an index, from MiniPBCoder::decodeOneMap and
// CodedInputData's readString(KeyValueHolder&) and readData(KeyValueHolder&).

/// The longest key MMKV accepts, in bytes.
package let keySizeLimit = Int(UInt16.max) - 4

/// The bytes of a key. Keys are compared as bytes, because MMKV does not require them to be
/// valid UTF-8.
package struct StoreKey: Hashable, Sendable {
  package var bytes: [UInt8]

  package init(_ bytes: [UInt8]) {
    self.bytes = bytes
  }

  package init(_ string: String) {
    self.bytes = Array(string.utf8)
  }

  package var string: String {
    String(decoding: self.bytes, as: UTF8.self)
  }
}

/// Where a key's record is in the data, as MMKV's `KeyValueHolder` records it.
///
/// `offset` is measured from the start of the data, which follows the file's four-byte header.
package struct RecordLocation: Equatable, Sendable {
  /// The size of the key's length, the key, and the value's length.
  package var computedKVSize: UInt16
  package var keySize: UInt16
  package var valueSize: UInt32
  package var offset: UInt32

  package init(computedKVSize: UInt16, keySize: UInt16, valueSize: UInt32, offset: UInt32) {
    self.computedKVSize = computedKVSize
    self.keySize = keySize
    self.valueSize = valueSize
    self.offset = offset
  }

  /// A record just written at `offset`, with a key of `keySize` bytes and a value of `valueSize`.
  package init(keySize: Int, valueSize: Int, offset: Int) {
    self.keySize = UInt16(truncatingIfNeeded: keySize)
    self.valueSize = UInt32(truncatingIfNeeded: valueSize)
    self.offset = UInt32(truncatingIfNeeded: offset)
    var computed =
      self.keySize &+ UInt16(truncatingIfNeeded: pbRawVarint32Size(UInt32(self.keySize)))
    computed &+= UInt16(truncatingIfNeeded: pbRawVarint32Size(self.valueSize))
    self.computedKVSize = computed
  }

  /// The size of the whole record.
  package var size: Int {
    Int(self.computedKVSize) + Int(self.valueSize)
  }

  /// Where the value's bytes start.
  package var valueOffset: Int {
    Int(self.offset) + Int(self.computedKVSize)
  }
}

package enum RecordDecoding {
  /// Decodes the records in `data` into `index`, applying each in order: a record with an empty
  /// value removes its key.
  ///
  /// Decoding starts at `position`, or, when it is zero, after the varint at the start of the data
  /// (the size placeholder MMKV writes there). An empty key is skipped without reading a value.
  ///
  /// - Parameter greedy: Whether to keep what was decoded before an error, as
  ///   `greedyDecodeMap` does. Otherwise `index` is only changed if everything decodes, as with
  ///   `decodeMap`.
  /// - Returns: Whether everything decoded.
  @discardableResult
  package static func decode(
    _ data: UnsafeRawBufferPointer,
    from position: Int = 0,
    into index: inout [StoreKey: RecordLocation],
    greedy: Bool
  ) -> Bool {
    if greedy {
      return Self.decodeRecords(data, from: position, into: &index)
    }
    var decoded = [StoreKey: RecordLocation]()
    guard Self.decodeRecords(data, from: position, into: &decoded) else { return false }
    index = decoded
    return true
  }

  private static func decodeRecords(
    _ data: UnsafeRawBufferPointer,
    from position: Int,
    into index: inout [StoreKey: RecordLocation]
  ) -> Bool {
    var input = CodedInput(data)
    do throws(CodingError) {
      if position != 0 {
        try input.seek(position)
      } else {
        _ = try input.readInt32()
      }
      while !input.isAtEnd {
        let offset = input.position
        let keyRange = try input.readLengthDelimited()
        guard keyRange.count <= keySizeLimit else { throw .entryTooLarge }
        guard !keyRange.isEmpty else { continue }
        let valueRange = try input.readLengthDelimited()
        let computedKVSize = valueRange.lowerBound - offset
        guard computedKVSize <= Int(UInt16.max) else { throw .entryTooLarge }
        let key = StoreKey(Array(input.bytes(in: keyRange)))
        if valueRange.isEmpty {
          index.removeValue(forKey: key)
        } else {
          index[key] = RecordLocation(
            computedKVSize: UInt16(computedKVSize),
            keySize: UInt16(keyRange.count),
            valueSize: UInt32(valueRange.count),
            offset: UInt32(offset)
          )
        }
      }
      return true
    } catch {
      return false
    }
  }
}
