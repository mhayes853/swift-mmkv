#if Sharing
  import Dependencies
  import Foundation
  import Sharing
  import SwiftMMKV
  import Testing

  private struct Profile: Codable, Equatable, Sendable {
    var name = "blob"
    var age = 42
    var nickname: String?
  }

  @Suite struct MMKVStorageKeyKeysUnderTests {
    @Test func `Uses The Default When No Key Is Under The Prefix`() throws {
      let store = try makeStore()

      @Shared(.mmkv(keysUnder: "profile", store: store)) var profile = Profile()

      #expect(profile == Profile())
      #expect($profile.loadError == nil)
      #expect(store.keys.isEmpty)
    }

    @Test func `Loads The Value Already In The Store`() throws {
      let store = try makeStore()
      let stored = Profile(name: "blob jr", age: 7, nickname: "junior")
      try store.encode(stored, intoKeysUnder: "profile")

      @Shared(.mmkv(keysUnder: "profile", store: store)) var profile = Profile()

      #expect(profile == stored)
    }

    @Test func `Saves Each Property Under A Key Of Its Own`() throws {
      let store = try makeStore()
      @Shared(.mmkv(keysUnder: "profile", store: store)) var profile = Profile()

      $profile.withLock { $0.name = "blob sr" }

      #expect(store.keys == ["profile.name", "profile.age"])
      #expect(store.value(forKey: "profile.name", as: String.self) == "blob sr")
      #expect(profile.name == "blob sr")
      #expect($profile.saveError == nil)
    }

    @Test func `Saving Removes The Keys The Value No Longer Has`() throws {
      let store = try makeStore()
      @Shared(.mmkv(keysUnder: "profile", store: store)) var profile = Profile()

      $profile.withLock { $0.nickname = "junior" }
      #expect(store.contains("profile.nickname"))

      $profile.withLock { $0.nickname = nil }
      #expect(!store.contains("profile.nickname"))
      #expect(profile.nickname == nil)
    }

    @Test func `Follows A Write To Any Key Under The Prefix`() throws {
      let store = try makeStore()
      @Shared(.mmkv(keysUnder: "profile", store: store)) var profile = Profile()
      try store.encode(Profile(), intoKeysUnder: "profile")

      store.set("blob jr", forKey: "profile.name")
      #expect(profile.name == "blob jr")

      store.set("unrelated", forKey: "profileBackup")
      store.set("unrelated", forKey: "other.name")
      #expect(profile.name == "blob jr")

      try store.encode(Profile(name: "blob sr", age: 70), intoKeysUnder: "profile")
      #expect(profile == Profile(name: "blob sr", age: 70))

      store.removeValues(underKey: "profile")
      #expect(profile == Profile())
    }

    @Test func `An Optional Value Is Nil Without Keys And Removes Its Keys When Set To Nil`()
      throws
    {
      let store = try makeStore()
      @Shared(.mmkv(keysUnder: "profile", store: store)) var profile: Profile?
      #expect(profile == nil)

      $profile.withLock { $0 = Profile(name: "blob jr") }
      #expect(store.value(forKey: "profile.name", as: String.self) == "blob jr")
      #expect(profile == Profile(name: "blob jr"))

      store.set("kept", forKey: "profileBackup")
      $profile.withLock { $0 = nil }
      #expect(store.keys == ["profileBackup"])
      #expect(profile == nil)
    }

    @Test func `Uses The Options`() throws {
      let store = try makeStore()
      let options = MMKVKeyCodingOptions(separator: "/")
      @Shared(.mmkv(keysUnder: "profile", options: options, store: store)) var profile = Profile()

      $profile.withLock { $0.name = "blob jr" }
      #expect(store.keys == ["profile/name", "profile/age"])

      store.set(7.0, forKey: "profile/age")
      #expect(profile.age == 7)
    }

    @Test func `Properties Over The Same Prefix Share Their State`() throws {
      let store = try makeStore()
      @Shared(.mmkv(keysUnder: "profile", store: store)) var first = Profile()
      @Shared(.mmkv(keysUnder: "profile", store: store)) var second = Profile()

      $first.withLock { $0.name = "blob jr" }

      #expect(second.name == "blob jr")
    }

    @Test func `A Prefix And A Key Of The Same Name Are Different State`() throws {
      let store = try makeStore()
      @Shared(.mmkv("profile", store: store)) var name = "blob"
      @Shared(.mmkv(keysUnder: "profile", store: store)) var profile: Profile?

      $name.withLock { $0 = "blob jr" }

      #expect(name == "blob jr")
      #expect(store.value(forKey: "profile", as: String.self) == "blob jr")
    }

    @Test func `A Value That Does Not Decode Is Reported As A Load Error`() throws {
      let store = try makeStore()
      store.set("blob", forKey: "profile.name")

      @Shared(.mmkv(keysUnder: "profile", store: store)) var profile = Profile()

      #expect(profile == Profile())
      #expect($profile.loadError is DecodingError)

      store.set(7.0, forKey: "profile.age")
      #expect(profile == Profile(name: "blob", age: 7))
      #expect($profile.loadError == nil)
    }

    @Test func `Follows A Change Made Outside The Store Once It Is Noticed`() throws {
      let (other, store) = try makeLinkedStores(mode: .multiProcess)
      @Shared(.mmkv(keysUnder: "profile", store: store)) var profile = Profile()

      try other.encode(Profile(name: "blob jr"), intoKeysUnder: "profile")
      store.checkForExternalChanges()

      #expect(profile.name == "blob jr")
    }

    @Test func `Keeps Its Value And Reports Errors While The Store Is Suspended`() throws {
      let store = try makeStore(id: "shared-keys-under-suspended", mode: .multiProcess)
      try store.encode(Profile(name: "blob jr"), intoKeysUnder: "profile")
      @Shared(.mmkv(keysUnder: "profile", store: store)) var profile = Profile()
      #expect(profile.name == "blob jr")

      store.suspend()
      $profile.withLock { $0.name = "blob sr" }
      #expect(($profile.saveError as? MMKVError)?.code == .storeIsSuspended)

      store.resume()
      #expect(profile.name == "blob jr")
      #expect($profile.loadError == nil)
    }

    @Test func `Setting An Optional To Nil While Suspended Is A Save Error`() throws {
      let store = try makeStore(id: "shared-keys-under-suspended-nil", mode: .multiProcess)
      try store.encode(Profile(), intoKeysUnder: "profile")
      @Shared(.mmkv(keysUnder: "profile", store: store)) var profile: Profile?

      store.suspend()
      $profile.withLock { $0 = nil }
      #expect(($profile.saveError as? MMKVError)?.code == .storeIsSuspended)

      store.resume()
      #expect(profile == Profile())
    }

    @Test func `Uses The Default Store Dependency`() throws {
      let store = try makeStore()
      try withDependencies {
        $0.defaultMMKVStore = store
      } operation: {
        @Shared(.mmkv(keysUnder: "profile")) var profile = Profile()
        $profile.withLock { $0.name = "blob jr" }
        #expect(store.value(forKey: "profile.name", as: String.self) == "blob jr")
      }
    }
  }
#endif
