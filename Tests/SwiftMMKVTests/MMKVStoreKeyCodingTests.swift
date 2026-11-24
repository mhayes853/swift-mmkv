import SwiftMMKV
import Testing

private struct Sync: Codable, Equatable {
  var isEnabled: Bool
  var interval: Int
}

private struct Settings: Codable, Equatable {
  var fontSize: Double
  var theme: String?
  var sync: Sync
}

private enum Theme: String, Codable {
  case light, dark
}

private struct Numbers: Codable, Equatable {
  var int: Int
  var small: Int8
  var unsigned: UInt64
  var float: Float
}

private struct Profile: Codable, Equatable {
  var theme: Theme
  var avatar: [UInt8]
  var scores: [String: Int]
}

private struct Tags: Codable, Equatable {
  var tags: [String]
}

private struct Points: Codable, Equatable {
  var points: [Sync]
}

/// Removes its key when the theme is `nil`, which a compiler-written conformance does not.
private struct ExplicitNil: Encodable {
  var theme: String?

  enum CodingKeys: CodingKey { case theme }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.theme, forKey: .theme)
  }
}

private let settings = Settings(
  fontSize: 16,
  theme: "dark",
  sync: Sync(isEnabled: true, interval: 30)
)

@Suite struct MMKVStoreKeyEncodingTests {
  @Test func `Stores Each Property Under Its Own Key`() throws {
    let store = try makeStore()

    #expect(try store.encode(settings, intoKeysUnder: "settings"))

    #expect(
      store.keys == [
        "settings.fontSize", "settings.theme", "settings.sync.isEnabled", "settings.sync.interval"
      ]
    )
    #expect(store.value(forKey: "settings.fontSize", as: Double.self) == 16)
    #expect(store.value(forKey: "settings.theme", as: String.self) == "dark")
    #expect(store.value(forKey: "settings.sync.isEnabled", as: Bool.self) == true)
  }

  @Test func `Stores Integers As Doubles By Default`() throws {
    let store = try makeStore()

    try store.encode(settings, intoKeysUnder: "settings")

    #expect(store.value(forKey: "settings.sync.interval", as: Double.self) == 30)
  }

  @Test func `Stores Numbers In Their Own Form When Asked`() throws {
    let store = try makeStore()
    let numbers = Numbers(int: -5, small: 7, unsigned: .max, float: 1.5)
    let options = MMKVKeyCodingOptions(numbers: .native)

    try store.encode(numbers, intoKeysUnder: "n", options: options)

    #expect(store.value(forKey: "n.int", as: Int64.self) == -5)
    #expect(store.value(forKey: "n.small", as: Int32.self) == 7)
    #expect(store.value(forKey: "n.unsigned", as: UInt64.self) == .max)
    #expect(store.value(forKey: "n.float", as: Float.self) == 1.5)
    #expect(try store.decode(Numbers.self, fromKeysUnder: "n", options: options) == numbers)
  }

  @Test func `Refuses An Integer A Double Cannot Hold`() throws {
    let store = try makeStore()
    let numbers = Numbers(int: 1, small: 1, unsigned: .max, float: 1)

    #expect(throws: EncodingError.self) { try store.encode(numbers, intoKeysUnder: "n") }
    #expect(store.keys.isEmpty)
  }

  @Test func `An Empty Prefix Stores Top Level Keys`() throws {
    let store = try makeStore()

    try store.encode(settings, intoKeysUnder: "")

    #expect(store.keys == ["fontSize", "theme", "sync.isEnabled", "sync.interval"])
    #expect(try store.decode(Settings.self, fromKeysUnder: "") == settings)
  }

  @Test func `Uses The Separator`() throws {
    let store = try makeStore()
    let options = MMKVKeyCodingOptions(separator: "/")

    try store.encode(settings, intoKeysUnder: "settings", options: options)

    #expect(store.contains("settings/sync/isEnabled"))
    #expect(
      try store.decode(Settings.self, fromKeysUnder: "settings", options: options) == settings
    )
  }

  @Test func `Stores A Single Value Under The Prefix`() throws {
    let store = try makeStore()

    try store.encode(Theme.dark, intoKeysUnder: "theme")

    #expect(store.value(forKey: "theme", as: String.self) == "dark")
    #expect(try store.decode(Theme.self, fromKeysUnder: "theme") == .dark)
  }

  @Test func `Removes The Key Of A Skipped Nil Property`() throws {
    let store = try makeStore()
    try store.encode(settings, intoKeysUnder: "settings")
    store.set("kept", forKey: "settingsBackup")
    var changed = settings
    changed.theme = nil

    try store.encode(changed, intoKeysUnder: "settings")

    #expect(!store.contains("settings.theme"))
    #expect(store.contains("settingsBackup"))
    #expect(try store.decode(Settings.self, fromKeysUnder: "settings") == changed)
  }

  @Test func `Leaves Other Keys When Asked`() throws {
    let store = try makeStore()
    try store.encode(settings, intoKeysUnder: "settings")
    store.set("kept", forKey: "settings.unrelated")
    var changed = settings
    changed.theme = nil

    try store.encode(changed, intoKeysUnder: "settings", removingOtherKeys: false)

    #expect(store.value(forKey: "settings.theme", as: String.self) == "dark")
    #expect(store.contains("settings.unrelated"))
  }

  @Test func `An Empty Prefix Removes Every Other Key In The Store`() throws {
    let store = try makeStore()
    store.set(true, forKey: "hasOnboarded")
    store.set("abc", forKey: "auth.token")

    try store.encode(ExplicitNil(theme: "dark"), intoKeysUnder: "")

    #expect(store.keys == ["theme"])
  }

  @Test func `An Empty Prefix Leaves Other Keys When Asked`() throws {
    let store = try makeStore()
    store.set(true, forKey: "hasOnboarded")
    store.set("abc", forKey: "auth.token")

    try store.encode(ExplicitNil(theme: "dark"), intoKeysUnder: "", removingOtherKeys: false)

    #expect(store.keys == ["hasOnboarded", "auth.token", "theme"])
  }

  @Test func `Several Values Remove The Keys None Of Them Wrote`() throws {
    let store = try makeStore()
    try store.encode(settings, intoKeysUnder: "settings")
    try store.encode(settings, intoKeysUnder: "draft")
    store.set("kept", forKey: "other")
    var changed = settings
    changed.theme = nil

    try store.encode(intoKeysUnder: ("settings", changed), ("draft", changed))

    #expect(!store.contains("settings.theme"))
    #expect(!store.contains("draft.theme"))
    #expect(store.contains("other"))
  }

  @Test func `An Encoded Nil Removes Its Key`() throws {
    let store = try makeStore()
    try store.encode(ExplicitNil(theme: "dark"), intoKeysUnder: "settings")

    try store.encode(ExplicitNil(theme: nil), intoKeysUnder: "settings")

    #expect(store.keys.isEmpty)
  }

  @Test func `Encoding Nil Removes Every Key Under The Prefix`() throws {
    let store = try makeStore()
    try store.encode(settings, intoKeysUnder: "settings")
    store.set("kept", forKey: "other")

    try store.encode(Settings?.none, intoKeysUnder: "settings")

    #expect(store.keys == ["other"])
  }

  @Test func `Stores Bytes Raw Enums And Dictionaries`() throws {
    let store = try makeStore()
    let profile = Profile(theme: .dark, avatar: [1, 2, 3], scores: ["a": 1, "b": 2])

    try store.encode(profile, intoKeysUnder: "profile")

    #expect(store.value(forKey: "profile.theme", as: String.self) == "dark")
    #expect(store.value(forKey: "profile.avatar", as: [UInt8].self) == [1, 2, 3])
    #expect(store.value(forKey: "profile.scores.b", as: Double.self) == 2)
    #expect(try store.decode(Profile.self, fromKeysUnder: "profile") == profile)
  }

  @Test func `Tells Listeners About Each Key Once`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    try store.encode(settings, intoKeysUnder: "settings")

    #expect(
      Set(recorder.all) == [
        .key("settings.fontSize"), .key("settings.theme"), .key("settings.sync.isEnabled"),
        .key("settings.sync.interval")
      ]
    )
    #expect(recorder.all.count == 4)
    subscription.cancel()
  }

  @Test func `Throws While The Store Is Suspended`() throws {
    let store = try makeStore(mode: .multiProcess)
    store.suspend()

    expectError(.storeIsSuspended) {
      try store.encode(settings, intoKeysUnder: "settings")
    }
    expectError(.storeIsSuspended) {
      try store.decode(Settings.self, fromKeysUnder: "settings")
    }
  }
}

