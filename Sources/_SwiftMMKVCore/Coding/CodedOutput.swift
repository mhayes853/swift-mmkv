/// Writes MMKV's encoding into a fixed region of memory, as `CodedOutputData` does.
///
/// Every write checks that it fits, and throws ``CodingError/outOfSpace`` rather than writing
/// past the end.
package struct CodedOutput {
  private let base: UnsafeMutableRawPointer
  package let size: Int
  package private(set) var position: Int

  /// Writes into `size` bytes at `base`, starting at `position`.
  package init(base: UnsafeMutableRawPointer, size: Int, position: Int = 0) {
    self.base = base
    self.size = size
    self.position = position
  }

  package init(_ buffer: UnsafeMutableRawBufferPointer) {
    self.init(
      base: buffer.baseAddress ?? UnsafeMutableRawPointer(bitPattern: 1)!,
      size: buffer.count
    )
  }

  package var spaceLeft: Int {
    self.size <= self.position ? 0 : self.size - self.position
  }

  package var currentPointer: UnsafeMutableRawPointer {
    self.base + self.position
  }

  private func requireSpace(_ length: Int) throws(CodingError) {
    if self.position > self.size || length > self.size - self.position {
      throw .outOfSpace
    }
  }

  package mutating func seek(_ addedSize: Int) throws(CodingError) {
    try self.requireSpace(addedSize)
    self.position += addedSize
  }

  package mutating func setPosition(_ position: Int) throws(CodingError) {
    guard position <= self.size else { throw .outOfSpace }
    self.position = position
  }

  // MARK: Raw

  package mutating func writeRawByte(_ value: UInt8) throws(CodingError) {
    guard self.position < self.size else { throw .outOfSpace }
    self.base.storeBytes(of: value, toByteOffset: self.position, as: UInt8.self)
    self.position += 1
  }

  package mutating func writeRawData(_ bytes: UnsafeRawBufferPointer) throws(CodingError) {
    try self.requireSpace(bytes.count)
    if let source = bytes.baseAddress, bytes.count > 0 {
      (self.base + self.position).copyMemory(from: source, byteCount: bytes.count)
    }
    self.position += bytes.count
  }

  package mutating func writeRawVarint32(_ bits: UInt32) throws(CodingError) {
    if self.position > self.size || self.size - self.position < 5 {
      try self.requireSpace(pbRawVarint32Size(bits))
    }
    self.writeVarintUnchecked(UInt64(bits))
  }

  package mutating func writeRawVarint64(_ bits: UInt64) throws(CodingError) {
    if self.position > self.size || self.size - self.position < 10 {
      try self.requireSpace(pbUInt64Size(bits))
    }
    self.writeVarintUnchecked(bits)
  }

  private mutating func writeVarintUnchecked(_ value: UInt64) {
    var bits = value
    while bits > 0x7f {
      self.base.storeBytes(
        of: UInt8(truncatingIfNeeded: bits & 0x7f) | 0x80,
        toByteOffset: self.position,
        as: UInt8.self
      )
      self.position += 1
      bits >>= 7
    }
    self.base.storeBytes(of: UInt8(bits), toByteOffset: self.position, as: UInt8.self)
    self.position += 1
  }

  package mutating func writeRawLittleEndian32(_ bits: UInt32) throws(CodingError) {
    try self.requireSpace(4)
    self.base.storeBytes(of: bits.littleEndian, toByteOffset: self.position, as: UInt32.self)
    self.position += 4
  }

  package mutating func writeRawLittleEndian64(_ bits: UInt64) throws(CodingError) {
    try self.requireSpace(8)
    self.base.storeBytes(of: bits.littleEndian, toByteOffset: self.position, as: UInt64.self)
    self.position += 8
  }

  // MARK: Fields

  package mutating func writeBool(_ value: Bool) throws(CodingError) {
    try self.writeRawByte(value ? 1 : 0)
  }

  /// A negative value is sign-extended to a ten-byte varint, as protobuf's `int32` is.
  package mutating func writeInt32(_ value: Int32) throws(CodingError) {
    if value >= 0 {
      try self.writeRawVarint32(UInt32(value))
    } else {
      try self.writeRawVarint64(UInt64(bitPattern: Int64(value)))
    }
  }

  package mutating func writeUInt32(_ value: UInt32) throws(CodingError) {
    try self.writeRawVarint32(value)
  }

  package mutating func writeInt64(_ value: Int64) throws(CodingError) {
    try self.writeRawVarint64(UInt64(bitPattern: value))
  }

  package mutating func writeUInt64(_ value: UInt64) throws(CodingError) {
    try self.writeRawVarint64(value)
  }

  package mutating func writeFloat(_ value: Float) throws(CodingError) {
    try self.writeRawLittleEndian32(value.bitPattern)
  }

  package mutating func writeDouble(_ value: Double) throws(CodingError) {
    try self.writeRawLittleEndian64(value.bitPattern)
  }

  /// Writes `bytes` preceded by their length, as `writeData` and `writeString` do.
  package mutating func writeData(_ bytes: UnsafeRawBufferPointer) throws(CodingError) {
    guard bytes.count <= Int(UInt32.max) else { throw .outOfSpace }
    let prefixSize = pbRawVarint32Size(UInt32(bytes.count))
    let available = self.spaceLeft
    if prefixSize > available || bytes.count > available - prefixSize {
      throw .outOfSpace
    }
    self.writeVarintUnchecked(UInt64(bytes.count))
    if let source = bytes.baseAddress, bytes.count > 0 {
      (self.base + self.position).copyMemory(from: source, byteCount: bytes.count)
    }
    self.position += bytes.count
  }
}
