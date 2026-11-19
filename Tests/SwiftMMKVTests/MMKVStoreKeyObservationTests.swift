import SwiftMMKV
import Testing

@Suite(.requires(.store)) struct MMKVStoreKeySubscriptionTests {
  @Test func `Reports Changes To Its Key Only`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<Bool>()
    let subscription = store.subscribe(forKey: "a") { recorder.record(true) }
    #expect(recorder.all.isEmpty)

    store.set(1.0, forKey: "a")
    store.set(2.0, forKey: "b")
    store.removeValue(forKey: "a")

    #expect(recorder.all.count == 2)
    subscription.cancel()
  }

  @Test func `Delivers The Current Value Immediately And Then Each Change`() throws {
    let store = try makeStore()
    store.set(0.5, forKey: "volume")
    let recorder = ValueRecorder<Double?>()
    let subscription = store.subscribe(forKey: "volume", as: Double.self, recorder.record)
    #expect(recorder.all == [0.5])

    store.set(0.8, forKey: "volume")
    store.set("unrelated", forKey: "other")
    store.removeValue(forKey: "volume")

    #expect(recorder.all == [0.5, 0.8, nil])
    subscription.cancel()
  }

  @Test func `Delivers Nil Immediately When The Key Has No Value`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<String?>()
    let subscription = store.subscribe(forKey: "username", as: String.self, recorder.record)

    #expect(recorder.all == [nil])
    subscription.cancel()
  }

  @Test func `Stops Delivering Once Cancelled`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<Double?>()
    let subscription = store.subscribe(forKey: "volume", as: Double.self, recorder.record)

    subscription.cancel()
    store.set(0.8, forKey: "volume")

    #expect(recorder.all == [nil])
  }

  @Test(.requires(.multiProcess))
  func `Delivers The Value Again After A Change Made Outside The Store`() throws {
    let (other, store) = try makeLinkedStores(mode: .multiProcess)
    let recorder = ValueRecorder<String?>()
    let subscription = store.subscribe(forKey: "username", as: String.self, recorder.record)

    other.set("unrelated", forKey: "other")
    store.checkForExternalChanges()
    other.set("blob", forKey: "username")
    store.checkForExternalChanges()

    #expect(recorder.all == [nil, nil, "blob"])
    subscription.cancel()
  }
}

@Suite(.requires(.store)) struct MMKVValuesTests {
  @Test func `Starts With The Current Value And Follows Each Change`() async throws {
    let store = try makeStore()
    store.set(0.5, forKey: "volume")
    var values = store.values(forKey: "volume", as: Double.self).makeAsyncIterator()
    #expect(await values.next() == .some(0.5))

    store.set(0.8, forKey: "volume")
    #expect(await values.next() == .some(0.8))

    store.removeValue(forKey: "volume")
    #expect(await values.next() == .some(nil))
  }

  @Test func `Starts With Nil When The Key Has No Value`() async throws {
    let store = try makeStore()
    var values = store.values(forKey: "volume", as: Double.self).makeAsyncIterator()

    #expect(await values.next() == .some(nil))
  }

  @Test func `Skips To The Newest Value`() async throws {
    let store = try makeStore()
    var values = store.values(forKey: "count", as: Double.self).makeAsyncIterator()

    store.set(1.0, forKey: "count")
    store.set(2.0, forKey: "count")
    store.set(3.0, forKey: "count")
    #expect(await values.next() == .some(3))

    store.set(4.0, forKey: "count")
    #expect(await values.next() == .some(4))
  }

  @Test func `Ignores Other Keys`() async throws {
    let store = try makeStore()
    var values = store.values(forKey: "count", as: Double.self).makeAsyncIterator()
    #expect(await values.next() == .some(nil))

    store.set(1.0, forKey: "other")
    store.set(2.0, forKey: "count")
    #expect(await values.next() == .some(2))
  }

  @Test func `Each Iteration Observes Separately`() async throws {
    let store = try makeStore()
    let sequence = store.values(forKey: "count", as: Double.self)
    var first = sequence.makeAsyncIterator()
    var second = sequence.makeAsyncIterator()

    store.set(1.0, forKey: "count")

    #expect(await first.next() == .some(1))
    #expect(await second.next() == .some(1))
  }

  @Test func `Ends When Its Task Is Cancelled`() async throws {
    let store = try makeStore()
    let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
    let task = Task {
      var count = 0
      for await _ in store.values(forKey: "count", as: Double.self) {
        count += 1
        startedContinuation.yield()
      }
      return count
    }
    _ = await started.first { _ in true }

    task.cancel()

    #expect(await task.value == 1)
  }

  @Test(.requires(.multiProcess))
  func `Follows A Change Made Outside The Store Once It Is Noticed`() async throws {
    let (other, store) = try makeLinkedStores(mode: .multiProcess)
    var values = store.values(forKey: "username", as: String.self).makeAsyncIterator()
    #expect(await values.next() == .some(nil))

    other.set("blob", forKey: "username")
    store.checkForExternalChanges()

    #expect(await values.next() == .some("blob"))
  }

  @Test func `Decodes Values With A Custom Decoder`() async throws {
    let store = try makeStore()
    var values = store.values(forKey: "count", as: Int.self, with: DescriptionCoder())
      .makeAsyncIterator()
    #expect(try await values.next() == .some(nil))

    store.set("42", forKey: "count")
    #expect(try await values.next() == .some(42))
  }

  @Test func `A Value That Cannot Be Decoded Is Thrown And Ends The Sequence`() async throws {
    let store = try makeStore()
    store.set("not a number", forKey: "count")
    var values = store.values(forKey: "count", as: Int.self, with: DescriptionCoder())
      .makeAsyncIterator()

    await #expect(throws: DescriptionCoder.Failure.self) { try await values.next() }

    store.set("42", forKey: "count")
    #expect(try await values.next() == nil)
  }
}
