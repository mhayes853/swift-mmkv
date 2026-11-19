/// Reads MMKV's encoding from a region of memory, as `CodedInputData` does, including its
/// handling of malformed and truncated input.
package struct CodedInput {
  private let base: UnsafeRawPointer
  package let size: Int
  package private(set) var position: Int

  package init(base: UnsafeRawPointer, size: Int, position: Int = 0) {
    self.base = base
    self.size = size
    self.position = position
  }

  package init(_ buffer: UnsafeRawBufferPointer) {
    self.init(base: buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, size: buffer.count)
  }

  package var isAtEnd: Bool {
    self.position == self.size
  }

  package mutating func seek(_ addedSize: Int) throws(CodingError) {
    guard self.position + addedSize <= self.size else { throw .truncated }
    self.position += addedSize
  }

  // MARK: Raw

  package mutating func readRawByte() throws(CodingError) -> Int8 {
    guard self.position != self.size else { throw .truncated }
    let byte = self.base.load(fromByteOffset: self.position, as: Int8.self)
    self.position += 1
    return byte
  }

  /// Reads a varint as a 32-bit value. A ten-byte varint, such as a negative `int32`, keeps its
  /// low 32 bits, and one longer than ten bytes is malformed.
  package mutating func readRawVarint32() throws(CodingError) -> Int32 {
    var tmp = try self.readRawByte()
    if tmp >= 0 {
      return Int32(tmp)
    }
    var result = UInt32(UInt8(bitPattern: tmp) & 0x7f)
    tmp = try self.readRawByte()
    if tmp >= 0 {
      result |= UInt32(UInt8(bitPattern: tmp)) << 7
    } else {
      result |= UInt32(UInt8(bitPattern: tmp) & 0x7f) << 7
      tmp = try self.readRawByte()
      if tmp >= 0 {
        result |= UInt32(UInt8(bitPattern: tmp)) << 14
      } else {
        result |= UInt32(UInt8(bitPattern: tmp) & 0x7f) << 14
        tmp = try self.readRawByte()
        if tmp >= 0 {
          result |= UInt32(UInt8(bitPattern: tmp)) << 21
        } else {
          result |= UInt32(UInt8(bitPattern: tmp) & 0x7f) << 21
          tmp = try self.readRawByte()
          result |= UInt32(UInt8(bitPattern: tmp)) << 28
          if tmp < 0 {
            // Discard the upper 32 bits.
            for _ in 0..<5 {
              if try self.readRawByte() >= 0 {
                return Int32(bitPattern: result)
              }
            }
            throw .malformedVarint
          }
        }
      }
    }
    return Int32(bitPattern: result)
  }

  package mutating func readRawLittleEndian32() throws(CodingError) -> UInt32 {
    guard self.size - self.position >= 4 else {
      // The C++ core reads byte by byte, so a short read consumes what is left before failing.
      self.position = self.size
      throw .truncated
    }
    let value = self.base.loadUnaligned(fromByteOffset: self.position, as: UInt32.self)
    self.position += 4
    return UInt32(littleEndian: value)
  }

  package mutating func readRawLittleEndian64() throws(CodingError) -> UInt64 {
    guard self.size - self.position >= 8 else {
      self.position = self.size
      throw .truncated
    }
    let value = self.base.loadUnaligned(fromByteOffset: self.position, as: UInt64.self)
    self.position += 8
    return UInt64(littleEndian: value)
  }

  // MARK: Fields

  package mutating func readInt64() throws(CodingError) -> Int64 {
    var shift: Int64 = 0
    var result: Int64 = 0
    while shift < 64 {
      let byte = try self.readRawByte()
      result |= Int64(byte & 0x7f) << shift
      if byte & -0x80 == 0 {
        return result
      }
      shift += 7
    }
    throw .malformedVarint
  }

  package mutating func readUInt64() throws(CodingError) -> UInt64 {
    UInt64(bitPattern: try self.readInt64())
  }

  package mutating func readInt32() throws(CodingError) -> Int32 {
    try self.readRawVarint32()
  }

  package mutating func readUInt32() throws(CodingError) -> UInt32 {
    UInt32(bitPattern: try self.readRawVarint32())
  }

  package mutating func readBool() throws(CodingError) -> Bool {
    try self.readRawVarint32() != 0
  }

  package mutating func readFloat() throws(CodingError) -> Float {
    Float(bitPattern: try self.readRawLittleEndian32())
  }

  package mutating func readDouble() throws(CodingError) -> Double {
    Double(bitPattern: try self.readRawLittleEndian64())
  }

  /// Reads a length-delimited field and returns where its bytes are, as `readString` and
  /// `readData` do. With `exactly`, the field must take up the rest of the input.
  package mutating func readLengthDelimited(exactly: Bool = false) throws(CodingError) -> Range<Int>
  {
    let length = Int(try self.readUInt32())
    let remaining = self.size - self.position
    guard exactly ? length == remaining : length <= remaining else { throw .invalidLength }
    let start = self.position
    self.position += length
    return start..<self.position
  }

  /// The bytes in `range`, which must come from this input.
  package func bytes(in range: Range<Int>) -> UnsafeRawBufferPointer {
    UnsafeRawBufferPointer(start: self.base + range.lowerBound, count: range.count)
  }
}
