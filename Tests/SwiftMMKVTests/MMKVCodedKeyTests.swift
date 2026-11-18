import Foundation
import SwiftMMKV
import Testing

extension MMKVStore.CodedKey where Value == Int {
  fileprivate static let count = Self("count", encoder: TextCoder.shared, decoder: TextCoder.shared)

  fileprivate static func score(_ level: Int) -> Self {
    Self("score.\(level)", encoder: TextCoder.shared, decoder: TextCoder.shared)
  }
}

extension MMKVStore.CodedKey where Value == [Int] {
  fileprivate static let unencodable = Self(
    "unencodable",
    encoder: TextCoder.shared,
    decoder: TextCoder.shared
  )
}

extension MMKVStore.DefaultedCodedKey where Value == Int {
  fileprivate static let lives = Self(
    "lives",
    default: 3,
    encoder: TextCoder.shared,
    decoder: TextCoder.shared
  )

  fileprivate static let countOrZero = Self(.count, default: 0)
}

@Suite struct MMKVStoreCodedKeyTests {
  @Test func `Is Equal To A Key With The Same Name And Coders`() {
    let other = TextCoder()

    #expect(MMKVStore.CodedKey.score(1) == .score(1))
    #expect(MMKVStore.CodedKey.score(1) != .score(2))
    #expect(Set([MMKVStore.CodedKey.score(1), .score(1), .score(2)]).count == 2)
    #expect(
      MMKVStore.CodedKey.count
        != MMKVStore.CodedKey<Int>("count", encoder: other, decoder: TextCoder.shared)
    )
    #expect(
      MMKVStore.CodedKey.count
        != MMKVStore.CodedKey<Int>("count", encoder: TextCoder.shared, decoder: other)
    )
    #expect(MMKVStore.CodedKey.count.name == "count")
    #expect("\(MMKVStore.CodedKey.score(3))" == "score.3")
  }

  @Test func `Stores The Value In The Form Its Encoder Gives It`() throws {
    let store = try makeStore()

    #expect(try store.value(for: .count) == nil)
    #expect(try store.set(42, for: .count))

    #expect(try store.value(for: .count) == 42)
    #expect(store["count", as: String.self] == "42")
    #expect(try store.decode(Int.self, forKey: "count", with: TextCoder.shared) == 42)
  }

  @Test func `Throws What Its Decoder Throws`() throws {
    let store = try makeStore()
    store.set("not a number", forKey: "count")

    #expect(throws: TextCoder.Failure.self) { try store.value(for: .count) }
  }

  @Test func `Throws What Its Encoder Throws And Stores Nothing`() throws {
    let store = try makeStore()

    #expect(throws: TextCoder.Failure.self) { try store.set([1, 2], for: .unencodable) }

    #expect(!store.contains(.unencodable))
  }

  @Test func `Contains And Removes Without Decoding`() throws {
    let store = try makeStore()
    store.set("not a number", forKey: "count")

    #expect(store.contains(.count))
    #expect(store.removeValue(for: .count))
    #expect(!store.contains(.count))
  }

  @Test func `A Value Can Expire`() throws {
    let store = try makeStore()

    #expect(try store.set(7, for: .count, expiringIn: .seconds(60)))

    #expect(try store.value(for: .count) == 7)
  }

  @Test func `Throws While The Store Is Suspended`() throws {
    let store = try makeStore(mode: .multiProcess)
    try store.set(1, for: .count)
    store.suspend()

    #expect(throws: MMKVError.storeIsSuspended(id: store.id)) { try store.value(for: .count) }
    #expect(throws: MMKVError.storeIsSuspended(id: store.id)) { try store.set(2, for: .count) }

    store.resume()
    #expect(try store.value(for: .count) == 1)
  }

  @Test func `Produces The Decoded Values Of A Key Over Time`() async throws {
    let store = try makeStore()
    try store.set(1, for: .count)
    var iterator = store.values(for: .count).makeAsyncIterator()

    #expect(try await iterator.next() == .some(1))
    try store.set(2, for: .count)
    #expect(try await iterator.next() == .some(2))
    store.removeValue(for: .count)
    #expect(try await iterator.next() == .some(nil))
  }

  @Test func `The Values End With The Error Of A Value That Does Not Decode`() async throws {
    let store = try makeStore()
    store.set("not a number", forKey: "count")
    var iterator = store.values(for: .count).makeAsyncIterator()

    await #expect(throws: TextCoder.Failure.self) { try await iterator.next() }

    try store.set(3, for: .count)
    #expect(try await iterator.next() == nil)
  }
}

@Suite struct MMKVStoreDefaultedCodedKeyTests {
  @Test func `Is Made From A Name Or A Key`() {
    #expect(MMKVStore.DefaultedCodedKey.countOrZero.key == .count)
    #expect(MMKVStore.DefaultedCodedKey.countOrZero.defaultValue == 0)
    #expect(MMKVStore.DefaultedCodedKey.lives.key.name == "lives")
    #expect(
      MMKVStore.DefaultedCodedKey.countOrZero == MMKVStore.DefaultedCodedKey(.count, default: 0)
    )
    #expect(
      MMKVStore.DefaultedCodedKey.countOrZero != MMKVStore.DefaultedCodedKey(.count, default: 1)
    )
  }

  @Test func `Reads The Default Until A Value Is Stored`() throws {
    let store = try makeStore()

    #expect(try store.value(for: .lives) == 3)
    #expect(!store.contains(.lives))
    #expect(store.keys.isEmpty)

    #expect(try store.set(5, for: .lives))

    #expect(try store.value(for: .lives) == 5)
    #expect(store.contains(.lives))
    #expect(store["lives", as: String.self] == "5")
  }

  @Test func `Stores A Value Equal To The Default`() throws {
    let store = try makeStore()

    try store.set(3, for: .lives)

    #expect(store.contains(.lives))
  }

  @Test func `Reads The Default Again Once Removed`() throws {
    let store = try makeStore()
    try store.set(5, for: .lives)

    #expect(store.removeValue(for: .lives))

    #expect(try store.value(for: .lives) == 3)
  }

  @Test func `Throws Rather Than Reading The Default For A Value That Does Not Decode`() throws {
    let store = try makeStore()
    store.set("not a number", forKey: "lives")

    #expect(throws: TextCoder.Failure.self) { try store.value(for: .lives) }
  }
}
