import SwiftMMKV
import Testing

private struct Settings: Codable, Equatable, Sendable {
  var fontSize: Double
  var theme: String
}

extension MMKVStore.Key where Value == String {
  fileprivate static let username = Self("username")
}

extension MMKVStore.DefaultedKey where Value == Double {
  fileprivate static let volume = Self("volume", default: 0.5)
}

extension MMKVStore.CodedKey where Value == Int {
  fileprivate static let count = Self("count", encoder: TextCoder.shared, decoder: TextCoder.shared)
}

extension MMKVStore.DefaultedCodedKey where Value == Int {
  fileprivate static let lives = Self(
    "lives",
    default: 3,
    encoder: TextCoder.shared,
    decoder: TextCoder.shared
  )
}

@Suite struct MMKVStoreChangeBatchTests {
  @Test func `Each Write And Removal Is A Batch Of One Key`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    store.set("blob", forKey: "username")
    store.set(0.8, forKey: "volume")
    store.removeValue(forKey: "username")

    #expect(recorder.batches == [[.key("username")], [.key("volume")], [.key("username")]])
    subscription.cancel()
  }

  @Test func `Removing Several Keys Is One Batch, With A Repeated Key Once`() throws {
    let store = try makeStore()
    store.set(["a": 1.0, "b": 2.0, "c": 3.0])
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    store.removeValues(forKeys: ["a", "b", "a"])

    #expect(recorder.batches == [[.key("a"), .key("b")]])
    subscription.cancel()
  }

  @Test func `Removing Everything Is One Batch`() throws {
    let store = try makeStore()
    store.set(["a": 1.0, "b": 2.0, "c": 3.0])
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    store.removeAll()

    #expect(recorder.batches.map(Set.init) == [[.key("a"), .key("b"), .key("c")]])
    subscription.cancel()
  }

  @Test func `Encoding Into Keys Is One Batch`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    try store.encode(Settings(fontSize: 16, theme: "dark"), intoKeysUnder: "settings")

    #expect(
      recorder.batches.map(Set.init) == [[.key("settings.fontSize"), .key("settings.theme")]]
    )
    subscription.cancel()
  }

  @Test func `Importing Is One Batch`() throws {
    let source = try makeStore()
    source.set(["a": 1.0, "b": 2.0])
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    store.importAll(from: source)

    #expect(recorder.batches.map(Set.init) == [[.key("a"), .key("b")]])
    subscription.cancel()
  }

  @Test func `A Locked Body Is One Batch, With Each Key Once In The Order It First Changed`()
    throws
  {
    let store = try makeStore()
    store.set(1.0, forKey: "c")
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    store.withExclusiveLock { store in
      store.set(1.0, forKey: "b")
      store.set(1.0, forKey: "a")
      store.set(2.0, forKey: "b")
      store.withExclusiveLock { store in
        store.removeValue(forKey: "c")
      }
    }

    #expect(recorder.batches == [[.key("b"), .key("a"), .key("c")]])
    subscription.cancel()
  }

  @Test func `A Locked Body That Changes Nothing Is No Batch`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    store.withExclusiveLock { store in
      _ = store.value(forKey: "a", as: Double.self)
    }

    #expect(recorder.batches.isEmpty)
    subscription.cancel()
  }

  @Test func `An External Change Is A Batch With No Keys`() throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)
    first.set("initial", forKey: "a")
    _ = second.value(forKey: "a", as: String.self)
    let recorder = ValueRecorder<MMKVStore.ChangeBatch>()
    let subscription = second.subscribe(recorder.record)

    first.set("changed", forKey: "a")
    second.checkForExternalChanges()

    #expect(recorder.all.map(\.keys) == [[]])
    #expect(recorder.all.map(\.isExternal) == [true])
    subscription.cancel()
  }

  @Test func `A Batch Made Through This Package Is Not External`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<MMKVStore.ChangeBatch>()
    let subscription = store.subscribe(recorder.record)

    store.set(1.0, forKey: "a")

    #expect(recorder.all.map(\.isExternal) == [false])
    subscription.cancel()
  }

  @Test func `Every Store Over The Same Files Is Given The Batch`() throws {
    let (id, rootDirectory) = (MMKVStore.ID("shared-batch"), temporaryRootDirectory())
    let first = try makeStore(id: id, rootDirectory: rootDirectory)
    let second = try makeStore(id: id, rootDirectory: rootDirectory)
    let recorder = ChangeRecorder()
    let values = ValueRecorder<[String: Double]>()
    let subscription = second.subscribe { batch in
      recorder.record(batch)
      values.record(second.values(forKeys: batch.keys, as: Double.self))
    }

    first.set(["a": 1.0, "b": 2.0])

    #expect(recorder.batches.map(Set.init) == [[.key("a"), .key("b")]])
    #expect(values.all == [["a": 1, "b": 2]])
    subscription.cancel()
  }
}

