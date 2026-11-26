import Foundation
import SwiftMMKV
import Testing

private struct BodyFailure: Error, Equatable {}

private struct Sync: Codable, Equatable {
  var isEnabled: Bool
  var interval: Int
}

private struct Settings: Codable, Equatable {
  var fontSize: Double
  var theme: String?
  var sync: Sync
}

private let settings = Settings(
  fontSize: 16,
  theme: "dark",
  sync: Sync(isEnabled: true, interval: 30)
)

extension MMKVStore.Key where Value == String {
  fileprivate static let username = Self("username")
}

extension MMKVStore.DefaultedKey where Value == Int {
  fileprivate static let launchCount = Self("launchCount", default: 0)
}

extension MMKVStore.CodedKey where Value == Int {
  fileprivate static let count = Self("count", encoder: TextCoder.shared, decoder: TextCoder.shared)
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

@Suite struct MMKVStoreUpdateTests {
  @Test func `Changes The Value Of A Key In Place`() throws {
    let store = try makeStore()
    store.set(1, forKey: "count")

    #expect(store.update(forKey: "count", as: Int.self) { $0 = ($0 ?? 0) + 1 })
    #expect(store.update(forKey: "count") { (count: inout Int?) in count? *= 10 })

    #expect(store.value(forKey: "count", as: Int.self) == 20)
  }

  @Test func `Gives Nil For A Key Without A Value`() throws {
    let store = try makeStore()
    var seen = [Int?]()

    store.update(forKey: "count", as: Int.self) {
      seen.append($0)
      $0 = 1
    }

    #expect(seen == [nil])
    #expect(store.value(forKey: "count", as: Int.self) == 1)
  }

  @Test func `Setting The Value To Nil Removes The Key`() throws {
    let store = try makeStore()
    store.set("blob", forKey: "username")

    #expect(store.update(forKey: "username", as: String.self) { $0 = nil })

    #expect(!store.contains("username"))
  }

  @Test func `Leaving A Missing Value Nil Changes Nothing And Tells Nobody`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    #expect(store.update(forKey: "username", as: String.self) { _ in })

    #expect(store.keys.isEmpty)
    #expect(recorder.all.isEmpty)
    subscription.cancel()
  }

  @Test func `A Throwing Body Writes Nothing`() throws {
    let store = try makeStore()
    store.set(1, forKey: "count")
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    #expect(throws: BodyFailure()) {
      try store.update(forKey: "count", as: Int.self) { (count) throws(BodyFailure) in
        count = 2
        throw BodyFailure()
      }
    }

