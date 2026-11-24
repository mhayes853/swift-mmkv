#if canImport(Darwin)
  import Darwin
#elseif canImport(Android)
  import Android
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// How long a store keeps a value.
///
/// ```swift
/// store.set("123456", forKey: "otp", expiry: .after(.seconds(30)))
/// store.set("blob", forKey: "username", expiry: .never)
/// ```
///
/// A write that names no expiry uses the store's ``MMKVConfiguration/defaultExpiry``.
///
/// An expired key reads as if it had been removed, and is left out of the store's keys and
/// count. Nothing reports the moment a key expires, so a change listener or a subscription to
/// the key hears nothing until the key is next written or removed.
///
/// MMKV records the second a key expires at, by the device's clock, so changing the clock moves
/// every expiry with it.
public struct MMKVExpiry: Sendable, Hashable {
  fileprivate enum Storage: Sendable, Hashable {
    case never
    case after(Duration)
    case at(secondsSince1970: Int64)
  }

  fileprivate let storage: Storage

  private init(_ storage: Storage) {
    self.storage = storage
  }

  /// The value is kept until it is removed.
  public static let never = MMKVExpiry(.never)

  /// The value is kept for `duration` from the moment it is written, rounded up to a whole
  /// second. The shortest a value is kept for is one second.
  public static func after(_ duration: Duration) -> MMKVExpiry {
    MMKVExpiry(.after(duration))
  }

  /// The value is kept until `secondsSince1970` seconds after the start of 1970 in UTC, which
  /// is how a token's `exp` claim counts.
  ///
  /// A value written after that moment is kept for one second.
  public static func at(secondsSince1970: Int64) -> MMKVExpiry {
    MMKVExpiry(.at(secondsSince1970: secondsSince1970))
  }
}

extension MMKVExpiry: CustomStringConvertible {
  public var description: String {
    switch self.storage {
    case .never: "never"
    case .after(let duration): "after \(duration)"
    case .at(let secondsSince1970): "at \(secondsSince1970) seconds since 1970"
    }
  }
}

/// The number of seconds the core should keep a key written now for, or zero to keep it until
/// it is removed.
///
/// The core records the second a key expires at in 32 bits, and silently brings a later moment
/// back to the last one it can record, in 2106. An expiry it cannot record is therefore turned
/// into no expiry, which is what was meant by it.
func expirySeconds(for expiry: MMKVExpiry, now: Int64 = Int64(time(nil))) -> UInt32 {
  let seconds: Int64
  switch expiry.storage {
  case .never:
    return 0
  case .after(let duration):
    // Rounded up, so that a key never expires early.
    let components = duration.components
    let (rounded, overflow) = components.seconds.addingReportingOverflow(
      components.attoseconds > 0 ? 1 : 0
    )
    seconds = overflow ? .max : rounded
  case .at(let deadline):
    seconds =
      deadline.subtractingReportingOverflow(now).overflow
      ? (deadline > 0 ? .max : 1) : deadline - now
  }
  let latest = Int64(UInt32.max) - now
  // The core reserves zero for "never", so the shortest expiry is one second.
  return seconds >= latest ? 0 : UInt32(Swift.max(seconds, 1))
}