@Suite struct MMKVStoreKeyDecodingTests {
  @Test func `Reads What Was Encoded`() throws {
    let store = try makeStore()
    try store.encode(settings, intoKeysUnder: "settings")

    #expect(try store.decode(Settings.self, fromKeysUnder: "settings") == settings)
  }

  @Test func `Reads Keys Written One By One`() throws {
    let store = try makeStore()
    store.set(12.0, forKey: "settings.fontSize")
    store.set(false, forKey: "settings.sync.isEnabled")
    store.set(60.0, forKey: "settings.sync.interval")

    let decoded = try store.decode(Settings.self, fromKeysUnder: "settings")

    #expect(
      decoded == Settings(fontSize: 12, theme: nil, sync: Sync(isEnabled: false, interval: 60))
    )
  }

  @Test func `Throws For A Missing Key`() throws {
    let store = try makeStore()
    store.set(12.0, forKey: "settings.fontSize")

    #expect {
      try store.decode(Settings.self, fromKeysUnder: "settings")
    } throws: { error in
      guard case DecodingError.keyNotFound(let key, _) = error else { return false }
      return key.stringValue == "isEnabled"
    }
  }

  @Test func `Throws For A Number That Is Not An Integer`() throws {
    let store = try makeStore()
    store.set(true, forKey: "sync.isEnabled")
    store.set(1.5, forKey: "sync.interval")

    #expect {
      try store.decode(Sync.self, fromKeysUnder: "sync")
    } throws: { error in
      if case DecodingError.dataCorrupted = error { true } else { false }
    }
  }

  @Test func `An Optional Is Nil When No Key Is Under The Prefix`() throws {
    let store = try makeStore()
    store.set("unrelated", forKey: "settingsBackup")

    #expect(try store.decode(Settings?.self, fromKeysUnder: "settings") == nil)

    try store.encode(settings, intoKeysUnder: "settings")
    #expect(try store.decode(Settings?.self, fromKeysUnder: "settings") == settings)
  }

  @Test func `Reads A Dictionary Of Values`() throws {
    let store = try makeStore()
    let syncs = [
      "home": Sync(isEnabled: true, interval: 1), "work": Sync(isEnabled: false, interval: 2)
    ]

    try store.encode(syncs, intoKeysUnder: "syncs")

    #expect(store.contains("syncs.home.isEnabled"))
    #expect(try store.decode([String: Sync].self, fromKeysUnder: "syncs") == syncs)
  }

  @Test func `Stores Arrays Of Strings Natively When Asked`() throws {
    let store = try makeStore()
    let options = MMKVKeyCodingOptions(arrays: .native)
    let tags = Tags(tags: ["a", "b"])

    try store.encode(tags, intoKeysUnder: "t", options: options)

    #expect(store.value(forKey: "t.tags", as: [String].self) == ["a", "b"])
    #expect(try store.decode(Tags.self, fromKeysUnder: "t", options: options) == tags)
  }

  @Test func `Refuses Other Arrays Without A Coder`() throws {
    let store = try makeStore()
    let options = MMKVKeyCodingOptions(arrays: .native)
    let points = Points(points: [Sync(isEnabled: true, interval: 1)])

    #expect(throws: EncodingError.self) {
      try store.encode(points, intoKeysUnder: "p", options: options)
    }
    #expect(store.keys.isEmpty)
    #expect(throws: DecodingError.self) {
      try store.decode(Points.self, fromKeysUnder: "p", options: options)
    }
  }

  @Test func `Stores Arrays With A Coder`() throws {
    let store = try makeStore()
    let options = MMKVKeyCodingOptions(
      arrays: .coded(encoder: CountingCoder(), decoder: CountingCoder())
    )

    try store.encode(Tags(tags: ["a", "b", "c"]), intoKeysUnder: "t", options: options)

    #expect(store.value(forKey: "t.tags", as: String.self) == "3 elements")
  }
}