    #expect(store.value(forKey: "count", as: Int.self) == 1)
    #expect(recorder.all.isEmpty)
    subscription.cancel()
  }

  @Test func `Tells Listeners Once, After The Value Is Written`() throws {
    let store = try makeStore()
    store.set(1, forKey: "count")
    let recorder = ValueRecorder<Int?>()
    let subscription = store.subscribe { change in
      #expect(change == .key("count"))
      recorder.record(store.value(forKey: "count", as: Int.self))
    }

    store.update(forKey: "count", as: Int.self) { $0 = 2 }
    #expect(recorder.all == [2])

    store.update(forKey: "count", as: Int.self) { $0 = nil }
    #expect(recorder.all == [2, nil])
    subscription.cancel()
  }

  @Test func `Writes The Value Even When The Body Leaves It Alone`() throws {
    let store = try makeStore()
    store.set(1, forKey: "count")
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    store.update(forKey: "count", as: Int.self) { _ in }

    #expect(recorder.all == [.key("count")])
    subscription.cancel()
  }

  @Test func `The Body May Read And Write The Store`() throws {
    let store = try makeStore()
    store.set(2, forKey: "step")
    store.set(1, forKey: "count")

    store.update(forKey: "count", as: Int.self) { count in
      let step = store.value(forKey: "step", as: Int.self) ?? 1
      count = (count ?? 0) + step
      store.set(step + 1, forKey: "step")
    }

    #expect(store.value(forKey: "count", as: Int.self) == 3)
    #expect(store.value(forKey: "step", as: Int.self) == 3)
  }

  @Test func `Concurrent Updates Lose Nothing`() async throws {
    let store = try makeStore()

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask {
          for _ in 0..<250 {
            store.update(forKey: "count", as: Int.self) { $0 = ($0 ?? 0) + 1 }
          }
        }
      }
    }

    #expect(store.value(forKey: "count", as: Int.self) == 2000)
  }

  @Test func `Updates From Two Copies Of A Multi Process Store Lose Nothing`() async throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)

    await withTaskGroup(of: Void.self) { group in
      for store in [first, second] {
        group.addTask {
          for _ in 0..<250 {
            store.update(forKey: "count", as: Int.self) { $0 = ($0 ?? 0) + 1 }
          }
        }
      }
    }

    #expect(first.value(forKey: "count", as: Int.self) == 500)
  }

  @Test func `A Read Only Store Runs The Body And Accepts Nothing`() throws {
    let rootDirectory = temporaryRootDirectory()
    do {
      let writable = try makeStore(id: "update-read-only", rootDirectory: rootDirectory)
      writable.set(1, forKey: "count")
      writable.close()
    }
    let store = try makeStore(
      id: "update-read-only",
      rootDirectory: rootDirectory,
      isReadOnly: true
    )
    var seen = [Int?]()

    let didUpdate = store.update(forKey: "count", as: Int.self) {
      seen.append($0)
      $0 = 2
    }

    #expect(!didUpdate)
    #expect(seen == [1])
    #expect(store.value(forKey: "count", as: Int.self) == 1)
  }

  @Test func `A Suspended Store Accepts Nothing And Does Not Run The Body`() throws {
    let store = try makeStore(id: "update-suspended", mode: .multiProcess)
    store.set(1, forKey: "count")
    store.suspend()
    var runs = 0

    #expect(!store.update(forKey: "count", as: Int.self) { _ in runs += 1 })
    #expect(!store.update(for: .launchCount) { _ in runs += 1 })
    expectError(.storeIsSuspended) { try store.update(for: .count) { _ in runs += 1 } }
    expectError(.storeIsSuspended) { try store.update(for: .lives) { _ in runs += 1 } }
    expectError(.storeIsSuspended) {
      try store.update(keysUnder: "settings", as: Settings?.self) { _ in runs += 1 }
    }
    expectError(.storeIsSuspended) {
      try store.update(
        forKey: "count",
        as: Int.self,
        encoder: TextCoder.shared,
        decoder: TextCoder.shared
      ) { _ in runs += 1 }
    }

    store.resume()
    #expect(runs == 0)
    #expect(store.value(forKey: "count", as: Int.self) == 1)
    #expect(store.keys == ["count"])
  }

  @Test func `A Closed Store Accepts Nothing And Does Not Run The Body`() throws {
    let store = try makeStore(id: "update-closed")
    store.set(1, forKey: "count")
    store.close()
    var runs = 0

    #expect(!store.update(forKey: "count", as: Int.self) { _ in runs += 1 })
    #expect(!store.update(for: .username) { _ in runs += 1 })
    #expect(!store.update(for: .launchCount) { _ in runs += 1 })
    expectError(.storeIsClosed) { try store.update(for: .count) { _ in runs += 1 } }
    expectError(.storeIsClosed) { try store.update(for: .lives) { _ in runs += 1 } }
    expectError(.storeIsClosed) {
      try store.update(keysUnder: "settings", as: Settings?.self) { _ in runs += 1 }
    }
    expectError(.storeIsClosed) {
      try store.update(
        forKey: "count",
        as: Int.self,
        encoder: TextCoder.shared,
        decoder: TextCoder.shared
      ) { _ in runs += 1 }
    }

    #expect(runs == 0)
  }
}

@Suite struct MMKVStoreUpdateCodedTests {
  @Test func `Decodes, Changes, And Encodes The Value`() throws {
    let store = try makeStore()
    try store.encode(41, forKey: "count", with: TextCoder.shared)

    let didUpdate = try store.update(
      forKey: "count",
      as: Int.self,
      encoder: TextCoder.shared,
      decoder: TextCoder.shared
    ) { $0? += 1 }

    #expect(didUpdate)
    #expect(store.value(forKey: "count", as: String.self) == "42")
  }

  @Test func `Gives Nil Without A Value, And Removes The Key When Set To Nil`() throws {
    let store = try makeStore()
    var seen = [Int?]()
    let update = { (body: (inout Int?) -> Void) in
      try store.update(
        forKey: "count",
        as: Int.self,
        encoder: TextCoder.shared,
        decoder: TextCoder.shared,
        body
      )
    }

    try update { seen.append($0) }
    #expect(store.keys.isEmpty)

    try update { $0 = 7 }
    #expect(store.value(forKey: "count", as: String.self) == "7")

    try update { $0 = nil }
    #expect(seen == [nil])
    #expect(!store.contains("count"))
  }

