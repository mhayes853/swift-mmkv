import SwiftMMKV
import Testing

extension MMKVStore.Key where Value == String {
  fileprivate static let username: Self = "username"
  fileprivate static func draft(_ id: Int) -> Self { "draft.\(id)" }
}

extension MMKVStore.Key where Value == Double {
  fileprivate static let volume: Self = "volume"
}

extension MMKVStore.DefaultedKey where Value == Double {
  fileprivate static let brightness = Self("brightness", default: 0.5)
}

extension MMKVStore.DefaultedKey where Value == String {
  fileprivate static let theme = Self("theme", default: "system")
}

extension MMKVStore.CodedKey where Value == Int {
  fileprivate static let count = Self("count", encoder: TextCoder.shared, decoder: TextCoder.shared)
}

extension MMKVStore.CodedKey where Value == Bool {
  fileprivate static let flag = Self("flag", encoder: TextCoder.shared, decoder: TextCoder.shared)
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
}

extension MMKVStore.DefaultedCodedKey where Value == Bool {
  fileprivate static let isMuted = Self(
    "isMuted",
    default: false,
    encoder: TextCoder.shared,
    decoder: TextCoder.shared
  )
}

@Suite struct MMKVTypedKeyBatchReadTests {
  @Test func `Reads The Values Of Several Keys Of Different Types`() throws {
    let store = try makeStore()
    store[.username] = "blob"
    store[.volume] = 0.8

    let (username, volume, draft) = store.values(forKeys: .username, .volume, .draft(1))

    #expect(username == "blob")
    #expect(volume == 0.8)
    #expect(draft == nil)
  }

  @Test func `Reads The Values Of Several String Keys As Their Own Types`() throws {
    let store = try makeStore()
    store.set("blob", forKey: "username")
    store.set(0.8, forKey: "volume")
    let key = "volume"

    let (username, volume, missing) = store.values(
      forKeys: ("username", String.self),
      (key, Double.self),
      ("missing", Bool.self)
    )

    #expect(username == "blob")
    #expect(volume == 0.8)
    #expect(missing == nil)
  }

  @Test func `Reads The Defaults Of Defaulted Keys Without Values`() throws {
    let store = try makeStore()
    store[.theme] = "dark"

    let (brightness, theme) = store.values(forKeys: .brightness, .theme)

    #expect(brightness == 0.5)
    #expect(theme == "dark")
  }

  @Test func `Reads And Decodes The Values Of Coded Keys`() throws {
    let store = try makeStore()
    try store.set(7, for: .count)

    let (count, flag) = try store.values(forKeys: .count, .flag)

    #expect(count == 7)
    #expect(flag == nil)
  }

  @Test func `Reading Coded Keys Throws For A Value That Does Not Decode`() throws {
    let store = try makeStore()
    try store.set(7, for: .count)
    store.set("not a boolean", forKey: "flag")

    #expect(throws: TextCoder.Failure.self) {
      _ = try store.values(forKeys: .count, .flag)
    }
  }

  @Test func `Reads The Defaults Of Defaulted Coded Keys Without Values`() throws {
    let store = try makeStore()
    try store.set(1, for: .lives)

    let (lives, isMuted) = try store.values(forKeys: .lives, .isMuted)

    #expect(lives == 1)
    #expect(isMuted == false)
  }

  @Test func `Reading Defaulted Coded Keys Throws For A Value That Does Not Decode`() throws {
    let store = try makeStore()
    store.set("not a number", forKey: "lives")

    #expect(throws: TextCoder.Failure.self) {
      _ = try store.values(forKeys: .lives, .isMuted)
    }
  }

  @Test func `A Suspended Store Reads No Values And Throws For Coded Keys`() throws {
    let store = try makeStore(mode: .multiProcess)
    store[.username] = "blob"
    store.suspend()

    let (username, volume) = store.values(forKeys: .username, .volume)
    let (brightness, theme) = store.values(forKeys: .brightness, .theme)

    #expect(username == nil && volume == nil)
    #expect(brightness == 0.5 && theme == "system")
    expectError(.storeIsSuspended) {
      _ = try store.values(forKeys: .count, .flag)
    }
  }
}

