import SwiftMMKV
import Testing

extension MMKVStore.Key where Value == String {
  fileprivate static let username = Self("username")
  fileprivate static let theme = Self("theme")
}

extension MMKVStore.Key where Value == Double {
  fileprivate static let fontSize = Self("fontSize")
}

extension MMKVStore.DefaultedKey where Value == Double {
  fileprivate static let volume = Self("volume", default: 0.5)
}

extension MMKVStore.DefaultedKey where Value == Bool {
  fileprivate static let isMuted = Self("isMuted", default: false)
}

extension MMKVStore.DefaultedKey where Value == String {
  fileprivate static let language = Self("language", default: "en")
}

extension MMKVStore.CodedKey where Value == Int {
  fileprivate static let count = Self("count", encoder: TextCoder.shared, decoder: TextCoder.shared)
  fileprivate static let total = Self("total", encoder: TextCoder.shared, decoder: TextCoder.shared)
}

extension MMKVStore.CodedKey where Value == Double {
  fileprivate static let ratio = Self("ratio", encoder: TextCoder.shared, decoder: TextCoder.shared)
}

extension MMKVStore.DefaultedCodedKey where Value == Int {
  fileprivate static let lives = Self(
    "lives",
    default: 3,
    encoder: TextCoder.shared,
    decoder: TextCoder.shared
  )
  fileprivate static let level = Self(
    "level",
    default: 1,
    encoder: TextCoder.shared,
    decoder: TextCoder.shared
  )
}

/// Compares the values a subscription to several keys delivers.
private struct Row<each Value: Equatable & Sendable>: Equatable, Sendable {
  let values: (repeat each Value)

  init(_ values: repeat each Value) {
    self.values = (repeat each values)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    for (left, right) in repeat (each lhs.values, each rhs.values) {
      if left != right { return false }
    }
    return true
  }
}

@Suite struct MMKVStoreSubscribeToKeysTests {
  @Test func `Delivers The Values Of Its Keys At Once, And After Each Operation`() throws {
    let store = try makeStore()
    store.set(1.0, forKey: "a")
    let recorder = ValueRecorder<[String: Double]>()
    let subscription = store.subscribe(forKeys: ["a", "b"], as: Double.self, recorder.record)
    #expect(recorder.all == [["a": 1]])

    store.set(2.0, forKey: "b")
    store.set(3.0, forKey: "c")
    store.removeValue(forKey: "a")

    #expect(recorder.all == [["a": 1], ["a": 1, "b": 2], ["b": 2]])
    subscription.cancel()
  }

  @Test func `Runs Once For An Operation That Changes Several Of Its Keys`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<[String: Double]>()
    let subscription = store.subscribe(forKeys: ["a", "b"], as: Double.self, recorder.record)

    store.set(["a": 1.0, "b": 2.0, "c": 3.0])
    store.withExclusiveLock { store in
      store.set(4.0, forKey: "a")
      store.set(5.0, forKey: "b")
      store.set(6.0, forKey: "a")
    }
    store.removeValues(forKeys: ["a", "b"])

    #expect(recorder.all == [[:], ["a": 1, "b": 2], ["a": 6, "b": 5], [:]])
    subscription.cancel()
  }

  @Test func `Runs For An External Change`() throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)
    first.set("initial", forKey: "a")
    _ = second.value(forKey: "a", as: String.self)
    let recorder = ValueRecorder<[String: String]>()
    let subscription = second.subscribe(forKeys: ["a", "b"], as: String.self, recorder.record)

    first.set("changed", forKey: "a")
    second.checkForExternalChanges()

    #expect(recorder.all == [["a": "initial"], ["a": "changed"]])
    subscription.cancel()
  }

  @Test func `Stops When Cancelled`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<[String: Double]>()
    let subscription = store.subscribe(forKeys: ["a", "b"], as: Double.self, recorder.record)

    subscription.cancel()
    store.set(1.0, forKey: "a")

    #expect(recorder.all == [[:]])
  }

  @Test func `Decodes Each Key, With A Result Of Its Own`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<[String: Int?]>()
    let subscription = store.subscribe(
      forKeys: ["a", "b", "c"],
      as: Int.self,
      with: TextCoder.shared
    ) { results in
      recorder.record(results.mapValues(\.success))
    }
    #expect(recorder.all == [[:]])

    store.withExclusiveLock { store in
      store.set("1", forKey: "a")
      store.set("not a number", forKey: "b")
    }

    #expect(recorder.all == [[:], ["a": 1, "b": nil]])
    subscription.cancel()
  }

  @Test func `A Decoding Subscription Fails Every Key Of A Closed Store`() throws {
    let store = try makeStore()
    store.set("1", forKey: "a")
    let recorder = ValueRecorder<[String: MMKVError.Code?]>()
    let subscription = store.subscribe(
      forKeys: ["a", "b"],
      as: Int.self,
      with: TextCoder.shared
    ) { results in
      recorder.record(results.mapValues { ($0.failure as? MMKVError)?.code })
    }

    store.close()

    #expect(recorder.all == [["a": nil], ["a": .storeIsClosed, "b": .storeIsClosed]])
    subscription.cancel()
  }
}

