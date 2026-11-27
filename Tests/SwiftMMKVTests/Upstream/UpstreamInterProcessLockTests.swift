import Foundation
import SwiftMMKV
import Testing

/// An in-process port of MMKV v2.4.3's `POSIX/demo/TestInterProcessLock.cpp`, whose parent side
/// is `testInterProcessLock` in `demo.cpp`. `MANIFEST.md` maps every upstream function.
///
/// Upstream's parent process takes an exclusive file lock and its child's threads try to take a
/// shared one, which must wait. Here the two processes are two instances over hard-linked files
/// from `makeLinkedStores(mode:)`: each opens the files itself, so their `flock`s exclude each
/// other as two processes' would. The real two-process test needs a helper executable.
@Suite(.requires(.store, .multiProcess)) struct UpstreamInterProcessLockTests {
  @Test func `Readers Wait For Another Instance's Exclusive Lock`() throws {
    // Upstream: TestInterProcessLock.cpp threadTest, demo.cpp testInterProcessLock
    let (first, second) = try makeLinkedStores(mode: .multiProcess)
    first.set("value", forKey: "key")
    _ = second.value(forKey: "key", as: String.self)
    let readers = DispatchGroup()
    let results = ValueRecorder<String?>()

    first.withExclusiveLock { first in
      first.set("changed", forKey: "key")
      // Two reader threads, as upstream starts. Each read takes the shared file lock. They are
      // threads of their own because a queue's may all be busy with other tests, which on a
      // small machine has kept the readers from starting for longer than this test waits.
      for _ in 0..<2 {
        readers.enter()
        Thread.detachNewThread {
          results.record(second.value(forKey: "key", as: String.self))
          readers.leave()
        }
      }
      // Upstream waits a millisecond; waiting longer only makes a wrong result likelier to show.
      #expect(readers.wait(timeout: .now() + .milliseconds(100)) == .timedOut)
      #expect(results.all.isEmpty)
    }

    #expect(readers.wait(timeout: .now() + .seconds(60)) == .success)
    #expect(results.all == ["changed", "changed"])
  }
}