@Suite struct MMKVTypedKeyBatchWriteTests {
  @Test func `Stores The Values Of Several Keys Of Different Types`() throws {
    let store = try makeStore()

    let didStore = store.set((.username, "blob"), (.volume, 0.8), (.draft(1), "Hello"))

    #expect(didStore)
    #expect(store[.username] == "blob")
    #expect(store[.volume] == 0.8)
    #expect(store[.draft(1)] == "Hello")
  }

  @Test func `Stores The Values Of Several String Keys`() throws {
    let store = try makeStore()
    let key = "volume"

    let didStore = store.set(("username", "blob"), (MMKVStore.Key(key), 0.8))

    #expect(didStore)
    #expect(store.value(forKey: "username", as: String.self) == "blob")
    #expect(store.value(forKey: "volume", as: Double.self) == 0.8)
  }

  @Test func `Listeners Are Told About Every Key Once, After Every Value Is Written`() throws {
    let store = try makeStore()
    let changes = ChangeRecorder()
    let states = ValueRecorder<Set<String>>()
    let subscription = store.subscribe { batch in
      changes.record(batch)
      states.record(store.keys)
    }

    store.set((.username, "blob"), (.volume, 0.8))

    #expect(changes.batches == [[.key("username"), .key("volume")]])
    #expect(states.all == [["username", "volume"]])
    subscription.cancel()
  }

  @Test func `A Value That Cannot Be Stored Does Not Stop The Others`() throws {
    let store = try makeStore(itemSizeLimit: 32)

    let didStore = store.set((.username, String(repeating: "x", count: 64)), (.volume, 0.8))

    #expect(!didStore)
    #expect(store.keys == ["volume"])
  }

  @Test func `Stores The Values Of Defaulted Keys Even When They Equal The Default`() throws {
    let store = try makeStore()

    let didStore = store.set((.brightness, 0.5), (.theme, "dark"))

    #expect(didStore)
    #expect(store.contains(.brightness))
    #expect(store[.theme] == "dark")
  }

  @Test func `Stored Values Can Expire`() async throws {
    let store = try makeStore()

    store.set((.username, "blob"), (.volume, 0.8), expiry: .after(.seconds(1)))
    #expect(store[.username] == "blob")

    try await Task.sleep(for: .seconds(2.1))

    #expect(store.keys.isEmpty)
  }

  @Test func `Encodes And Stores The Values Of Coded Keys`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    let didStore = try store.set((.count, 7), (.flag, true))

    #expect(didStore)
    #expect(try store.value(for: .count) == 7)
    #expect(try store.value(for: .flag) == true)
    #expect(store.value(forKey: "count", as: String.self) == "7")
    #expect(recorder.all == [.key("count"), .key("flag")])
    subscription.cancel()
  }

  @Test func `Stores Nothing When A Coded Value Does Not Encode`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    #expect(throws: TextCoder.Failure.self) {
      try store.set((.count, 7), (.unencodable, [1, 2]), (.flag, true))
    }

    #expect(store.keys.isEmpty)
    #expect(recorder.all.isEmpty)
    subscription.cancel()
  }

  @Test func `Encodes And Stores The Values Of Defaulted Coded Keys`() throws {
    let store = try makeStore()

    let didStore = try store.set((.lives, 3), (.isMuted, true))

    #expect(didStore)
    #expect(store.contains(.lives))
    #expect(try store.value(for: .isMuted))
  }

  @Test func `A Suspended Store Stores Nothing And Throws For Coded Keys`() throws {
    let store = try makeStore(mode: .multiProcess)
    store.suspend()

    #expect(!store.set((.username, "blob"), (.volume, 0.8)))
    #expect(!store.set((.brightness, 0.5), (.theme, "dark")))
    expectError(.storeIsSuspended) {
      try store.set((.count, 7), (.flag, true))
    }
    expectError(.storeIsSuspended) {
      try store.set((.lives, 3), (.isMuted, true))
    }

    store.resume()
    #expect(store.keys.isEmpty)
  }
}
