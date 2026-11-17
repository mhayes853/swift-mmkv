/// The CRC-32 MMKV checksums its data with: zlib's `crc32`, the IEEE 802.3 polynomial in its
/// reflected form. The ARMv8 instructions MMKV uses where it can compute the same function.
package enum CRC32 {
  /// Continues the checksum `crc` over `bytes`, as `crc32(crc, bytes, count)` does. Start from 0.
  package static func checksum(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
    var value = ~crc
    var index = 0
    let count = bytes.count
    // Slicing by eight: eight table lookups for each eight bytes.
    while count - index >= 8 {
      let low = value ^ bytes.loadUnaligned(fromByteOffset: index, as: UInt32.self).littleEndian
      let high = bytes.loadUnaligned(fromByteOffset: index + 4, as: UInt32.self).littleEndian
      value =
        tables[7][Int(low & 0xff)] ^ tables[6][Int((low >> 8) & 0xff)]
        ^ tables[5][Int((low >> 16) & 0xff)] ^ tables[4][Int(low >> 24)]
        ^ tables[3][Int(high & 0xff)] ^ tables[2][Int((high >> 8) & 0xff)]
        ^ tables[1][Int((high >> 16) & 0xff)] ^ tables[0][Int(high >> 24)]
      index += 8
    }
    while index < count {
      value = tables[0][Int((value ^ UInt32(bytes[index])) & 0xff)] ^ (value >> 8)
      index += 1
    }
    return ~value
  }

  private static let tables: [[UInt32]] = {
    var tables = [[UInt32]](repeating: [UInt32](repeating: 0, count: 256), count: 8)
    for byte in 0..<256 {
      var value = UInt32(byte)
      for _ in 0..<8 {
        value = value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
      }
      tables[0][byte] = value
    }
    for byte in 0..<256 {
      for table in 1..<8 {
        let previous = tables[table - 1][byte]
        tables[table][byte] = (previous >> 8) ^ tables[0][Int(previous & 0xff)]
      }
    }
    return tables
  }()
}
