import SwiftMMKV
import Testing

@Suite struct MMKVStoreBatchTests {
  @Test func `Reads The Values Of Several Keys And Leaves Out Those Without One`() throws {
    let store = try makeStore()
    store.set(10.0, forKey: "score.1")
    store.set(12.5, forKey: "score.2")
    store.set("blob", forKey: "username")

    let scores = store.values(forKeys: ["score.1", "score.2", "score.3"], as: Double.self)
    let names = store.values(forKeys: ["username", "nickname"], as: String.self)

    #expect(scores == ["score.1": 10, "score.2": 12.5])
    #expect(names == ["username": "blob"])
  }

  @Test func `Reads Nothing For No Keys`() throws {
    let store = try makeStore()
    store.set(1.0, forKey: "score")

    #expect(store.values(forKeys: [String](), as: Double.self).isEmpty)
  }

  @Test func `Reads The Keys Of Any Sequence Once Each`() throws {
    let store = try makeStore()
    store.set(1.0, forKey: "a")
    store.set(2.0, forKey: "b")

    let values = store.values(forKeys: Set(["a", "b"]), as: Double.self)
    let repeated = store.values(forKeys: ["a", "a"], as: Double.self)

    #expect(values == ["a": 1, "b": 2])
    #expect(repeated == ["a": 1])
  }

  @Test func `Stores Several Values And Replaces Existing Ones`() throws {
    let store = try makeStore()
    store.set(1.0, forKey: "score.1")

    let didStore = store.set(["score.1": 10.0, "score.2": 12.5])

    #expect(didStore)
    #expect(store.value(forKey: "score.1", as: Double.self) == 10)
    #expect(store.value(forKey: "score.2", as: Double.self) == 12.5)
    #expect(store.count == 2)
  }

  @Test func `Storing No Values Succeeds And Changes Nothing`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    #expect(store.set([String: Double]()))
    #expect(recorder.all.isEmpty)
    #expect(store.keys.isEmpty)
    subscription.cancel()
  }

  @Test func `A Value That Cannot Be Stored Does Not Stop The Others`() throws {
    let store = try makeStore(itemSizeLimit: 32)
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    let didStore = store.set(["small": "a", "large": String(repeating: "x", count: 64), "": "b"])

    #expect(!didStore)
    #expect(store.keys == ["small"])
    #expect(recorder.all == [.key("small")])
    subscription.cancel()
  }

  @Test func `Stores Nothing In A Read Only Store`() throws {
    let rootDirectory = temporaryRootDirectory()
    _ = try makeStore(rootDirectory: rootDirectory)
    let store = try makeStore(id: "readonly", rootDirectory: rootDirectory, isReadOnly: true)

    #expect(!store.set(["a": 1.0]))
  }

  @Test func `Listeners Are Told About Each Key After Every Value Is Written`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<[String: Double]>()
    let subscription = store.subscribe { change in
      guard case .key = change else { return }
      recorder.record(store.values(forKeys: ["a", "b", "c"], as: Double.self))
    }

    store.set(["a": 1.0, "b": 2.0, "c": 3.0])

    #expect(recorder.all == Array(repeating: ["a": 1, "b": 2, "c": 3], count: 3))
    subscription.cancel()
  }

  @Test func `A Key's Subscription Is Given Its Value From The Batch`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<Double?>()
    let subscription = store.subscribe(forKey: "b", as: Double.self, recorder.record)

    store.set(["a": 1.0, "b": 2.0])

    #expect(recorder.all == [nil, 2])
    subscription.cancel()
  }

  @Test func `Expiring Values Disappear After Their Duration`() async throws {
    let store = try makeStore()
    store.set(0.0, forKey: "kept")

    store.set(["a": 1.0, "b": 2.0], expiringIn: .seconds(1))
    #expect(store.values(forKeys: ["a", "b"], as: Double.self) == ["a": 1, "b": 2])

    try await Task.sleep(for: .seconds(2.1))

    #expect(store.values(forKeys: ["a", "b", "kept"], as: Double.self) == ["kept": 0])
  }

  @Test func `A Suspended Store Reads And Stores Nothing`() throws {
    let store = try makeStore(mode: .multiProcess)
    store.set(1.0, forKey: "a")
    store.suspend()

    #expect(store.values(forKeys: ["a"], as: Double.self).isEmpty)
    #expect(!store.set(["b": 2.0]))

    store.resume()
    #expect(store.keys == ["a"])
  }

  @Test func `Listeners Are Told About The Keys An Exclusive Lock Changed Once It Returns`()
    throws
  {
    let store = try makeStore()
    store.set("old", forKey: "legacy")
    let changes = ChangeRecorder()
    let states = ValueRecorder<Set<String>>()
    let subscription = store.subscribe { change in
      changes.record(change)
      states.record(store.keys)
    }

    store.withExclusiveLock { store in
      store.set("blob", forKey: "username")
      store.set(0.8, forKey: "volume")
      store.removeValue(forKey: "legacy")
      #expect(changes.all.isEmpty)
    }

    #expect(changes.all == [.key("username"), .key("volume"), .key("legacy")])
    #expect(states.all == Array(repeating: ["username", "volume"], count: 3))
    subscription.cancel()
  }

  @Test func `A Key Changed More Than Once In An Exclusive Lock Is Reported Once`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<Double?>()
    let subscription = store.subscribe(forKey: "count", as: Double.self, recorder.record)

    store.withExclusiveLock { store in
      store.set(1.0, forKey: "count")
      store.withExclusiveLock { store in
        _ = store.set(2.0, forKey: "count")
      }
      store.set(3.0, forKey: "count")
    }

    #expect(recorder.all == [nil, 3])
    subscription.cancel()
  }

  @Test func `Listeners Are Told About Changes Made Before An Exclusive Lock Throws`() throws {
    struct Failure: Error {}
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    #expect(throws: Failure.self) {
      try store.withExclusiveLock { store in
        store.set(1.0, forKey: "count")
        throw Failure()
      }
    }

    #expect(recorder.all == [.key("count")])
    #expect(store.value(forKey: "count", as: Double.self) == 1)
    subscription.cancel()
  }
}
