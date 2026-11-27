import Foundation
import SwiftMMKV
import Testing

@Suite(.requires(.store, .multiProcess)) struct MMKVStoreExpiringActivityTests {
  @Test func `Operations Close Together Share One Activity`() throws {
    let store = try makeStore(mode: .multiProcess)
    let system = TestActivitySystem()
    store.setExpiringActivity(system.makeActivity())

    for index in 0..<100 {
      #expect(store.set(Int32(index), forKey: "key-\(index)"))
      #expect(store.value(forKey: "key-\(index)", as: Int32.self) == Int32(index))
    }
    DispatchQueue.concurrentPerform(iterations: 8) { index in
      store.set(Int32(index), forKey: "concurrent-\(index)")
    }
    #expect(system.startCount == 1)

    system.waitUntilIdle()
    #expect(store.count == 108)
    #expect(system.startCount == 2)
  }

  @Test func `Operations Inside An Exclusive Lock Join Its Activity`() throws {
    let store = try makeStore(mode: .multiProcess)
    let system = TestActivitySystem()
    store.setExpiringActivity(system.makeActivity())

    store.withExclusiveLock { store in
      #expect(store.set("value", forKey: "key"))
      #expect(store["key", as: String.self] == "value")
      #expect(system.runningCount == 1)
    }
    #expect(system.startCount == 1)
  }

  @Test func `An Operation The System Will Not Keep Running Is Turned Away`() throws {
    let store = try makeStore(mode: .multiProcess)
    store.set("value", forKey: "key")
    let system = TestActivitySystem()
    store.setExpiringActivity(system.makeActivity())

    system.isRefusing = true
    #expect(store["key", as: String.self] == nil)
    #expect(!store.set("other", forKey: "key"))
    #expect(!store.isSuspended)

    system.isRefusing = false
    #expect(store["key", as: String.self] == "value")
  }

  @Test func `Expiring Suspends The Stores Once No Operation Holds The Lock`() throws {
    let store = try makeStore(mode: .multiProcess)
    let system = TestActivitySystem()
    store.setExpiringActivity(system.makeActivity { store.suspend() })

    let didLock = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let didFinish = ValueRecorder<Bool>()
    let thread = Thread {
      store.withExclusiveLock { store in
        didLock.signal()
        release.wait()
        store.set("value", forKey: "key")
        didFinish.record(true)
      }
    }
    thread.start()
    didLock.wait()
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { release.signal() }

    system.expire()
    #expect(didFinish.all == [true])
    #expect(store.isSuspended)
    system.waitUntilIdle()

    store.resume()
    #expect(store["key", as: String.self] == "value")
  }

  @Test func `Removing The Activity Runs Operations Directly`() throws {
    let store = try makeStore(mode: .multiProcess)
    let system = TestActivitySystem()
    let activity = system.makeActivity()
    store.setExpiringActivity(activity)
    store.removeExpiringActivity(system.makeActivity())
    #expect(store.set("value", forKey: "key"))
    #expect(system.startCount == 1)

    store.removeExpiringActivity(activity)
    system.waitUntilIdle()
    #expect(store.set("other", forKey: "key"))
    #expect(system.startCount == 1)
  }

  @Test func `A Single Process Store Runs Operations Directly`() throws {
    let store = try makeStore()
    let system = TestActivitySystem()
    store.setExpiringActivity(system.makeActivity())
    #expect(store.set("value", forKey: "key"))
    #expect(system.startCount == 0)
  }
}

/// Plays the system's part in expiring activities: runs each on a thread of its own, keeps
/// count of those still running, and can refuse to keep the process running or make the
/// running ones expire.
final class TestActivitySystem: Sendable {
  private struct State {
    var isRefusing = false
    var startCount = 0
    var running = [Int: @Sendable (Bool) -> Void]()
  }

  private let lock = NSLock()
  nonisolated(unsafe) private var state = State()

  var isRefusing: Bool {
    get { self.lock.withLock { self.state.isRefusing } }
    set { self.lock.withLock { self.state.isRefusing = newValue } }
  }

  var startCount: Int {
    self.lock.withLock { self.state.startCount }
  }

  var runningCount: Int {
    self.lock.withLock { self.state.running.count }
  }

  /// An activity that lingers for a short time, so tests that wait for it to end stay quick.
  func makeActivity(onExpiration: @escaping @Sendable () -> Void = {}) -> ExpiringActivity {
    ExpiringActivity(linger: .milliseconds(100), start: self.start, onExpiration: onExpiration)
  }

  /// Tells each running activity that the process is about to be suspended, and returns once
  /// they have all handled it.
  func expire() {
    let running = self.lock.withLock { Array(self.state.running.values) }
    for block in running {
      block(true)
    }
  }

  func waitUntilIdle(sourceLocation: SourceLocation = #_sourceLocation) {
    let deadline = Date(timeIntervalSinceNow: 5)
    while self.runningCount > 0 && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    #expect(self.runningCount == 0, sourceLocation: sourceLocation)
  }

  func start(_ reason: String, _ block: @escaping @Sendable (Bool) -> Void) {
    let (identifier, isRefused) = self.lock.withLock {
      self.state.startCount += 1
      if !self.state.isRefusing {
        self.state.running[self.state.startCount] = block
      }
      return (self.state.startCount, self.state.isRefusing)
    }
    let thread = Thread {
      block(isRefused)
      self.lock.withLock { _ = self.state.running.removeValue(forKey: identifier) }
    }
    thread.start()
  }
}