@Suite struct MMKVStoreSubscribeToTypedKeysTests {
  @Test func `Delivers The Values Of Two Keys, Once For Each Operation`() throws {
    let store = try makeStore()
    store.set("blob", for: .username)
    let recorder = ValueRecorder<Row<String?, Double?>>()
    let subscription = store.subscribe(for: .username, .fontSize) { username, fontSize in
      recorder.record(Row(username, fontSize))
    }
    #expect(recorder.all == [Row("blob", nil)])

    store.withExclusiveLock { store in
      store.set("blob jr", for: .username)
      store.set(16, for: .fontSize)
    }
    store.set("unrelated", forKey: "other")
    store.removeValue(for: .username)

    #expect(recorder.all == [Row("blob", nil), Row("blob jr", 16), Row(nil, 16)])
    subscription.cancel()
  }

  @Test func `Delivers The Values Of Three Keys Written Together`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<Row<String?, String?, Double?>>()
    let subscription = store.subscribe(for: .username, .theme, .fontSize) {
      recorder.record(Row($0, $1, $2))
    }

    store.set((.username, "blob"), (.theme, "dark"))
    store.set(16, for: .fontSize)

    #expect(
      recorder.all == [Row(nil, nil, nil), Row("blob", "dark", nil), Row("blob", "dark", 16)]
    )
    subscription.cancel()
  }

  @Test func `A Single Key Still Delivers One Value`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<String?>()
    let subscription = store.subscribe(for: .username) { recorder.record($0) }

    store.set("blob", for: .username)

    #expect(recorder.all == [nil, "blob"])
    subscription.cancel()
  }

  @Test func `Delivers The Defaults Of Defaulted Keys`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<Row<Double, Bool, String>>()
    let subscription = store.subscribe(for: .volume, .isMuted, .language) {
      recorder.record(Row($0, $1, $2))
    }

    store.withExclusiveLock { store in
      store.set(0.8, for: .volume)
      store.set(true, for: .isMuted)
    }
    store.removeValue(for: .volume)

    #expect(
      recorder.all == [Row(0.5, false, "en"), Row(0.8, true, "en"), Row(0.5, true, "en")]
    )
    subscription.cancel()
  }

  @Test func `Delivers A Result For Each Coded Key`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<Row<Int?, Int?, Double?, Bool>>()
    let subscription = store.subscribe(for: .count, .total, .ratio) { count, total, ratio in
      recorder.record(
        Row(count.success ?? nil, total.success ?? nil, ratio.success ?? nil, total.failure != nil)
      )
    }

    try store.withExclusiveLock { store in
      try store.set(1, for: .count)
      try store.set(0.5, for: .ratio)
      store.set("not a number", forKey: "total")
    }

    #expect(recorder.all == [Row(nil, nil, nil, false), Row(1, nil, 0.5, true)])
    subscription.cancel()
  }

  @Test func `Delivers A Result For Each Defaulted Coded Key`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<Row<Int?, Int?>>()
    let subscription = store.subscribe(for: .lives, .level) { lives, level in
      recorder.record(Row(lives.success, level.success))
    }

    try store.set(1, for: .lives)
    store.set("not a number", forKey: "level")

    #expect(recorder.all == [Row(3, 1), Row(1, 1), Row(1, nil)])
    subscription.cancel()
  }

  @Test func `Typed Keys Run For An External Change`() throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)
    first.set("blob", for: .username)
    _ = second.value(for: .username)
    let recorder = ValueRecorder<Row<String?, String?>>()
    let subscription = second.subscribe(for: .username, .theme) {
      recorder.record(Row($0, $1))
    }

    first.set("dark", for: .theme)
    second.checkForExternalChanges()

    #expect(recorder.all == [Row("blob", nil), Row("blob", "dark")])
    subscription.cancel()
  }

  @Test func `Typed Keys Take Their Closure By Label`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<Row<String?, String?>>()
    let onChange: @Sendable (String?, String?) -> Void = { recorder.record(Row($0, $1)) }
    let subscription = store.subscribe(for: .username, .theme, onChange: onChange)

    subscription.cancel()
    store.set("blob", for: .username)

    #expect(recorder.all == [Row(nil, nil)])
  }
}
