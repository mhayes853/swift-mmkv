#if Sharing
  import Dependencies
  import Foundation
  import Sharing
  import SwiftMMKV
  import Testing

  extension MMKVStore.Key where Value == String {
    fileprivate static let username: Self = "username"
  }

  extension MMKVStore.DefaultedKey where Value == Double {
    fileprivate static let volume = Self("volume", default: 0.5)
  }

  extension MMKVStore.CodedKey where Value == Int {
    fileprivate static let count = Self(
      "count",
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

  @Suite struct MMKVStorageKeyTypedKeyTests {
    @Test func `A Key Loads And Saves Its Value`() throws {
      let store = try makeStore()
      @Shared(.mmkv(.username, store: store)) var username = "default"
      #expect(username == "default")

      $username.withLock { $0 = "blob" }
      #expect(store[.username] == "blob")

      store[.username] = "blob jr"
      #expect(username == "blob jr")
    }

    @Test func `An Optional Key Is Nil Without A Value And Removes Its Key When Set To Nil`()
      throws
    {
      let store = try makeStore()
      @Shared(.mmkv(.username, store: store)) var username: String?
      #expect(username == nil)

      $username.withLock { $0 = "blob" }
      #expect(store[.username] == "blob")

      $username.withLock { $0 = nil }
      #expect(!store.contains(.username))
    }

    @Test func `A Key Shares Its State With The Same Key Given As A String`() throws {
      let store = try makeStore()
      @Shared(.mmkv(.username, store: store)) var typed = "default"
      @Shared(.mmkv("username", store: store)) var untyped = "default"

      $typed.withLock { $0 = "blob" }

      #expect(untyped == "blob")
    }

    @Test func `A Defaulted Key Supplies The Default`() throws {
      let store = try makeStore()
      @Shared(.mmkv(.volume, store: store)) var volume
      #expect(volume == 0.5)
      #expect(!store.contains(.volume))

      $volume.withLock { $0 = 0.8 }
      #expect(store[.volume] == 0.8)

      store.removeValue(for: .volume)
      #expect(volume == 0.5)
    }

    @Test func `A Coded Key Loads And Saves Through Its Coders`() throws {
      let store = try makeStore()
      @Shared(.mmkv(.count, store: store)) var count = 0
      #expect(count == 0)

      $count.withLock { $0 = 42 }
      #expect(store["count", as: String.self] == "42")

      try store.set(7, for: .count)
      #expect(count == 7)
    }

    @Test func `An Optional Coded Key Removes Its Key When Set To Nil`() throws {
      let store = try makeStore()
      @Shared(.mmkv(.count, store: store)) var count: Int?
      #expect(count == nil)

      $count.withLock { $0 = 42 }
      #expect(try store.value(for: .count) == 42)

      $count.withLock { $0 = nil }
      #expect(!store.contains(.count))
    }

    @Test func `A Coded Value That Does Not Decode Is Reported As A Load Error`() throws {
      let store = try makeStore()
      store.set("not a number", forKey: "count")

      @Shared(.mmkv(.count, store: store)) var count = 0

      #expect(count == 0)
      #expect($count.loadError is TextCoder.Failure)
    }

    @Test func `A Defaulted Coded Key Supplies The Default`() throws {
      let store = try makeStore()
      @Shared(.mmkv(.lives, store: store)) var lives
      #expect(lives == 3)

      $lives.withLock { $0 = 5 }
      #expect(try store.value(for: .lives) == 5)
    }

    @Test func `A Rejected Write Is Reported As A Save Error`() throws {
      let store = try makeStore(mode: .multiProcess)
      @Shared(.mmkv(.count, store: store)) var count = 0

      store.suspend()
      $count.withLock { $0 = 1 }

      #expect(($count.saveError as? MMKVError)?.code == .storeIsSuspended)
    }

    @Test func `Uses The Default Store Dependency`() throws {
      let store = try makeStore()
      withDependencies {
        $0.defaultMMKVStore = store
      } operation: {
        @Shared(.mmkv(.volume)) var volume
        $volume.withLock { $0 = 1 }
        #expect(store[.volume] == 1)
      }
    }
  }
#endif