#if Foundation
  import Foundation

  @Suite struct MMKVStoreKeyCodingJSONTests {
    @Test func `Stores Arrays As JSON Strings`() throws {
      let store = try makeStore()
      let tags = Tags(tags: ["a", "b"])

      try store.encode(tags, intoKeysUnder: "t")

      #expect(store.value(forKey: "t.tags", as: String.self) == #"["a","b"]"#)
      #expect(store.keys == ["t.tags"])
      #expect(try store.decode(Tags.self, fromKeysUnder: "t") == tags)
    }

    @Test func `Stores Arrays Of Values As JSON Strings`() throws {
      let store = try makeStore()
      let points = Points(points: [Sync(isEnabled: true, interval: 1)])

      try store.encode(points, intoKeysUnder: "p")

      #expect(store.keys == ["p.points"])
      #expect(try store.decode(Points.self, fromKeysUnder: "p") == points)
    }

    @Test func `Reads An Array Written As JSON`() throws {
      let store = try makeStore()
      store.set(#"[{"isEnabled":false,"interval":9}]"#, forKey: "p.points")

      let decoded = try store.decode(Points.self, fromKeysUnder: "p")

      #expect(decoded == Points(points: [Sync(isEnabled: false, interval: 9)]))
    }

    @Test func `Stores An Array As The Whole Value`() throws {
      let store = try makeStore()

      try store.encode([1, 2, 3], intoKeysUnder: "list")

      #expect(store.value(forKey: "list", as: String.self) == "[1,2,3]")
      #expect(try store.decode([Int].self, fromKeysUnder: "list") == [1, 2, 3])
    }

    @Test func `Stores Foundation Values As They Are Stored Alone`() throws {
      struct Account: Codable, Equatable {
        var id: UUID
        var homepage: URL
        var balance: Decimal
        var backup: URL?
      }
      let store = try makeStore()
      let account = Account(
        id: UUID(),
        homepage: URL(string: "https://example.com/me")!,
        balance: Decimal(string: "12.50")!,
        backup: nil
      )

      try store.encode(account, intoKeysUnder: "account")

      #expect(store.keys == ["account.id", "account.homepage", "account.balance"])
      #expect(store.value(forKey: "account.id", as: String.self) == account.id.uuidString)
      #expect(store.value(forKey: "account.homepage", as: String.self) == "https://example.com/me")
      #expect(store.value(forKey: "account.balance", as: String.self) == "12.5")
      #expect(try store.decode(Account.self, fromKeysUnder: "account") == account)
    }

    @Test func `Reads A Decimal From A Number`() throws {
      let store = try makeStore()
      store.set(0.1, forKey: "price")

      #expect(try store.decode(Decimal.self, fromKeysUnder: "price") == Decimal(string: "0.1"))
    }

    @Test func `Throws For A Value That Is Not Valid`() throws {
      let store = try makeStore()
      store.set("not a uuid", forKey: "id")

      #expect {
        try store.decode(UUID.self, fromKeysUnder: "id")
      } throws: { error in
        if case DecodingError.dataCorrupted = error { true } else { false }
      }
    }

    @Test func `Stores Data As Bytes`() throws {
      let store = try makeStore()

      try store.encode(["blob": Data([1, 2])], intoKeysUnder: "d")

      #expect(store.value(forKey: "d.blob", as: [UInt8].self) == [1, 2])
      #expect(try store.decode([String: Data].self, fromKeysUnder: "d") == ["blob": Data([1, 2])])
    }
  }
