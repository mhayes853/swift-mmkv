#if Sharing
  import Dependencies
  import Foundation
  import Sharing
  import SwiftMMKV
  import Testing

  @Suite struct MMKVStorageKeyTests {
    @Test func `Uses The Default When The Store Has No Value`() throws {
      let store = try makeStore()

      @Shared(.mmkv("volume", store: store)) var volume = 0.5

      #expect(volume == 0.5)
      #expect(!store.contains("volume"))
    }

    @Test func `Loads The Value Already In The Store`() throws {
      let store = try makeStore()
      store.set(0.8, forKey: "volume")

      @Shared(.mmkv("volume", store: store)) var volume = 0.5

      #expect(volume == 0.8)
    }

    @Test func `Saves Changes To The Store`() throws {
      let store = try makeStore()
      @Shared(.mmkv("volume", store: store)) var volume = 0.5

      $volume.withLock { $0 = 0.9 }

      #expect(store.value(forKey: "volume", as: Double.self) == 0.9)
      #expect(volume == 0.9)
    }

    @Test func `Follows Writes Made Through The Store`() throws {
      let store = try makeStore()
      @Shared(.mmkv("username", store: store)) var username = "blob"

      store.set("blob jr", forKey: "username")
      #expect(username == "blob jr")

      store.set("unrelated", forKey: "other")
      #expect(username == "blob jr")

      store.removeValue(forKey: "username")
      #expect(username == "blob")
    }

    @Test func `An Optional Value Is Nil Without A Value And Removes Its Key When Set To Nil`()
      throws
    {
      let store = try makeStore()
      @Shared(.mmkv("username", store: store)) var username: String?
      #expect(username == nil)

      $username.withLock { $0 = "blob" }
      #expect(store.value(forKey: "username", as: String.self) == "blob")

      $username.withLock { $0 = nil }
      #expect(!store.contains("username"))
      #expect(username == nil)
    }

    @Test func `Properties Over The Same Key Share Their State`() throws {
      let store = try makeStore()
      @Shared(.mmkv("count", store: store)) var first = 0.0
      @Shared(.mmkv("count", store: store)) var second = 0.0

      $first.withLock { $0 = 3 }

      #expect(second == 3)
    }

    @Test func `The Same Key In Different Stores Is Different State`() throws {
      let rootDirectory = temporaryRootDirectory()
      let firstStore = try makeStore(id: "first", rootDirectory: rootDirectory)
      let secondStore = try makeStore(id: "second", rootDirectory: rootDirectory)
      @Shared(.mmkv("count", store: firstStore)) var first = 0.0
      @Shared(.mmkv("count", store: secondStore)) var second = 0.0

      $first.withLock { $0 = 3 }

      #expect(second == 0)
      #expect(!secondStore.contains("count"))
    }

    @Test func `Stores Over The Same Files Keep Each Other's State Current`() throws {
      let rootDirectory = temporaryRootDirectory()
      let firstStore = try makeStore(rootDirectory: rootDirectory)
      let secondStore = try makeStore(rootDirectory: rootDirectory)
      @Shared(.mmkv("count", store: firstStore)) var first = 0.0
      @Shared(.mmkv("count", store: secondStore)) var second = 0.0

      $first.withLock { $0 = 3 }

      #expect(second == 3)
    }

    @Test func `Follows A Change Made Outside The Store Once It Is Noticed`() throws {
      let (other, store) = try makeLinkedStores(mode: .multiProcess)
      @Shared(.mmkv("username", store: store)) var username = "blob"

      other.set("blob jr", forKey: "username")
      #expect(username == "blob")

      store.checkForExternalChanges()
      #expect(username == "blob jr")
    }

    @Test func `A Rejected Write Is Reported As A Save Error`() throws {
      let store = try makeStore(itemSizeLimit: 16)
      @Shared(.mmkv("text", store: store)) var text = ""

      $text.withLock { $0 = String(repeating: "a", count: 64) }

      #expect($text.saveError as? MMKVError == .writeFailed(key: "text"))
      #expect(!store.contains("text"))
    }

    @Test func `Uses The Default Store Dependency`() throws {
      let store = try makeStore()
      store.set(true, forKey: "hasOnboarded")

      withDependencies {
        $0.defaultMMKVStore = store
      } operation: {
        @Shared(.mmkv("hasOnboarded")) var hasOnboarded = false
        #expect(hasOnboarded)
      }
    }

    @Test func `Tests Get An Empty Default Store`() {
      @Shared(.mmkv("launchCount")) var launchCount = 0.0
      $launchCount.withLock { $0 += 1 }

      @Dependency(\.defaultMMKVStore) var store
      #expect(store.value(forKey: "launchCount", as: Double.self) == 1)
    }

    #if Foundation
      struct Settings: Codable, Equatable {
        var fontSize = 14.0
      }

      @Test func `Codable Values Are Stored Whole Under One Key`() throws {
        let store = try makeStore()
        @Shared(.mmkv("settings", encoder: JSONEncoder(), decoder: JSONDecoder(), store: store))
        var settings = Settings()
        #expect(settings == Settings())

        $settings.withLock { $0.fontSize = 18 }
        #expect(store.value(forKey: "settings", as: String.self) == #"{"fontSize":18}"#)

        store.set(#"{"fontSize":20}"#, forKey: "settings")
        #expect(settings == Settings(fontSize: 20))
      }

      @Test func `An Optional Codable Value Removes Its Key When Set To Nil`() throws {
        let store = try makeStore()
        @Shared(.mmkv("settings", encoder: JSONEncoder(), decoder: JSONDecoder(), store: store))
        var settings: Settings?
        #expect(settings == nil)

        $settings.withLock { $0 = Settings(fontSize: 18) }
        #expect(try store.decode(Settings.self, forKey: "settings") == Settings(fontSize: 18))

        $settings.withLock { $0 = nil }
        #expect(!store.contains("settings"))
      }

      @Test func `A Value That Does Not Decode Is Reported As A Load Error`() throws {
        let store = try makeStore()
        store.set("not json", forKey: "settings")

        @Shared(.mmkv("settings", encoder: JSONEncoder(), decoder: JSONDecoder(), store: store))
        var settings = Settings()

        #expect(settings == Settings())
        #expect($settings.loadError is DecodingError)
      }
    #endif
  }
#endif
