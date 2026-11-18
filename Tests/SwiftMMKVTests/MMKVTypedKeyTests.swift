import Foundation
import SwiftMMKV
import Testing

extension MMKVStore.Key where Value == String {
  fileprivate static let username: Self = "username"

  fileprivate static func draft(_ postID: Int) -> Self {
    "draft.\(postID)"
  }
}

extension MMKVStore.Key where Value == Double {
  fileprivate static let volume = Self("volume")
}

extension MMKVStore.DefaultedKey where Value == Double {
  fileprivate static let brightness = Self("brightness", default: 0.5)
}

extension MMKVStore.DefaultedKey where Value == String {
  fileprivate static let theme = Self(.init("theme"), default: "system")
}

@Suite struct MMKVStoreKeyValueTests {
  @Test func `Is Made From A Name A Literal Or An Interpolation`() {
    #expect(MMKVStore.Key.username == MMKVStore.Key<String>("username"))
    #expect(MMKVStore.Key.username.name == "username")
    #expect(MMKVStore.Key.draft(42).name == "draft.42")
    #expect("\(MMKVStore.Key.draft(42))" == "draft.42")
    #expect(MMKVStore.Key("volume", as: Double.self) == .volume)
  }

  @Test func `Reads And Writes Through The Subscript`() throws {
    let store = try makeStore()

    #expect(store[.username] == nil)
    store[.username] = "blob"
    store[.volume] = 0.5

    #expect(store[.username] == "blob")
    #expect(store[.volume] == 0.5)
    store[.username] = nil
    #expect(store[.username] == nil)
    #expect(store.keys == ["volume"])
  }

  @Test func `Reads And Writes What The String API Does`() throws {
    let store = try makeStore()

    store.set("blob", forKey: "username")
    #expect(store.value(for: .username) == "blob")

    #expect(store.set("drafted", for: .draft(1)))
    #expect(store["draft.1", as: String.self] == "drafted")
  }

  @Test func `The String Subscript Still Takes A Literal`() throws {
    let store = try makeStore()

    store["volume"] = 0.25
    let volume: Double? = store["volume"]

    #expect(volume == 0.25)
    #expect(store[.volume] == 0.25)
  }

  @Test func `Contains And Removes`() throws {
    let store = try makeStore()
    store[.username] = "blob"

    #expect(store.contains(.username))
    #expect(!store.contains(.volume))
    #expect(store.removeValue(for: .username))
    #expect(!store.contains(.username))
  }

  @Test func `A Value Can Expire`() throws {
    let store = try makeStore()

    #expect(store.set("123456", for: .username, expiringIn: .seconds(60)))

    #expect(store[.username] == "123456")
  }

  @Test func `Reports A Failed Write`() throws {
    let rootDirectory = temporaryRootDirectory()
    _ = try makeStore(rootDirectory: rootDirectory).count
    let store = try makeStore(id: "other", rootDirectory: rootDirectory, isReadOnly: true)

    #expect(!store.set("blob", for: .username))
  }
}

@Suite struct MMKVStoreKeyObservationByKeyTests {
  @Test func `Delivers The Current Value And Each Change`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<String?>()

    let subscription = store.subscribe(for: .username, recorder.record)
    store[.username] = "blob"
    store[.volume] = 1
    store.removeValue(for: .username)

    #expect(recorder.all == [nil, "blob", nil])
    subscription.cancel()
  }

  @Test func `Produces The Values Of A Key Over Time`() async throws {
    let store = try makeStore()
    store[.volume] = 0.1
    var iterator = store.values(for: .volume).makeAsyncIterator()

    #expect(await iterator.next() == .some(0.1))
    store[.volume] = 0.2
    #expect(await iterator.next() == .some(0.2))
  }
}

@Suite struct MMKVStoreDefaultedKeyTests {
  @Test func `Is Made From A Name Or A Key`() {
    #expect(MMKVStore.DefaultedKey.brightness.key == MMKVStore.Key<Double>("brightness"))
    #expect(MMKVStore.DefaultedKey.brightness.defaultValue == 0.5)
    #expect(MMKVStore.DefaultedKey.theme == MMKVStore.DefaultedKey("theme", default: "system"))
    #expect(MMKVStore.DefaultedKey.theme != MMKVStore.DefaultedKey("theme", default: "dark"))
  }

  @Test func `Reads The Default Until A Value Is Stored`() throws {
    let store = try makeStore()

    #expect(store[.brightness] == 0.5)
    #expect(store.value(for: .theme) == "system")
    #expect(!store.contains(.brightness))
    #expect(store.keys.isEmpty)

    store[.brightness] = 0.8
    #expect(store.set("dark", for: .theme))

    #expect(store[.brightness] == 0.8)
    #expect(store[.theme] == "dark")
    #expect(store.contains(.brightness))
  }

  @Test func `Stores A Value Equal To The Default`() throws {
    let store = try makeStore()

    store[.brightness] = 0.5

    #expect(store.contains(.brightness))
    #expect(store["brightness", as: Double.self] == 0.5)
  }

  @Test func `Reads The Default Again Once Removed`() throws {
    let store = try makeStore()
    store[.theme] = "dark"

    #expect(store.removeValue(for: .theme))

    #expect(store[.theme] == "system")
    #expect(!store.contains(.theme))
  }

  @Test func `Delivers The Default In Place Of A Missing Value`() throws {
    let store = try makeStore()
    let recorder = ValueRecorder<String>()

    let subscription = store.subscribe(for: .theme, recorder.record)
    store[.theme] = "dark"
    store.removeValue(for: .theme)

    #expect(recorder.all == ["system", "dark", "system"])
    subscription.cancel()
  }
}