#endif

@Suite struct MMKVStoreKeyCodingBatchTests {
  private let sync = Sync(isEnabled: false, interval: 5)

  @Test func `Stores And Reads Several Values`() throws {
    let store = try makeStore()

    #expect(try store.encode(intoKeysUnder: ("settings", settings), ("sync", self.sync)))

    #expect(store.value(forKey: "settings.theme", as: String.self) == "dark")
    #expect(store.value(forKey: "sync.interval", as: Double.self) == 5)
    let (decodedSettings, decodedSync, missing) = try store.decode(
      fromKeysUnder: ("settings", Settings.self),
      ("sync", Sync.self),
      ("missing", Sync?.self)
    )
    #expect(decodedSettings == settings)
    #expect(decodedSync == self.sync)
    #expect(missing == nil)
  }

  @Test func `Stores Nothing When One Value Does Not Encode`() throws {
    let store = try makeStore()
    let numbers = Numbers(int: 1, small: 1, unsigned: .max, float: 1)

    #expect(throws: EncodingError.self) {
      try store.encode(intoKeysUnder: ("settings", settings), ("numbers", numbers))
    }
    #expect(store.keys.isEmpty)
  }

  @Test func `A Later Value Wins A Key`() throws {
    let store = try makeStore()

    try store.encode(intoKeysUnder: ("settings.sync", self.sync), ("settings", settings))

    #expect(try store.decode(Settings.self, fromKeysUnder: "settings") == settings)
  }

  @Test func `Removes Other Keys Under Every Prefix`() throws {
    let store = try makeStore()
    for key in ["settings.old", "settings.sync.old", "sync.old", "other.old"] {
      store.set("stale", forKey: key)
    }

    try store.encode(
      intoKeysUnder: ("settings", settings),
      ("settings.sync", self.sync),
      ("sync", self.sync),
      removingOtherKeys: true
    )

    #expect(
      store.keys == [
        "settings.fontSize", "settings.theme", "settings.sync.isEnabled",
        "settings.sync.interval", "sync.isEnabled", "sync.interval", "other.old"
      ]
    )
    #expect(try store.decode(Sync.self, fromKeysUnder: "settings.sync") == self.sync)
  }

  @Test func `Uses The Options For Every Value`() throws {
    let store = try makeStore()
    let options = MMKVKeyCodingOptions(separator: "/", numbers: .native)

    try store.encode(intoKeysUnder: ("a", self.sync), ("b", self.sync), options: options)

    #expect(store.value(forKey: "a/interval", as: Int64.self) == 5)
    let (a, b) = try store.decode(
      fromKeysUnder: ("a", Sync.self),
      ("b", Sync.self),
      options: options
    )
    #expect(a == self.sync && b == self.sync)
  }

  @Test func `Tells Listeners About Each Key Once`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    try store.encode(intoKeysUnder: ("a", self.sync), ("a", self.sync))

    #expect(recorder.all == [.key("a.isEnabled"), .key("a.interval")])
    subscription.cancel()
  }

  @Test func `Throws For A Missing Key Of Any Value`() throws {
    let store = try makeStore()
    try store.encode(settings, intoKeysUnder: "settings")

    #expect(throws: DecodingError.self) {
      try store.decode(fromKeysUnder: ("settings", Settings.self), ("sync", Sync.self))
    }
  }

  @Test func `Throws While The Store Is Suspended`() throws {
    let store = try makeStore(mode: .multiProcess)
    store.suspend()

    expectError(.storeIsSuspended) {
      try store.encode(intoKeysUnder: ("a", self.sync), ("b", self.sync))
    }
    expectError(.storeIsSuspended) {
      try store.decode(fromKeysUnder: ("a", Sync.self), ("b", Sync.self))
    }
  }
}

