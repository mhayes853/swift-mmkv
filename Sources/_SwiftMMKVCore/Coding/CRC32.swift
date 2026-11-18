import CSwiftMMKVCrypto

/// The CRC-32 MMKV checksums its data with: zlib's `crc32`, the IEEE 802.3 polynomial in its
/// reflected form, computed with the ARMv8 CRC32 instructions on 64-bit ARM when the CPU has them
/// and with zlib otherwise.
package enum CRC32 {
  /// Continues the checksum `crc` over `bytes`, as `crc32(crc, bytes, count)` does. Start from 0.
  @inline(__always)
  package static func checksum(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
    swiftmmkv_crc32(crc, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count)
  }
}
