import SwiftMMKV
import Testing

@Suite struct MMKVChangesTests {
  @Test func `Produces Each Changed Key In Order`() async throws {
    let store = try makeStore()
    var changes = store.changes.makeAsyncIterator()

    store.set("blob", forKey: "username")
    store.set(0.5, forKey: "volume")
    store.removeValue(forKey: "username")

    #expect(await changes.next() == .key("username"))
    #expect(await changes.next() == .key("volume"))

    store.set(true, forKey: "flag")
    #expect(await changes.next() == .key("flag"))
  }

  @Test func `Produces Nothing For Existing Contents`() async throws {
    let store = try makeStore()
    store.set("blob", forKey: "username")
    var changes = store.changes.makeAsyncIterator()

    store.set(0.5, forKey: "volume")

    #expect(await changes.next() == .key("volume"))
  }

  @Test func `Produces A Waiting Key Once`() async throws {
    let store = try makeStore()
    var changes = store.changes.makeAsyncIterator()

    store.set(1.0, forKey: "count")
    store.set(2.0, forKey: "count")
    store.set(3.0, forKey: "other")
    store.set(4.0, forKey: "count")

    #expect(await changes.next() == .key("count"))
    #expect(await changes.next() == .key("other"))

    store.set(5.0, forKey: "count")
    #expect(await changes.next() == .key("count"))
  }

  @Test func `Produces External Changes`() async throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)
    first.set("initial", forKey: "a")
    _ = second.value(forKey: "a", as: String.self)
    var changes = second.changes.makeAsyncIterator()

    first.set("changed", forKey: "a")
    second.checkForExternalChanges()
    first.set("again", forKey: "a")
    second.checkForExternalChanges()

    #expect(await changes.next() == .external)
  }

  @Test func `Produces The Keys Of A Batch After Its Lock Is Released`() async throws {
    let store = try makeStore()
    var changes = store.changes.makeAsyncIterator()

    store.withExclusiveLock { store in
      store.set(1.0, forKey: "count")
      store.set(2.0, forKey: "count")
      store.set("blob", forKey: "username")
    }

    #expect(await changes.next() == .key("count"))
    #expect(await changes.next() == .key("username"))
  }

  @Test func `Each Iteration Observes Separately`() async throws {
    let store = try makeStore()
    let sequence = store.changes
    var first = sequence.makeAsyncIterator()
    var second = sequence.makeAsyncIterator()

    store.set(1.0, forKey: "count")

    #expect(await first.next() == .key("count"))
    #expect(await second.next() == .key("count"))
  }

  @Test func `Ends When Its Task Is Cancelled`() async throws {
    let store = try makeStore()
    let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
    let task = Task {
      var count = 0
      var changes = store.changes.makeAsyncIterator()
      startedContinuation.yield()
      while await changes.next() != nil {
        count += 1
        startedContinuation.yield()
      }
      return count
    }
    var signals = started.makeAsyncIterator()
    await signals.next()
    store.set(1.0, forKey: "count")
    await signals.next()

    task.cancel()

    #expect(await task.value == 1)
  }
}
