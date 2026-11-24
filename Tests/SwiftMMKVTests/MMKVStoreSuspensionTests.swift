import Foundation
import SwiftMMKV
import Testing

@Suite(.requires(.store, .multiProcess)) struct MMKVStoreSuspensionTests {
  @Test func `A Suspended Store Turns Reads And Writes Away`() throws {
    let store = try makeStore(mode: .multiProcess)
    store.set("blob", forKey: "username")
    #expect(!store.isSuspended)

    store.suspend()
    #expect(store.isSuspended)
    #expect(store.value(forKey: "username", as: String.self) == nil)
    #expect(store.withBytes(forKey: "username") { $0.byteCount } == nil)
    #expect(store.keys.isEmpty)
    #expect(store.count == 0)
    #expect(!store.contains("username"))
    #expect(store.byteSize == 0)
    #expect(!store.set("other", forKey: "username"))
    #expect(!store.set(1.0, forKey: "number"))
    #expect(!store.removeValue(forKey: "username"))
    store.removeAll()
    store.removeAll { _ in true }
    store.trim()
    #expect(store.importAll(from: try makeStore()) == 0)

    store.resume()
    #expect(!store.isSuspended)
    #expect(store.keys == ["username"])
    #expect(store.value(forKey: "username", as: String.self) == "blob")
    #expect(store.set("other", forKey: "username"))
  }

  @Test func `Suspending Twice And Resuming Twice Has No Further Effect`() throws {
    let store = try makeStore(mode: .multiProcess)
    store.suspend()
    store.suspend()
    #expect(store.isSuspended)
    store.resume()
    store.resume()
    #expect(!store.isSuspended)
    #expect(store.set(1.0, forKey: "key"))
  }

  @Test func `A Single Process Store Is Never Suspended`() throws {
    let store = try makeStore()
    store.suspend()
    #expect(!store.isSuspended)
    #expect(store.set("value", forKey: "key"))
    #expect(store["key", as: String.self] == "value")
  }

  @Test func `Stores Over The Same Files Are Suspended Together`() throws {
    let rootDirectory = temporaryRootDirectory()
    let first = try makeStore(rootDirectory: rootDirectory, mode: .multiProcess)
    let second = try makeStore(rootDirectory: rootDirectory, mode: .multiProcess)
    let other = try makeStore(id: "other", rootDirectory: rootDirectory, mode: .multiProcess)

    first.suspend()
    #expect(second.isSuspended)
    #expect(!second.set("value", forKey: "key"))
    #expect(!other.isSuspended)
    #expect(other.set("value", forKey: "key"))

    second.resume()
    #expect(!first.isSuspended)
  }

  @Test func `Throwing Operations Report The Suspension`() throws {
    let store = try makeStore(mode: .multiProcess)
    try store.encode(1, forKey: "number", with: TextCoder.shared)
    store.suspend()

    expectError(.storeIsSuspended) {
      try store.decode(Int.self, forKey: "number", with: TextCoder.shared)
    }
    expectError(.storeIsSuspended) {
      try store.encode(2, forKey: "number", with: TextCoder.shared)
    }
    expectError(.storeIsSuspended) {
      try store.rekey(.aes128(key: "key"))
    }

    store.resume()
    #expect(try store.decode(forKey: "number", with: TextCoder.shared) == 1)
  }

  @Test func `An Exclusive Lock Body Runs Without The Lock While Suspended`() throws {
    let store = try makeStore(mode: .multiProcess)
    store.set(1.0, forKey: "count")
    store.suspend()

    let result = store.withExclusiveLock { store in
      store.set(2.0, forKey: "count")
      return store.value(forKey: "count", as: Double.self)
    }
    #expect(result == nil)

    store.resume()
    #expect(store["count", as: Double.self] == 1)
  }

  @Test func `Suspending Waits For An Operation Under Way On Another Thread`() async throws {
    let store = try makeStore(mode: .multiProcess)
    let events = ValueRecorder<String>()
    let (lockTaken, lockTakenContinuation) = AsyncStream.makeStream(of: Void.self)

    let writer = Thread {
      store.withExclusiveLock { store in
        lockTakenContinuation.yield()
        Thread.sleep(forTimeInterval: 0.2)
        // The operation under way is let through even though the store is being suspended.
        events.record(store.set("value", forKey: "key") ? "wrote" : "refused")
      }
    }
    writer.start()
    for await _ in lockTaken { break }

    store.suspend()
    events.record("suspended")
    #expect(events.all == ["wrote", "suspended"])
    #expect(!store.set("other", forKey: "key"))

    store.resume()
    #expect(store["key", as: String.self] == "value")
  }

  @Test func `Suspending Inside An Exclusive Lock Does Not Deadlock`() throws {
    let store = try makeStore(mode: .multiProcess)
    store.withExclusiveLock { store in
      store.suspend()
      #expect(store.set("value", forKey: "key"))
    }
    #expect(store.isSuspended)
    #expect(!store.set("other", forKey: "key"))
    store.resume()
    #expect(store["key", as: String.self] == "value")
  }

  @Test func `Resuming Tells Listeners To Read Again`() throws {
    let store = try makeStore(mode: .multiProcess)
    store.set(0.5, forKey: "volume")
    let changes = ChangeRecorder()
    let subscription = store.subscribe(changes.record)
    let values = ValueRecorder<Double?>()
    let keySubscription = store.subscribe(forKey: "volume", as: Double.self, values.record)

    store.resume()
    #expect(changes.all.isEmpty)

    store.suspend()
    store.set(0.8, forKey: "volume")
    #expect(changes.all.isEmpty)

    store.resume()
    #expect(changes.all == [.external])
    #expect(values.all == [0.5, 0.5])
    subscription.cancel()
    keySubscription.cancel()
  }

  @Test func `A Sequence Produces Nothing While Suspended And Catches Up On Resuming`()
    async throws
  {
    let (other, store) = try makeLinkedStores(mode: .multiProcess)
    store.set(0.5, forKey: "volume")
    var values = store.values(forKey: "volume", as: Double.self).makeAsyncIterator()
    #expect(await values.next() == .some(0.5))

    store.suspend()
    other.set(0.8, forKey: "volume")
    store.resume()
    #expect(await values.next() == .some(0.8))
  }

  @Test func `A Decoding Sequence Survives A Suspension`() async throws {
    let store = try makeStore(mode: .multiProcess)
    try store.encode(1, forKey: "number", with: TextCoder.shared)
    store.suspend()
    var values = store.values(forKey: "number", as: Int.self, with: TextCoder.shared)
      .makeAsyncIterator()

    store.resume()
    #expect(try await values.next() == .some(1))
  }
}
