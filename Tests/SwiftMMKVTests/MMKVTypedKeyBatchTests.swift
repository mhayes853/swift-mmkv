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
    #expect(throws: MMKVError.storeIsSuspended(id: store.id)) {
      _ = try store.values(forKeys: .count, .flag)
    }
  }
}