@Suite struct MMKVStoreChangeBatchKeySubscriptionTests {
  @Test func `A Key's Batch Holds That Key Alone`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(forKey: "a", recorder.record)

    store.set(["a": 1.0, "b": 2.0, "c": 3.0])
    store.set(1.0, forKey: "b")

    #expect(recorder.batches == [[.key("a")]])
    subscription.cancel()
  }

  @Test func `A Key Subscription Runs Once For A Locked Body That Writes The Key Twice`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(forKey: "a", recorder.record)

    store.withExclusiveLock { store in
      store.set(1.0, forKey: "a")
      store.set(2.0, forKey: "a")
    }

    #expect(recorder.batches == [[.key("a")]])
    subscription.cancel()
  }

  @Test func `A Key's Batch Has No Keys For An External Change`() throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)
    first.set("initial", forKey: "b")
    _ = second.value(forKey: "b", as: String.self)
    let recorder = ChangeRecorder()
    let subscription = second.subscribe(forKey: "a", recorder.record)

    first.set("changed", forKey: "b")
    second.checkForExternalChanges()

    #expect(recorder.batches == [[.external]])
    subscription.cancel()
  }

  @Test func `A Prefix's Batch Holds Only The Keys At Or Under It`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(underKey: "settings", recorder.record)

    store.withExclusiveLock { store in
      store.set("blob", forKey: "username")
      store.set("dark", forKey: "settings.theme")
      store.set(true, forKey: "settingsLoaded")
      store.set(1.0, forKey: "settings")
      store.set(16.0, forKey: "settings.font.size")
    }
    store.set("blob", forKey: "username")

    #expect(
      recorder.batches == [[.key("settings.theme"), .key("settings"), .key("settings.font.size")]]
    )
    subscription.cancel()
  }

  @Test func `A Prefix's Batch Goes By Its Separator`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(underKey: "a", separator: "/", recorder.record)

    store.set(["a.b": 1.0, "a/b": 2.0])

    #expect(recorder.batches == [[.key("a/b")]])
    subscription.cancel()
  }
}

@Suite struct MMKVStoreChangeBatchValueTests {
  @Test func `Reads The Values Of Its Keys`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<[String?]>()
    let subscription = store.subscribe { batch in
      recorder.record(batch.keys.map { batch.value(forKey: $0, as: String.self) })
    }

    store.withExclusiveLock { store in
      store.set("blob", forKey: "username")
      store.set("dark", forKey: "theme")
    }
    store.removeValue(forKey: "theme")

