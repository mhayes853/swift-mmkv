#if Tagged
  import SwiftMMKV
  import Tagged
  import Testing

  #if Foundation
    import Foundation
  #endif

  #if UUIDV7
    import UUIDV7
  #endif

  @Suite struct MMKVTaggedTests {
    struct User: Codable, Equatable {
      typealias ID = Tagged<User, Int>
      typealias SharedID = Tagged<User, Int.MMKVNumber>
      typealias Handle = Tagged<User, String>

      var id: ID
      var sharedID: SharedID
      var handle: Handle
      var age: Int
    }

    @Test func `A Tagged Value Is Stored As Its Raw Value`() throws {
      let store = try makeStore()

      #expect(store.set(User.Handle("blob"), forKey: "handle"))
      store.set("other", forKey: "raw")

      #expect(store.value(forKey: "handle", as: String.self) == "blob")
      #expect(store.value(forKey: "handle", as: User.Handle.self) == "blob")
      #expect(store.value(forKey: "raw", as: User.Handle.self) == "other")
      #expect(store.value(forKey: "missing", as: User.Handle.self) == nil)
    }

    @Test func `A Tagged Int Is A Native Integer`() throws {
      let store = try makeStore()

      store.set(User.ID(42), forKey: "id")

      #expect(store.value(forKey: "id", as: Int64.self) == 42)
      #expect(store.value(forKey: "id", as: User.ID.self) == 42)
    }

    @Test func `A Tagged Number Is A Double`() throws {
      let store = try makeStore()

      store.set(User.SharedID(42), forKey: "id")
      store.set(7.0, forKey: "javascript")
      store.set(2.5, forKey: "fraction")

      #expect(store.value(forKey: "id", as: Double.self) == 42)
      #expect(store.value(forKey: "id", as: User.SharedID.self) == 42)
      #expect(store.value(forKey: "javascript", as: User.SharedID.self) == 7)
      #expect(store.value(forKey: "fraction", as: User.SharedID.self) == nil)
    }

    @Test func `A Typed Key Holds A Tagged Value`() throws {
      let store = try makeStore()
      let key = MMKVStore.Key<User.ID>("currentUser")
      let defaulted = MMKVStore.DefaultedKey<User.SharedID>("shared", default: 0)

      store[key] = 3
      store[defaulted] += 1

      #expect(store[key] == 3)
      #expect(store[defaulted] == 1)
      #expect(store.value(forKey: "shared", as: Double.self) == 1)
    }

    @Test func `A Tagged Value Spread Over Keys Is Stored As Itself`() throws {
      let store = try makeStore()
      let user = User(id: 1, sharedID: 2, handle: "blob", age: 30)

      #expect(try store.encode(user, intoKeysUnder: "user"))

      #expect(store.value(forKey: "user.id", as: Int64.self) == 1)
      #expect(store.value(forKey: "user.sharedID", as: Double.self) == 2)
      #expect(store.value(forKey: "user.handle", as: String.self) == "blob")
      #expect(store.value(forKey: "user.age", as: Double.self) == 30)
      #expect(try store.decode(User.self, fromKeysUnder: "user") == user)
    }

    #if Foundation
      @Test func `A Tagged UUID Is Stored As Its String`() throws {
        let store = try makeStore()
        let id = Tagged<User, UUID>(UUID())

        store.set(id, forKey: "id")

        #expect(store.value(forKey: "id", as: String.self) == id.rawValue.uuidString)
        #expect(store.value(forKey: "id", as: Tagged<User, UUID>.self) == id)
      }
    #endif

    #if UUIDV7
      @Test func `A Tagged UUIDV7 Is Stored As Its String`() throws {
        let store = try makeStore()
        let id = Tagged<User, UUIDV7>(UUIDV7())

        store.set(id, forKey: "id")

        #expect(store.value(forKey: "id", as: String.self) == id.rawValue.uuidString)
        #expect(store.value(forKey: "id", as: Tagged<User, UUIDV7>.self) == id)
      }
    #endif
  }
#endif
