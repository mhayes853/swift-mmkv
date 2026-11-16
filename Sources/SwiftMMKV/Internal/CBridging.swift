import CSwiftMMKVCore

extension String {
  /// Calls `body` with the string's UTF-8 bytes, which are only valid during the call.
  @inline(__always)
  func withMMKVBytes<R>(_ body: (mmkv_bytes) -> R) -> R {
    var string = self
    return string.withUTF8 { body(mmkv_bytes(bytes: $0.baseAddress, count: $0.count)) }
  }
}

extension [String] {
  /// Calls `body` with the UTF-8 bytes of every string, which are only valid during the call.
  func withMMKVBytes<R>(_ body: (UnsafeBufferPointer<mmkv_bytes>) -> R) -> R {
    // One contiguous copy of all the strings' bytes, so that every element can point into it.
    var storage = [UInt8]()
    var ranges = [Range<Int>]()
    ranges.reserveCapacity(self.count)
    for string in self {
      let start = storage.count
      storage.append(contentsOf: string.utf8)
      ranges.append(start..<storage.count)
    }
    return storage.withUnsafeBytes { buffer in
      let elements = ranges.map { range in
        mmkv_bytes(
          bytes: buffer.baseAddress.map { $0 + range.lowerBound },
          count: range.count
        )
      }
      return elements.withUnsafeBufferPointer(body)
    }
  }
}

extension UnsafeRawBufferPointer {
  init(_ bytes: mmkv_bytes) {
    self.init(start: bytes.bytes, count: bytes.count)
  }
}

/// Runs a C read that reports its bytes through a callback, handing each run to `visit`.
///
/// A C function pointer cannot capture context, so `visit` is passed as the callback's context.
///
/// - Returns: Whether the read reports that there is a value.
func forEachCallbackBytes(
  _ read: (UnsafeMutableRawPointer, mmkv_bytes_callback) -> Bool,
  _ visit: (UnsafeRawBufferPointer) -> Void
) -> Bool {
  withoutActuallyEscaping(visit) { visit in
    var visit = visit
    return withUnsafeMutablePointer(to: &visit) { visit in
      read(UnsafeMutableRawPointer(visit)) { context, bytes in
        let visit = context!.assumingMemoryBound(to: ((UnsafeRawBufferPointer) -> Void).self)
        visit.pointee(UnsafeRawBufferPointer(bytes))
      }
    }
  }
}

/// Runs a C read that reports a single run of bytes through a callback, handing it to `body`.
///
/// - Returns: `nil` if the read reports that there is no value.
func withCallbackBytes<R, E: Error>(
  _ read: (UnsafeMutableRawPointer, mmkv_bytes_callback) -> Bool,
  _ body: (UnsafeRawBufferPointer) throws(E) -> R
) throws(E) -> R? {
  var result: Result<R, E>?
  _ = forEachCallbackBytes(read) { buffer in
    guard result == nil else { return }
    do throws(E) {
      result = .success(try body(buffer))
    } catch {
      result = .failure(error)
    }
  }
  return try result?.get()
}

extension Duration {
  /// The whole number of seconds MMKV should keep a key for, rounding up so that a key never
  /// expires early. MMKV reserves zero for "never", so the shortest expiry is one second.
  var mmkvExpirySeconds: UInt32 {
    let components = self.components
    let seconds = components.attoseconds > 0 ? components.seconds + 1 : components.seconds
    return UInt32(clamping: Swift.max(seconds, 1))
  }
}
