// How MMKV encodes each type of value, from the setters and getters in MMKV.cpp and from
// MiniPBCoder.cpp.
//
// A record in the data file is a length-delimited key followed by a length-delimited value. The
// value's own bytes, which this file produces and reads, are:
//
// - `Bool`, the integers, `Float`, and `Double`: their protobuf encoding.
// - `String` and bytes: the bytes preceded by their length, so a string is length-delimited twice
//   in the file. MMKV calls these "data holders".
// - `[String]`: a container, the total size of its items as a varint and then each string
//   length-delimited.
//
// A store with expiring keys appends the expiry time, a little-endian `UInt32` of seconds since
// 1970 or 0 for never, to every value.

/// A value as MMKV stores it, before its expiry time is added.
package enum EncodedValue {
  case bool(Bool)
  case int32(Int32)
  case uint32(UInt32)
  case int64(Int64)
  case uint64(UInt64)
  case float(Float)
  case double(Double)
  /// A string's UTF-8 bytes or raw bytes, which MMKV stores the same way.
  case bytes(UnsafeRawBufferPointer)
  case strings([String])

  /// The encoded size without an expiry time.
  package var size: Int {
    switch self {
    case .bool: 1
    case .int32(let value): pbInt32Size(value)
    case .uint32(let value): pbRawVarint32Size(value)
    case .int64(let value): pbUInt64Size(UInt64(bitPattern: value))
    case .uint64(let value): pbUInt64Size(value)
    case .float: fixed32Size
    case .double: fixed64Size
    case .bytes(let bytes): pbRawVarint32Size(UInt32(truncatingIfNeeded: bytes.count)) + bytes.count
    case .strings(let strings):
      Self.containerSize(strings)
        + pbRawVarint32Size(UInt32(truncatingIfNeeded: Self.containerSize(strings)))
    }
  }

  private static func containerSize(_ strings: [String]) -> Int {
    strings.reduce(0) { total, string in
      let count = string.utf8.count
      return total + pbRawVarint32Size(UInt32(truncatingIfNeeded: count)) + count
    }
  }

  /// Encodes the value, followed by `expiry` when the store has expiring keys.
  package func encode(expiry: UInt32?) throws(CodingError) -> [UInt8] {
    let size = self.size + (expiry == nil ? 0 : fixed32Size)
    var result = [UInt8](repeating: 0, count: size)
    var failure: CodingError?
    result.withUnsafeMutableBytes { buffer in
      var output = CodedOutput(buffer)
      do throws(CodingError) {
        try self.write(to: &output)
        if let expiry {
          try output.writeRawLittleEndian32(expiry)
        }
      } catch {
        failure = error
      }
    }
    if let failure { throw failure }
    return result
  }

  private func write(to output: inout CodedOutput) throws(CodingError) {
    switch self {
    case .bool(let value): try output.writeBool(value)
    case .int32(let value): try output.writeInt32(value)
    case .uint32(let value): try output.writeUInt32(value)
    case .int64(let value): try output.writeInt64(value)
    case .uint64(let value): try output.writeUInt64(value)
    case .float(let value): try output.writeFloat(value)
    case .double(let value): try output.writeDouble(value)
    case .bytes(let bytes): try output.writeData(bytes)
    case .strings(let strings):
      try output.writeUInt32(UInt32(truncatingIfNeeded: Self.containerSize(strings)))
      for var string in strings {
        var failure: CodingError?
        string.withUTF8 { utf8 in
          do throws(CodingError) {
            try output.writeData(UnsafeRawBufferPointer(utf8))
          } catch {
            failure = error
          }
        }
        if let failure { throw failure }
      }
    }
  }
}

/// Reads a value's bytes as each type, as MMKV's getters do. Each reads from the start of the
/// value and ignores anything after what it needs, including an expiry time.
package enum ValueDecoding {
  package static func bool(_ value: UnsafeRawBufferPointer) throws(CodingError) -> Bool {
    var input = CodedInput(value)
    return try input.readBool()
  }

  package static func int32(_ value: UnsafeRawBufferPointer) throws(CodingError) -> Int32 {
    var input = CodedInput(value)
    return try input.readInt32()
  }

  package static func uint32(_ value: UnsafeRawBufferPointer) throws(CodingError) -> UInt32 {
    var input = CodedInput(value)
    return try input.readUInt32()
  }

  package static func int64(_ value: UnsafeRawBufferPointer) throws(CodingError) -> Int64 {
    var input = CodedInput(value)
    return try input.readInt64()
  }

  package static func uint64(_ value: UnsafeRawBufferPointer) throws(CodingError) -> UInt64 {
    var input = CodedInput(value)
    return try input.readUInt64()
  }

  package static func float(_ value: UnsafeRawBufferPointer) throws(CodingError) -> Float {
    var input = CodedInput(value)
    return try input.readFloat()
  }

  package static func double(_ value: UnsafeRawBufferPointer) throws(CodingError) -> Double {
    var input = CodedInput(value)
    return try input.readDouble()
  }

  /// The bytes of a string or of raw bytes (`readString` and `readData`).
  package static func bytes(
    _ value: UnsafeRawBufferPointer
  ) throws(CodingError) -> UnsafeRawBufferPointer {
    var input = CodedInput(value)
    return input.bytes(in: try input.readLengthDelimited())
  }

  /// The strings of a container (`decodeOneVector`), which runs to the end of the value.
  package static func strings(_ value: UnsafeRawBufferPointer) throws(CodingError) -> [String] {
    var input = CodedInput(value)
    _ = try input.readInt32()
    var strings = [String]()
    while !input.isAtEnd {
      strings.append(
        String(decoding: input.bytes(in: try input.readLengthDelimited()), as: UTF8.self)
      )
    }
    return strings
  }
}