@Suite struct MMKVStoreKeysUnderKeyTests {
  @Test func `Returns A Key And The Keys Under It`() throws {
    let store = try makeStore()
    for key in ["settings", "settings.theme", "settings.sync.interval", "settingsBackup", "other"] {
      store.set("value", forKey: key)
    }

    #expect(
      store.keys(underKey: "settings") == ["settings", "settings.theme", "settings.sync.interval"]
    )
  }

  @Test func `Returns Nothing When No Key Is Under The Prefix`() throws {
    let store = try makeStore()
    store.set("value", forKey: "settingsBackup")

    #expect(store.keys(underKey: "settings").isEmpty)
  }

  @Test func `An Empty Prefix Returns Every Key`() throws {
    let store = try makeStore()
    store.set("value", forKey: "a.x")
    store.set("value", forKey: "b")

    #expect(store.keys(underKey: "") == ["a.x", "b"])
  }

  @Test func `Uses The Separator`() throws {
    let store = try makeStore()
    store.set("value", forKey: "a/x")
    store.set("value", forKey: "a.x")

    #expect(store.keys(underKey: "a", separator: "/") == ["a/x"])
  }

  @Test func `Returns The Keys A Value Was Encoded Into`() throws {
    let store = try makeStore()
    store.set(true, forKey: "hasOnboarded")
    try store.encode(settings, intoKeysUnder: "settings")

    #expect(
      store.keys(underKey: "settings") == [
        "settings.fontSize", "settings.theme", "settings.sync.isEnabled", "settings.sync.interval"
      ]
    )
  }

  @Test func `Is Empty While The Store Is Suspended`() throws {
    let store = try makeStore(mode: .multiProcess)
    store.set("value", forKey: "a.x")
    store.suspend()

    #expect(store.keys(underKey: "a").isEmpty)
    store.resume()
    #expect(store.keys(underKey: "a") == ["a.x"])
  }
}

