// Decoding the records of a data file into an index, from MiniPBCoder::decodeOneMap and
// CodedInputData's readString(KeyValueHolder&) and readData(KeyValueHolder&).

/// The longest key MMKV accepts, in bytes.
package let keySizeLimit = Int(UInt16.max) - 4

/// The bytes of a key. Keys are compared as bytes, because MMKV does not require them to be
/// valid UTF-8.
package struct StoreKey: Hashable, Sendable {
  package var bytes: [UInt8]

  package init(_ string: String) {
    self.bytes = Array(string.utf8)
  }

  package init(_ bytes: UnsafeRawBufferPointer) {
    self.bytes = Array(bytes)
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
    into index: inout RecordIndex,
    greedy: Bool
  ) -> Bool {
    if greedy {
      return Self.decodeAllRecords(data, from: position, into: &index)
    }
    var decoded = RecordIndex()
    guard Self.decodeAllRecords(data, from: position, into: &decoded) else { return false }
    index = decoded
    return true
  }

  /// Decodes the records, sizing the index for them first when it starts out empty, so that it
  /// does not grow, and leave behind the memory of every smaller table, while decoding.
  private static func decodeAllRecords(
    _ data: UnsafeRawBufferPointer,
    from position: Int,
    into index: inout RecordIndex
  ) -> Bool {
    guard index.isEmpty else {
      return Self.decodeRecords(data, from: position, into: &index)
    }
    index.reserveCapacity(Self.countValues(data, from: position))
    let decoded = Self.decodeRecords(data, from: position, into: &index)
    // Overwrites and removals leave fewer keys than records.
    index.shrinkToFit()
    return decoded
  }

  /// An input at the first record: at `position`, or after the size placeholder when it is zero.
  private static func input(
    _ data: UnsafeRawBufferPointer,
    from position: Int
  ) throws(CodingError) -> CodedInput {
    var input = CodedInput(data)
    if position != 0 {
      try input.seek(position)
    } else {
      _ = try input.readInt32()
    }
    return input
  }

  /// How many records hold a value, up to the first that cannot be read.
  private static func countValues(_ data: UnsafeRawBufferPointer, from position: Int) -> Int {
    var count = 0
    do throws(CodingError) {
      var input = try Self.input(data, from: position)
      while !input.isAtEnd {
        guard !(try input.readLengthDelimited()).isEmpty else { continue }
        if !(try input.readLengthDelimited()).isEmpty {
          count += 1
        }
      }
    } catch {}
    return count
  }

  private static func decodeRecords(
    _ data: UnsafeRawBufferPointer,
    from position: Int,
    into index: inout RecordIndex
  ) -> Bool {
    do throws(CodingError) {
      var input = try Self.input(data, from: position)
      while !input.isAtEnd {
        let offset = input.position
        let keyRange = try input.readLengthDelimited()
        guard keyRange.count <= keySizeLimit else { throw .entryTooLarge }
        guard !keyRange.isEmpty else { continue }
        let valueRange = try input.readLengthDelimited()
        let computedKVSize = valueRange.lowerBound - offset
        guard computedKVSize <= Int(UInt16.max) else { throw .entryTooLarge }
        let key = input.bytes(in: keyRange)
        if valueRange.isEmpty {
          index.remove(key, base: data.baseAddress)
        } else {
          let location = RecordLocation(
            computedKVSize: UInt16(computedKVSize),
            keySize: UInt16(keyRange.count),
            valueSize: UInt32(valueRange.count),
            offset: UInt32(offset)
          )
          index.set(location, for: key, base: data.baseAddress)
        }
      }
      return true
    } catch {
      return false
    }
  }
}
