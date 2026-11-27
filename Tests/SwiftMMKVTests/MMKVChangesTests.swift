import SwiftMMKV
import Testing

@Suite struct MMKVChangesTests {
  @Test func `Produces A Batch For Each Operation`() async throws {
    let store = try makeStore()
    var batches = store.changes.makeAsyncIterator()

    store.set("blob", forKey: "username")
    #expect(await batches.next()?.changes == [.key("username")])

    store.set(["a": 1.0, "b": 2.0])
    #expect(await Set(batches.next()?.changes ?? []) == [.key("a"), .key("b")])

    store.removeValue(forKey: "username")
    #expect(await batches.next()?.changes == [.key("username")])
  }

  @Test func `Produces Nothing For Existing Contents`() async throws {
    let store = try makeStore()
    store.set("blob", forKey: "username")
    var batches = store.changes.makeAsyncIterator()

    store.set(0.5, forKey: "volume")

    #expect(await batches.next()?.changes == [.key("volume")])
  }

  @Test func `Produces Waiting Batches As One, With Each Key Once In Order`() async throws {
    let store = try makeStore()
    var batches = store.changes.makeAsyncIterator()

    store.set(1.0, forKey: "count")
    store.set(2.0, forKey: "count")
    store.set(3.0, forKey: "other")
    store.set(4.0, forKey: "count")

    #expect(await batches.next()?.changes == [.key("count"), .key("other")])

    store.set(5.0, forKey: "count")
    #expect(await batches.next()?.changes == [.key("count")])
  }

  @Test func `A Batch Reads The Store's Current Values`() async throws {
    let store = try makeStore()
    var batches = store.changes.makeAsyncIterator()

    store.set(1.0, forKey: "count")
    store.set(2.0, forKey: "count")

    let batch = try #require(await batches.next())
    #expect(batch.value(forKey: "count", as: Double.self) == 2)
  }

  @Test func `Produces External Changes`() async throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)
    first.set("initial", forKey: "a")
    _ = second.value(forKey: "a", as: String.self)
    var batches = second.changes.makeAsyncIterator()

    first.set("changed", forKey: "a")
    second.checkForExternalChanges()
    first.set("again", forKey: "a")
    second.checkForExternalChanges()

    let batch = try #require(await batches.next())
    #expect(batch.keys.isEmpty)
    #expect(batch.isExternal)
  }

  @Test func `Produces A Waiting External Change With The Waiting Keys`() async throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)
    var batches = second.changes.makeAsyncIterator()

    second.set("mine", forKey: "b")
    first.set("changed", forKey: "a")
    second.checkForExternalChanges()

    #expect(await batches.next()?.changes == [.key("b"), .external])
  }

  @Test func `Produces The Keys Of A Locked Body As One Batch`() async throws {
    let store = try makeStore()
    var batches = store.changes.makeAsyncIterator()

    store.withExclusiveLock { store in
      store.set(1.0, forKey: "count")
      store.set(2.0, forKey: "count")
      store.set("blob", forKey: "username")
    }

    #expect(await batches.next()?.changes == [.key("count"), .key("username")])
  }

  @Test func `Each Iteration Observes Separately`() async throws {
    let store = try makeStore()
    let sequence = store.changes
    var first = sequence.makeAsyncIterator()
    var second = sequence.makeAsyncIterator()

    store.set(1.0, forKey: "count")

    #expect(await first.next()?.changes == [.key("count")])
    #expect(await second.next()?.changes == [.key("count")])
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