@Suite struct MMKVStoreSubscribeUnderKeyTests {
  @Test func `Runs For A Key And The Keys Under It`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<Int>()
    let subscription = store.subscribe(underKey: "settings") { recorder.record(0) }

    store.set("value", forKey: "settings")
    store.set("value", forKey: "settings.theme")
    store.set("value", forKey: "settings.sync.interval")
    store.set("value", forKey: "settingsBackup")
    store.set("value", forKey: "other")
    #expect(recorder.all.count == 3)

    store.removeValue(forKey: "settings.theme")
    store.removeValue(forKey: "other")
    #expect(recorder.all.count == 4)
    subscription.cancel()
  }

  @Test func `An Empty Prefix Runs For Every Key`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<Int>()
    let subscription = store.subscribe(underKey: "") { recorder.record(0) }

    store.set("value", forKey: "a.x")
    store.set("value", forKey: "b")

    #expect(recorder.all.count == 2)
    subscription.cancel()
  }

  @Test func `Uses The Separator`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<Int>()
    let subscription = store.subscribe(underKey: "a", separator: "/") { recorder.record(0) }

    store.set("value", forKey: "a.x")
    store.set("value", forKey: "a/x")

    #expect(recorder.all.count == 1)
    subscription.cancel()
  }

  @Test func `Runs Once For Each Key Of An Encoded Value, After All Are Written`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<Settings?>()
    let subscription = store.subscribe(underKey: "settings") {
      recorder.record(try? store.decode(Settings.self, fromKeysUnder: "settings"))
    }

    try store.encode(settings, intoKeysUnder: "settings")
    try store.encode(settings, intoKeysUnder: "profile")

    #expect(recorder.all == [settings, settings, settings, settings])
    subscription.cancel()
  }

  @Test func `Runs For An External Change`() throws {
    let store = try makeStore(mode: .multiProcess)
    let recorder = ValueRecorder<Int>()
    let subscription = store.subscribe(underKey: "settings") { recorder.record(0) }

    store.suspend()
    store.resume()

    #expect(recorder.all.count == 1)
    subscription.cancel()
  }

  @Test func `Stops When Cancelled`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<Int>()
    let subscription = store.subscribe(underKey: "a") { recorder.record(0) }

    subscription.cancel()
    store.set("value", forKey: "a.x")

    #expect(recorder.all.isEmpty)
  }
}

@Suite struct MMKVStoreKeyRemovalTests {
  @Test func `Removes A Key And The Keys Under It`() throws {
    let store = try makeStore()
    for key in ["settings", "settings.theme", "settings.sync.interval", "settingsBackup", "other"] {
      store.set("value", forKey: key)
    }

    store.removeValues(underKey: "settings")

    #expect(store.keys == ["settingsBackup", "other"])
  }

  @Test func `Removes Under Several Keys`() throws {
    let store = try makeStore()
    for key in ["a.x", "b.y", "c.z"] {
      store.set("value", forKey: key)
    }

    store.removeValues(underKeys: ["a", "b"])

    #expect(store.keys == ["c.z"])
  }

  @Test func `Uses The Separator`() throws {
    let store = try makeStore()
    store.set("value", forKey: "a/x")
    store.set("value", forKey: "a.x")

    store.removeValues(underKey: "a", separator: "/")

    #expect(store.keys == ["a.x"])
  }

  @Test func `Tells Listeners About Each Removed Key`() throws {
    let store = try makeStore()
    store.set("value", forKey: "a.x")
    store.set("value", forKey: "b")
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    store.removeValues(underKey: "a")

    #expect(recorder.all == [.key("a.x")])
    subscription.cancel()
  }
}

/// Stores how many elements an array has, to show that a coder was used.
private struct CountingCoder: MMKVTopLevelEncoder, MMKVTopLevelDecoder, Sendable {
  func encode<T: Encodable>(_ value: T) throws -> String {
    "\((value as? [String])?.count ?? 0) elements"
  }

  func decode<T: Decodable>(_ type: T.Type, from input: String) throws -> T {
    throw DecodingError.dataCorrupted(
      DecodingError.Context(codingPath: [], debugDescription: "Not needed.")
    )
  }
}
