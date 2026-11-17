import Foundation
import SwiftMMKV
import Testing

/// Ports of MMKV v2.4.3's `POSIX/demo/TestThreadLock.cpp`. `MANIFEST.md` maps every upstream
/// function.
///
/// Upstream tests the core's `ThreadLock` directly. The package reaches that lock through
/// ``MMKVStore/withExclusiveLock(_:)``, which takes it together with the store's file lock.
@Suite(.requires(.store)) struct UpstreamThreadLockTests {
  @Test func `Concurrent Locking Loses No Update`() throws {
    // Upstream: TestThreadLock.cpp concurrentLockingTracksOwnership
    let store = try makeStore()
    let threadCount = 8
    let iterationCount = 10000
    let counter = UnprotectedCounter()

    DispatchQueue.concurrentPerform(iterations: threadCount) { _ in
      for _ in 0..<iterationCount {
        store.withExclusiveLock { _ in counter.value += 1 }
      }
    }

    #expect(counter.value == threadCount * iterationCount)
  }
}

/// A counter that relies entirely on the store's lock to protect it.
private final class UnprotectedCounter: @unchecked Sendable {
  var value = 0
}
