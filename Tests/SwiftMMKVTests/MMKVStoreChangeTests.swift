import SwiftMMKV
import Testing

@Suite(.requires(.store)) struct MMKVStoreChangeTests {
  @Test func `Reports Each Key That Is Set Or Removed`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    store.set(1.0, forKey: "a")
    store["b"] = "two"
    store.removeValue(forKey: "a")

    #expect(recorder.all == [.key("a"), .key("b"), .key("a")])
    subscription.cancel()
  }

  @Test func `Does Not Report Failed Writes Or Removals Of Missing Keys`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    store.set("value", forKey: "")
    store.removeValue(forKey: "missing")
    store.removeValues(forKeys: ["missing"])

    #expect(recorder.all.isEmpty)
    subscription.cancel()
  }

  @Test func `Reports Every Key Removed In Bulk`() throws {
    let store = try makeStore()
    for key in ["a", "b", "c", "d"] {
      store.set(key, forKey: key)
    }
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    store.removeValues(forKeys: ["a", "missing"])
    store.removeAll { $0 == "b" }
    store.removeAll()

    #expect(recorder.all.prefix(2) == [.key("a"), .key("b")])
    #expect(Set(recorder.all.dropFirst(2)) == [.key("c"), .key("d")])
    #expect(recorder.all.count == 4)
    subscription.cancel()
  }

  @Test func `Stops Reporting Once Cancelled`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    store.set(1.0, forKey: "a")
    subscription.cancel()
    subscription.cancel()
    store.set(2.0, forKey: "b")

    #expect(recorder.all == [.key("a")])
  }

  @Test func `Stops Reporting Once The Subscription Is Released`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()

    do {
      let subscription = store.subscribe(recorder.record)
      store.set(1.0, forKey: "a")
      _ = subscription
    }
    store.set(2.0, forKey: "b")

    #expect(recorder.all == [.key("a")])
  }

  @Test func `Listeners Are Shared By Stores Over The Same Files`() throws {
    let rootDirectory = temporaryRootDirectory()
    let first = try makeStore(rootDirectory: rootDirectory)
    let second = try makeStore(rootDirectory: rootDirectory)
    let recorder = ChangeRecorder()
    let subscription = first.subscribe(recorder.record)

    second.set(1.0, forKey: "a")

    #expect(recorder.all == [.key("a")])
    subscription.cancel()
  }

  @Test func `A Listener May Use The Store It Observes`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe { batch in
      recorder.record(batch)
      if batch.keys == ["source"] {
        store.set(store.value(forKey: "source", as: Double.self)! * 2, forKey: "derived")
      }
    }

    store.set(21.0, forKey: "source")

    #expect(store.value(forKey: "derived", as: Double.self) == 42)
    #expect(recorder.all == [.key("source"), .key("derived")])
    subscription.cancel()
  }
}

/// These tests use stores from `makeLinkedStores(mode:)`, which stand in for two processes.
@Suite(.requires(.store, .multiProcess)) struct MMKVStoreMultiProcessTests {
  @Test func `Multi Process Stores See Each Other's Writes`() throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)

    first.set("from first", forKey: "a")
    #expect(second.value(forKey: "a", as: String.self) == "from first")

    second.set("from second", forKey: "b")
    #expect(first.value(forKey: "b", as: String.self) == "from second")
    #expect(first.keys == ["a", "b"])

    second.removeValue(forKey: "a")
    #expect(first.value(forKey: "a", as: String.self) == nil)
  }

  @Test func `Multi Process Stores Stay Consistent Under Concurrent Writes`() async throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for index in 0..<2000 { first.set(Double(index), forKey: "first\(index)") }
      }
      group.addTask {
        for index in 0..<2000 { second.set(Double(index), forKey: "second\(index)") }
      }
    }

    #expect(first.count == 4000)
    #expect(second.count == 4000)
    for index in stride(from: 0, to: 2000, by: 97) {
      #expect(first.value(forKey: "second\(index)", as: Double.self) == Double(index))
      #expect(second.value(forKey: "first\(index)", as: Double.self) == Double(index))
    }
  }

  @Test func `Exclusive Lock Excludes The Other Instance`() async throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)
    first.set(0.0, forKey: "counter")

    await withTaskGroup(of: Void.self) { group in
      for store in [first, second] {
        group.addTask {
          for _ in 0..<500 {
            store.withExclusiveLock { store in
              let count = store.value(forKey: "counter", as: Double.self) ?? 0
              store.set(count + 1, forKey: "counter")
            }
          }
        }
      }
    }

    #expect(first.value(forKey: "counter", as: Double.self) == 1000)
  }

  @Test func `Reports An External Change When The Store Is Next Used`() throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)
    first.set("initial", forKey: "a")
    _ = second.value(forKey: "a", as: String.self)
    let recorder = ChangeRecorder()
    let subscription = second.subscribe(recorder.record)

    first.set("changed", forKey: "a")
    #expect(recorder.all.isEmpty)

    #expect(second.value(forKey: "a", as: String.self) == "changed")
    #expect(recorder.all == externalChange("a"))
    subscription.cancel()
  }

  @Test func `Checking For External Changes Reports Without A Read`() throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)
    first.set("initial", forKey: "a")
    _ = second.value(forKey: "a", as: String.self)
    let recorder = ChangeRecorder()
    let subscription = second.subscribe(recorder.record)

    second.checkForExternalChanges()
    #expect(recorder.all.isEmpty)

    first.set("changed", forKey: "a")
    second.checkForExternalChanges()
    second.checkForExternalChanges()

    #expect(recorder.all == externalChange("a"))
    subscription.cancel()
  }

  @Test func `An External Listener May Use The Store It Observes`() throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)
    first.set("initial", forKey: "a")
    _ = second.value(forKey: "a", as: String.self)
    let recorder = ValueRecorder<String?>()
    let subscription = second.subscribe { batch in
      if batch.isExternal {
        recorder.record(second.value(forKey: "a", as: String.self))
      }
    }

    first.set("changed", forKey: "a")
    second.checkForExternalChanges()

    #expect(recorder.all == ["changed"])
    subscription.cancel()
  }

  @Test func `External Changes Are Reported After An Exclusive Lock Is Released`() throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)
    first.set("initial", forKey: "a")
    _ = second.value(forKey: "a", as: String.self)
    let recorder = ChangeRecorder()
    let subscription = second.subscribe(recorder.record)

    first.set("changed", forKey: "a")
    second.withExclusiveLock { second in
      #expect(second.value(forKey: "a", as: String.self) == "changed")
      second.withExclusiveLock { _ in }
      #expect(recorder.all.isEmpty)
    }

    #expect(recorder.all == externalChange("a"))
    subscription.cancel()
  }

  @Test func `Single Process Stores Do Not See Each Other's Writes`() throws {
    let (first, second) = try makeLinkedStores(mode: .singleProcess)
    _ = second.count

    first.set("from first", forKey: "a")

    // This is the data loss that mixing up the mode causes, pinned down so that the difference
    // the multi-process tests rely on is real.
    #expect(second.value(forKey: "a", as: String.self) == nil)
  }
}
