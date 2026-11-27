import Foundation
import SwiftMMKV
import Testing

/// Ports of MMKV v2.4.3's `iOS/MMKVDemo/MMKVDemoTests/MMKVDemoTests.mm`. Most of its tests
/// repeat `UnitTest.cpp`'s through the Objective-C API, or test Objective-C types the package does
/// not store; `MANIFEST.md` maps every one.
@Suite(.requires(.store)) struct UpstreamIOSDemoTests {
  @Test func `Int64 Max Round Trips`() throws {
    // Upstream: MMKVDemoTests.mm testInt64
    let store = try makeStore()

    #expect(store.set(Int64.max, forKey: "int64"))

    #expect(store.value(forKey: "int64", as: Int64.self) == .max)
    #expect(store.value(forKey: keyNotExist, as: Int64.self) == nil)
  }

  // MARK: - Expiration while enumerating

  @Test(.requires(.expiry)) func `Expired Keys Are Not Listed`() async throws {
    // Upstream: MMKVDemoTests.mm testEnumerateExpiredKeys
    try await self.checkEnumeration(encryption: nil, expireDuringEnumeration: false)
  }

  @Test(.requires(.expiry, .encryption)) func `Expired Encrypted Keys Are Not Listed`()
    async throws
  {
    // Upstream: MMKVDemoTests.mm testEnumerateExpiredKeysEncrypted
    try await self.checkEnumeration(
      encryption: .aes128(key: "enumerate-secret"),
      expireDuringEnumeration: false
    )
  }

  @Test(.requires(.expiry)) func `Keys That Expire After Being Listed Read As Missing`()
    async throws
  {
    // Upstream: MMKVDemoTests.mm testKeysExpireDuringEnumeration
    try await self.checkEnumeration(encryption: nil, expireDuringEnumeration: true)
  }

  @Test(.requires(.expiry, .encryption))
  func `Encrypted Keys That Expire After Being Listed Read As Missing`() async throws {
    // Upstream: MMKVDemoTests.mm testKeysExpireDuringEnumerationEncrypted
    try await self.checkEnumeration(
      encryption: .aes128(key: "enumerate-secret"),
      expireDuringEnumeration: true
    )
  }

  /// Upstream's `checkEnumerationWithCryptKey:expireDuringEnumeration:nonExpiredOnly:`.
  ///
  /// The package lists keys only through ``MMKVStore/keys``, which filters out expired keys like
  /// upstream's `enumerateNonExpiredKeys:`, and its ``MMKVStore/count`` filters them too. So
  /// this ports the `nonExpiredOnly` runs; the unfiltered `enumerateKeys:` and `count` that
  /// upstream checks are not exposed. A listing is a snapshot rather than a callback, so keys
  /// that expire "during enumeration" are keys that expire after `keys` returns.
  private func checkEnumeration(
    encryption: MMKVConfiguration.Encryption?,
    expireDuringEnumeration: Bool
  ) async throws {
    let store = try makeStore(id: "enumeration_expiration", encryption: encryption)
    try enableExpiration(on: store)
    #expect(store.keys.isEmpty)

    let expiry = MMKVExpiry.after(.seconds(expireDuringEnumeration ? 2 : 1))
    for index in 0..<16 {
      let key = "expired-dynamically-allocated-enumeration-key-\(index)"
      #expect(store.set(Int32(42), forKey: key, expiry: expiry))
    }
    #expect(store.set(Int32(7), forKey: "live-key"))
    if !expireDuringEnumeration {
      try await Task.sleep(for: oneSecondExpiry)
    }

    // Upstream's unfiltered count is 17 either way.
    #expect(store.count == (expireDuringEnumeration ? 17 : 1))

    let listed = store.keys
    if expireDuringEnumeration {
      // A value written to expire in two seconds is gone a little over two seconds later.
      try await Task.sleep(for: oneSecondExpiry + .seconds(1))
    }
    for key in listed {
      let expired = key.hasPrefix("expired-")
      if key.hasSuffix("0") {
        #expect(!store.contains(key))
      } else {
        // Reading an expired key removes it; the listed key is still usable afterwards.
        #expect(store.value(forKey: key, as: Int32.self) == (expired ? nil : 7))
      }
    }
    #expect(listed.count == (expireDuringEnumeration ? 17 : 1))
    #expect(listed.contains("live-key"))
    #expect(store.count == 1)
    #expect(store.value(forKey: "live-key", as: Int32.self) == 7)

    #expect(store.set(Int32(8), forKey: "another-live-key"))
    #expect(store.keys == ["live-key", "another-live-key"])
  }

  // MARK: - Instances

  @Test func `Opening One Store Concurrently From Many Threads`() throws {
    // Upstream: MMKVDemoTests.mm testConcurrentGetAndAutoCleanupOwnershipHandoff
    let rootDirectory = temporaryRootDirectory()
    let seed = try makeStore(id: "auto_cleanup_handoff_test", rootDirectory: rootDirectory)
    #expect(seed.set(true, forKey: "value"))
    let failures = ValueRecorder<Int>()

    // Upstream also runs `tryAutoCleanUpInstances` on two more threads, which releases
    // Objective-C instances nothing holds. The package never closes an instance, so only the
    // concurrent opens and writes are ported.
    DispatchQueue.concurrentPerform(iterations: 8) { worker in
      for index in 0..<2000 {
        guard
          let store = try? makeStore(id: "auto_cleanup_handoff_test", rootDirectory: rootDirectory),
          store.set(index & 1 != 0, forKey: "value")
        else {
          failures.record(worker)
          continue
        }
      }
    }

    #expect(failures.all.isEmpty)
    #expect(seed.value(forKey: "value", as: Bool.self) == true)
    seed.removeAll()
  }

  // MARK: - Overwriting

  @Test func `Overwriting One Value A Million Times`() throws {
    // Upstream: MMKVDemoTests.mm testMultiTimesOverwriteValue
    let store = try makeStore()
    var random = SplitMix64(seed: 0x4D4D_4B56)
    var data = [UInt8]()
    var failedWrites = 0

    for _ in 0..<1_000_000 {
      data = Array("\(#filePath)-\(Int32(truncatingIfNeeded: random.next()) & .max)".utf8)
      if !store.set(data, forKey: "data") { failedWrites += 1 }
    }

    #expect(failedWrites == 0)
    #expect(store.value(forKey: "data", as: [UInt8].self) == data)
    #expect(store.value(forKey: keyNotExist, as: [UInt8].self) == nil)
  }
}