    #expect(recorder.all == [["blob", "dark"], [nil]])
    subscription.cancel()
  }

  @Test func `Reads Any Key Of The Store, And The Value It Holds Now`() throws {
    let store = try makeStore()
    store.set("dark", forKey: "theme")
    let batch = MMKVStore.ChangeBatch(store: store, keys: ["username"])

    store.set("light", forKey: "theme")

    #expect(batch.keys == ["username"])
    #expect(!batch.isExternal)
    #expect(batch.value(forKey: "theme", as: String.self) == "light")
    #expect(batch.value(forKey: "username", as: String.self) == nil)
  }

  @Test func `Reads Typed Keys`() throws {
    let store = try makeStore()
    let batch = MMKVStore.ChangeBatch(store: store, keys: [], isExternal: true)
    #expect(batch.isExternal)
    #expect(batch.value(for: .username) == nil)
    #expect(batch.value(for: .volume) == 0.5)

    store.set("blob", for: .username)
    store.set(0.8, for: .volume)

    #expect(batch.value(for: .username) == "blob")
    #expect(batch.value(for: .volume) == 0.8)
  }

  @Test func `Reads Coded Keys`() throws {
    let store = try makeStore()
    let batch = MMKVStore.ChangeBatch(store: store, keys: [])
    #expect(try batch.value(for: .count) == nil)
    #expect(try batch.value(for: .lives) == 3)

    try store.set(7, for: .count)
    try store.set(1, for: .lives)

    #expect(try batch.value(for: .count) == 7)
    #expect(try batch.value(for: .lives) == 1)
  }

  @Test func `Throws What A Coded Key's Decoder Throws`() throws {
    let store = try makeStore()
    let batch = MMKVStore.ChangeBatch(store: store, keys: [])
    store.set("not a number", forKey: "count")
    store.set("not a number", forKey: "lives")

    #expect(throws: TextCoder.Failure.self) { try batch.value(for: .count) }
    #expect(throws: TextCoder.Failure.self) { try batch.value(for: .lives) }
  }

  @Test func `Decodes With A Decoder`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<Int?>()
    let subscription = store.subscribe { batch in
      recorder.record(try? batch.decode(Int.self, forKey: "count", with: TextCoder.shared))
    }

    try store.encode(7, forKey: "count", with: TextCoder.shared)
    store.set("not a number", forKey: "count")
    store.removeValue(forKey: "count")

    #expect(recorder.all == [7, nil, nil])
    subscription.cancel()
  }

  @Test func `Decodes From The Keys Under A Prefix`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<Settings?>()
    let subscription = store.subscribe(underKey: "settings") { batch in
      recorder.record(try? batch.decode(Settings.self, fromKeysUnder: "settings"))
    }

    try store.encode(Settings(fontSize: 16, theme: "dark"), intoKeysUnder: "settings")
    store.removeValue(forKey: "settings.theme")

    #expect(recorder.all == [Settings(fontSize: 16, theme: "dark"), nil])
    subscription.cancel()
  }

  @Test func `Decodes From The Keys Under A Prefix With Options`() throws {
    let store = try makeStore()
    let options = MMKVKeyCodingOptions(separator: "/")
    let batch = MMKVStore.ChangeBatch(store: store, keys: [])

    try store.encode(
      Settings(fontSize: 16, theme: "dark"),
      intoKeysUnder: "settings",
      options: options
    )

    #expect(
      try batch.decode(Settings.self, fromKeysUnder: "settings", options: options)
        == Settings(fontSize: 16, theme: "dark")
    )
    #expect(throws: (any Error).self) {
      try batch.decode(Settings.self, fromKeysUnder: "settings")
    }
  }

  @Test func `Reads Of A Closed Store Are Turned Away`() throws {
    let store = try makeStore()
    store.set("blob", forKey: "username")
    let batch = MMKVStore.ChangeBatch(store: store, keys: ["username"])

    store.close()

    #expect(batch.value(forKey: "username", as: String.self) == nil)
    #expect(batch.value(for: .username) == nil)
    #expect(throws: MMKVError.self) { try batch.value(for: .count) }
    #expect(throws: MMKVError.self) {
      try batch.decode(Int.self, forKey: "count", with: TextCoder.shared)
    }
    #expect(throws: MMKVError.self) {
      try batch.decode(Settings.self, fromKeysUnder: "settings")
    }
  }
}
