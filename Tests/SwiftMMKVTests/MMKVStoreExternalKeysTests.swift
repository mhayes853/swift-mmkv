import Foundation
@_spi(Engines) import SwiftMMKV
import Testing

/// Telling which keys another process changed. The linked stores stand in for two processes.
@Suite(.requires(.store, .multiProcess, .externalKeys))
struct MMKVStoreExternalKeysTests {
  /// A pair of linked stores, the second subscribed to, with both loaded.
  private func observedPair(
    encryption: MMKVConfiguration.Encryption? = nil,
    _ setUp: (MMKVStore) -> Void = { _ in }
  ) throws -> (other: MMKVStore, store: MMKVStore, recorder: ChangeRecorder, MMKVSubscription) {
    let (other, store) = try makeLinkedStores(mode: .multiProcess, encryption: encryption)
    setUp(other)
    _ = store.count
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)
    return (other, store, recorder, subscription)
  }

  // MARK: - Appends

  @Test(arguments: [nil, MMKVConfiguration.Encryption.aes128(key: "secret")])
  func `Reports The Keys Another Process Appended, Each Once, In Order`(
    encryption: MMKVConfiguration.Encryption?
  ) throws {
    let (other, store, recorder, subscription) = try observedPair(encryption: encryption) {
      $0.set("old", forKey: "gone")
    }
    defer { subscription.cancel() }

    other.set("one", forKey: "b")
    other.set("two", forKey: "a")
    other.set("three", forKey: "b")
    other.removeValue(forKey: "gone")
    store.checkForExternalChanges()

    #expect(recorder.batches == [[.externalKey("b"), .externalKey("a"), .externalKey("gone")]])
    #expect(store.value(forKey: "b", as: String.self) == "three")
    #expect(store.value(forKey: "gone", as: String.self) == nil)
  }

  @Test func `Reports A Large Encrypted Value Another Process Appended`() throws {
    let (other, store, recorder, subscription) = try observedPair(encryption: .aes128(key: "k"))
    defer { subscription.cancel() }
    let large = String(repeating: "x", count: 4096)

    other.set(large, forKey: "large")
    other.set("small", forKey: "small")
    store.checkForExternalChanges()

    #expect(recorder.batches == [[.externalKey("large"), .externalKey("small")]])
    #expect(store.value(forKey: "large", as: String.self) == large)
  }

  @Test func `An External Batch Comes Before The Write That Noticed It`() throws {
    let (other, store, recorder, subscription) = try observedPair()
    defer { subscription.cancel() }

    other.set("theirs", forKey: "a")
    store.set("mine", forKey: "b")

    #expect(recorder.batches == [[.externalKey("a")], [.key("b")]])
  }

  @Test func `External Changes Noticed In A Locked Body Come Before Its Own`() throws {
    let (other, store, recorder, subscription) = try observedPair()
    defer { subscription.cancel() }

    other.set("theirs", forKey: "a")
    store.withExclusiveLock { store in
      store.set("mine", forKey: "b")
      store.set("mine", forKey: "c")
    }

    #expect(recorder.batches == [[.externalKey("a")], [.key("b"), .key("c")]])
  }

  // MARK: - Rewrites

  @Test(arguments: [nil, MMKVConfiguration.Encryption.aes128(key: "secret")])
  func `Reports Only The Keys Whose Values A Rewrite Changed`(
    encryption: MMKVConfiguration.Encryption?
  ) throws {
    let (other, store, recorder, subscription) = try observedPair(encryption: encryption) {
      $0.set("same", forKey: "kept")
      $0.set("old", forKey: "changed")
      $0.set("old", forKey: "removed")
    }
    defer { subscription.cancel() }

    other.set("new", forKey: "changed")
    other.set("new", forKey: "added")
    // Removing several keys rewrites the whole file.
    other.removeValues(forKeys: ["removed", "absent"])
    store.checkForExternalChanges()

    #expect(
      recorder.batches == [["changed", "added", "removed"].map(Change.externalKey)]
    )
    #expect(store.value(forKey: "added", as: String.self) == "new")
  }

  @Test func `Reports The Keys Of Writes That Filled And Compacted The File`() throws {
    let (other, store, recorder, subscription) = try observedPair {
      $0.set("same", forKey: "kept")
    }
    defer { subscription.cancel() }
    let sizeBefore = store.byteSize

    for index in 0..<500 {
      other.set(String(repeating: "\(index % 10)", count: 100), forKey: "busy")
    }
    store.checkForExternalChanges()

    #expect(store.byteSize == sizeBefore)
    #expect(recorder.batches == [[.externalKey("busy")]])
  }

  @Test func `Reports Every Key When Another Process Removes Them All`() throws {
    let (other, store, recorder, subscription) = try observedPair {
      $0.set("1", forKey: "b")
      $0.set("2", forKey: "a")
    }
    defer { subscription.cancel() }

    other.removeAll()
    store.checkForExternalChanges()

    #expect(recorder.batches == [[.externalKey("a"), .externalKey("b")]])
  }

  @Test func `A Rewrite That Changes No Value Reports Nothing`() throws {
    let (other, store, recorder, subscription) = try observedPair {
      $0.set("1", forKey: "a")
      $0.set("2", forKey: "a")
    }
    defer { subscription.cancel() }

    other.removeValues(forKeys: ["absent"])
    other.trim()
    store.checkForExternalChanges()

    #expect(recorder.batches.isEmpty)
    #expect(store.value(forKey: "a", as: String.self) == "2")
  }

  @Test func `This Process's Own Writes Are Not Reported As External After A Rewrite`() throws {
    let (other, store, recorder, subscription) = try observedPair {
      $0.set("1", forKey: "a")
      $0.set("1", forKey: "doomed")
    }
    defer { subscription.cancel() }

    store.set("mine", forKey: "mine")
    store.removeValue(forKey: "a")
    other.removeValues(forKeys: ["doomed"])
    store.checkForExternalChanges()

    #expect(recorder.batches == [[.key("mine")], [.key("a")], [.externalKey("doomed")]])
  }

  @Test func `A Rewrite That Restores A Value This Process Changed Is Reported`() throws {
    let (other, store, recorder, subscription) = try observedPair {
      $0.set("original", forKey: "a")
      $0.set("1", forKey: "doomed")
    }
    defer { subscription.cancel() }

    store.set("mine", forKey: "a")
    _ = other.count
    other.set("original", forKey: "a")
    other.removeValues(forKeys: ["doomed"])
    store.checkForExternalChanges()

    #expect(recorder.batches == [[.key("a")], [.externalKey("a"), .externalKey("doomed")]])
    #expect(store.value(forKey: "a", as: String.self) == "original")
  }

  @Test func `Reports Keys After This Process Rewrote The File Itself`() throws {
    let (other, store, recorder, subscription) = try observedPair {
      $0.set("1", forKey: "a")
      $0.set("1", forKey: "b")
    }
    defer { subscription.cancel() }

    store.removeValues(forKeys: ["b"])
    other.set("2", forKey: "a")
    store.checkForExternalChanges()

    #expect(recorder.batches == [[.key("b")], [.externalKey("a")]])
  }

  // MARK: - Subscribing and releasing memory

  @Test func `A Key Subscription Ignores Another Process's Writes To Other Keys`() throws {
    let (other, store) = try makeLinkedStores(mode: .multiProcess)
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(forKey: "watched", recorder.record)
    defer { subscription.cancel() }

    other.set("x", forKey: "unrelated")
    store.checkForExternalChanges()
    other.set("y", forKey: "watched")
    store.checkForExternalChanges()

    #expect(recorder.batches == [[.externalKey("watched")]])
  }

  @Test func `A Store Subscribed To While Suspended Reports Keys Once Resumed`() throws {
    let (other, store) = try makeLinkedStores(mode: .multiProcess)
    store.suspend()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)
    defer { subscription.cancel() }

    store.resume()
    _ = store.count
    other.set("x", forKey: "a")
    store.checkForExternalChanges()

    #expect(recorder.batches == [[.wholeStore(.resumed)], [.externalKey("a")]])
  }

  @Test func `Keys Are Reported Again After The Store Releases Its Memory`() throws {
    let (other, store, recorder, subscription) = try observedPair()
    defer { subscription.cancel() }

    store.releaseMemory()
    _ = store.count
    other.set("x", forKey: "a")
    store.checkForExternalChanges()

    #expect(recorder.batches == [[.externalKey("a")]])
  }
}