  @Test func `A Value That Does Not Decode Is Thrown Without Running The Body`() throws {
    let store = try makeStore()
    store.set("not a number", forKey: "count")
    var runs = 0

    #expect(throws: TextCoder.Failure.self) {
      try store.update(
        forKey: "count",
        as: Int.self,
        encoder: TextCoder.shared,
        decoder: TextCoder.shared
      ) { _ in runs += 1 }
    }

    #expect(runs == 0)
    #expect(store.value(forKey: "count", as: String.self) == "not a number")
  }

  @Test func `A Result That Does Not Encode Is Thrown And Nothing Is Written`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    #expect(throws: TextCoder.Failure.self) {
      try store.update(for: .unencodable) { $0 = [1, 2] }
    }

    #expect(store.keys.isEmpty)
    #expect(recorder.all.isEmpty)
    subscription.cancel()
  }

  @Test func `A Throwing Body Writes Nothing`() throws {
    let store = try makeStore()
    try store.set(1, for: .count)

    #expect(throws: BodyFailure()) {
      try store.update(for: .count) {
        $0 = 2
        throw BodyFailure()
      }
    }

    #expect(try store.value(for: .count) == 1)
  }
}

@Suite struct MMKVStoreUpdateTypedKeyTests {
  @Test func `A Key Is Updated Like Its Name`() throws {
    let store = try makeStore()
    store.set("Blob", for: .username)

    #expect(store.update(for: .username) { $0 = $0?.lowercased() })
    #expect(store.value(for: .username) == "blob")

    #expect(store.update(for: .username) { $0 = nil })
    #expect(!store.contains(.username))
  }

  @Test func `A Defaulted Key Starts From Its Default`() throws {
    let store = try makeStore()

    #expect(store.update(for: .launchCount) { $0 += 1 })
    #expect(store.update(for: .launchCount) { $0 += 1 })

    #expect(store.value(forKey: "launchCount", as: Int.self) == 2)
  }

  @Test func `A Defaulted Key Is Written Even When It Is Left At Its Default`() throws {
    let store = try makeStore()

    #expect(store.update(for: .launchCount) { _ in })

    #expect(store.value(forKey: "launchCount", as: Int.self) == 0)
  }

  @Test func `A Throwing Body Leaves A Defaulted Key Alone`() throws {
    let store = try makeStore()

    #expect(throws: BodyFailure()) {
      try store.update(for: .launchCount) { (count) throws(BodyFailure) in
        count = 9
        throw BodyFailure()
      }
    }

    #expect(!store.contains(.launchCount))
  }

  @Test func `A Coded Key Uses Its Coders`() throws {
    let store = try makeStore()
    var seen = [Int?]()

    #expect(
      try store.update(for: .count) {
        seen.append($0)
        $0 = 41
      }
    )
    #expect(try store.update(for: .count) { $0? += 1 })
    #expect(store.value(forKey: "count", as: String.self) == "42")

    #expect(try store.update(for: .count) { $0 = nil })
    #expect(seen == [nil])
    #expect(!store.contains(.count))
  }

  @Test func `A Defaulted Coded Key Starts From Its Default`() throws {
    let store = try makeStore()

    #expect(try store.update(for: .lives) { $0 -= 1 })
    #expect(try store.update(for: .lives) { $0 -= 1 })

    #expect(store.value(forKey: "lives", as: String.self) == "1")
  }

  @Test func `A Coded Key That Does Not Decode Is Thrown Without Running The Body`() throws {
    let store = try makeStore()
    store.set("many", forKey: "lives")
    var runs = 0

    #expect(throws: TextCoder.Failure.self) {
      try store.update(for: .lives) { _ in runs += 1 }
    }

    #expect(runs == 0)
    #expect(store.value(forKey: "lives", as: String.self) == "many")
  }
}

@Suite struct MMKVStoreUpdateKeysUnderTests {
  @Test func `Changes A Property Of A Value Spread Over Keys`() throws {
    let store = try makeStore()
    try store.encode(settings, intoKeysUnder: "settings")

    let didUpdate = try store.update(keysUnder: "settings", as: Settings.self) {
      $0.theme = "light"
      $0.sync.interval = 60
    }

    var expected = settings
    expected.theme = "light"
    expected.sync.interval = 60
    #expect(didUpdate)
    #expect(try store.decode(Settings.self, fromKeysUnder: "settings") == expected)
    #expect(store.value(forKey: "settings.theme", as: String.self) == "light")
  }

