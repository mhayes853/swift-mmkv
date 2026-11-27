// The sizes of protobuf encodings, from MMKV's PBUtility.h and PBUtility.cpp.

/// The number of bytes a varint encoding of `value` takes (`pbRawVarint32Size`).
@inlinable
package func pbRawVarint32Size(_ value: UInt32) -> Int {
  if value & (0xffff_ffff << 7) == 0 { return 1 }
  if value & (0xffff_ffff << 14) == 0 { return 2 }
  if value & (0xffff_ffff << 21) == 0 { return 3 }
  if value & (0xffff_ffff << 28) == 0 { return 4 }
  return 5
}

/// The number of bytes a varint encoding of `value` takes (`pbUInt64Size`).
@inlinable
package func pbUInt64Size(_ value: UInt64) -> Int {
  var size = 1
  var remaining = value >> 7
  while remaining != 0 {
    size += 1
    remaining >>= 7
  }
  return size
}

/// The size of an `int32` field, which a negative value sign-extends to ten bytes (`pbInt32Size`).
@inlinable
package func pbInt32Size(_ value: Int32) -> Int {
  value >= 0 ? pbRawVarint32Size(UInt32(value)) : 10
}

/// The size of a little-endian 32-bit field, such as a float or an expiry time.
package let fixed32Size = 4

/// The size of a little-endian 64-bit field, such as a double.
package let fixed64Size = 8
