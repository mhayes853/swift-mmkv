import CSwiftMMKV
import SwiftMMKV

/// The expiry of a C write, where zero seconds means never.
private func expiry(_ seconds: UInt32) -> Duration? {
  seconds == 0 ? nil : .seconds(Int64(seconds))
}

private func set<V: MMKVValue>(
  _ value: V,
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ expiresInSeconds: UInt32
) -> Bool {
  store.store.set(value, forKey: String(cString: key), expiringIn: expiry(expiresInSeconds))
}

private func get<V: MMKVValue>(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<V>
) -> Bool {
  guard let value = store.store.value(forKey: String(cString: key), as: V.self) else {
    return false
  }
  outValue.pointee = value
  return true
}

// MARK: - Writes

@c @implementation
public func swiftmmkv_store_set_bool(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ value: Bool,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(value, store, key, expiresInSeconds)
}

@c @implementation
public func swiftmmkv_store_set_int32(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ value: Int32,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(value, store, key, expiresInSeconds)
}

@c @implementation
public func swiftmmkv_store_set_uint32(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ value: UInt32,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(value, store, key, expiresInSeconds)
}

@c @implementation
public func swiftmmkv_store_set_int64(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ value: Int64,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(value, store, key, expiresInSeconds)
}

@c @implementation
public func swiftmmkv_store_set_uint64(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ value: UInt64,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(value, store, key, expiresInSeconds)
}

@c @implementation
public func swiftmmkv_store_set_float(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ value: Float,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(value, store, key, expiresInSeconds)
}

@c @implementation
public func swiftmmkv_store_set_double(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ value: Double,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(value, store, key, expiresInSeconds)
}

@c @implementation
public func swiftmmkv_store_set_string(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ value: UnsafePointer<CChar>,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(String(cString: value), store, key, expiresInSeconds)
}

@c @implementation
public func swiftmmkv_store_set_bytes(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ bytes: UnsafeRawPointer?,
  _ count: Int,
  _ expiresInSeconds: UInt32
) -> Bool {
  store.store.set(
    unsafeBytes: UnsafeRawBufferPointer(start: bytes, count: bytes == nil ? 0 : count),
    forKey: String(cString: key),
    expiringIn: expiry(expiresInSeconds)
  )
}

@c @implementation
public func swiftmmkv_store_set_strings(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ values: UnsafePointer<UnsafePointer<CChar>>?,
  _ count: Int,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(makeStrings(values, count), store, key, expiresInSeconds)
}

// MARK: - Reads

@c @implementation
public func swiftmmkv_store_get_bool(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<Bool>
) -> Bool {
  get(store, key, outValue)
}

@c @implementation
public func swiftmmkv_store_get_int32(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<Int32>
) -> Bool {
  get(store, key, outValue)
}

@c @implementation
public func swiftmmkv_store_get_uint32(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<UInt32>
) -> Bool {
  get(store, key, outValue)
}

@c @implementation
public func swiftmmkv_store_get_int64(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<Int64>
) -> Bool {
  get(store, key, outValue)
}

@c @implementation
public func swiftmmkv_store_get_uint64(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<UInt64>
) -> Bool {
  get(store, key, outValue)
}

@c @implementation
public func swiftmmkv_store_get_float(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<Float>
) -> Bool {
  get(store, key, outValue)
}

@c @implementation
public func swiftmmkv_store_get_double(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<Double>
) -> Bool {
  get(store, key, outValue)
}

@c @implementation
public func swiftmmkv_store_get_string(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
  _ outLength: UnsafeMutablePointer<Int>?
) -> Bool {
  guard let value = store.store.value(forKey: String(cString: key), as: String.self) else {
    return false
  }
  let (pointer, length) = makeCString(value)
  outValue.pointee = pointer
  outLength?.pointee = length
  return true
}

@c @implementation
public func swiftmmkv_store_get_bytes(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outBytes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
  _ outCount: UnsafeMutablePointer<Int>
) -> Bool {
  let copy = store.store.withUnsafeBytes(forKey: String(cString: key)) { bytes in
    // An empty value still gets an allocation, so that the caller always has one to free.
    let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: max(bytes.count, 1))
    UnsafeMutableRawBufferPointer(start: copy, count: bytes.count).copyMemory(from: bytes)
    return (pointer: copy, count: bytes.count)
  }
  guard let copy else { return false }
  outBytes.pointee = copy.pointer
  outCount.pointee = copy.count
  return true
}

@c @implementation
public func swiftmmkv_store_get_strings(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValues: UnsafeMutablePointer<OpaquePointer?>
) -> Bool {
  guard let values = store.store.value(forKey: String(cString: key), as: [String].self) else {
    return false
  }
  outValues.pointee = OpaquePointer(retaining: StringList(values))
  return true
}