  @Test func `Removes The Keys Of Properties That Become Nil`() throws {
    let store = try makeStore()
    try store.encode(settings, intoKeysUnder: "settings")

    try store.update(keysUnder: "settings", as: Settings.self) { $0.theme = nil }

    #expect(!store.contains("settings.theme"))
    #expect(try store.decode(Settings.self, fromKeysUnder: "settings").theme == nil)
  }

  @Test func `A Value That Needs Missing Keys Is Thrown Without Running The Body`() throws {
    let store = try makeStore()
    store.set(16.0, forKey: "settings.fontSize")
    var runs = 0

    #expect(throws: DecodingError.self) {
      try store.update(keysUnder: "settings", as: Settings.self) { _ in runs += 1 }
    }

    #expect(runs == 0)
    #expect(store.keys == ["settings.fontSize"])
  }

  @Test func `An Optional Starts As Nil And Its Keys Are Removed When It Is Set To Nil`() throws {
    let store = try makeStore()
    var seen = [Settings?]()

    try store.update(keysUnder: "settings", as: Settings?.self) {
      seen.append($0)
      $0 = settings
    }
    #expect(seen == [nil])
    #expect(try store.decode(Settings.self, fromKeysUnder: "settings") == settings)

    store.set("kept", forKey: "settingsBackup")
    try store.update(keysUnder: "settings", as: Settings?.self) { $0 = nil }
    #expect(store.keys == ["settingsBackup"])
  }

  @Test func `A Throwing Body Writes Nothing`() throws {
    let store = try makeStore()
    try store.encode(settings, intoKeysUnder: "settings")
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    #expect(throws: BodyFailure()) {
      try store.update(keysUnder: "settings", as: Settings.self) {
        $0.theme = "light"
        throw BodyFailure()
      }
    }

    #expect(try store.decode(Settings.self, fromKeysUnder: "settings") == settings)
    #expect(recorder.all.isEmpty)
    subscription.cancel()
  }

  @Test func `Tells A Listener Of The Value Once, With The Whole Result`() throws {
    let store = try makeStore()
    try store.encode(settings, intoKeysUnder: "settings")
    let recorder = ValueRecorder<Settings?>()
    let subscription = store.subscribe(fromKeysUnder: "settings", as: Settings.self) {
      recorder.record($0.success)
    }

    try store.update(keysUnder: "settings", as: Settings.self) {
      $0.fontSize = 20
      $0.sync.isEnabled = false
    }

    var expected = settings
    expected.fontSize = 20
    expected.sync.isEnabled = false
    #expect(recorder.all == [settings, expected])
    subscription.cancel()
  }

  @Test func `Uses The Options`() throws {
    let store = try makeStore()
    let options = MMKVKeyCodingOptions(separator: "/")
    try store.encode(settings, intoKeysUnder: "settings", options: options)

    try store.update(keysUnder: "settings", as: Settings.self, options: options) {
      $0.theme = "light"
    }

    #expect(store.value(forKey: "settings/theme", as: String.self) == "light")
    #expect(!store.contains("settings.theme"))
  }

  @Test func `Keeps Other Keys Under The Prefix When Asked To`() throws {
    let store = try makeStore()
    try store.encode(settings, intoKeysUnder: "settings")
    store.set("kept", forKey: "settings.extra")

    try store.update(keysUnder: "settings", as: Settings.self, removingOtherKeys: false) {
      $0.fontSize = 20
    }
    #expect(store.value(forKey: "settings.extra", as: String.self) == "kept")

    try store.update(keysUnder: "settings", as: Settings.self) { $0.fontSize = 22 }
    #expect(!store.contains("settings.extra"))
    #expect(store.value(forKey: "settings.fontSize", as: Double.self) == 22)
  }

  @Test func `Concurrent Updates Of Different Properties Lose Nothing`() async throws {
    let store = try makeStore()
    try store.encode(Settings(fontSize: 0, theme: nil, sync: settings.sync), intoKeysUnder: "all")

    await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<4 {
        group.addTask {
          for _ in 0..<100 {
            try store.update(keysUnder: "all", as: Settings.self) { $0.fontSize += 1 }
            try store.update(keysUnder: "all", as: Settings.self) { $0.sync.interval += 1 }
          }
        }
      }
    }

    let result = try store.decode(Settings.self, fromKeysUnder: "all")
    #expect(result.fontSize == 400)
    #expect(result.sync.interval == settings.sync.interval + 400)
  }
}
