#if UUIDV7
  import Foundation
  import SwiftMMKV
  import Testing
  import UUIDV7

  @Suite struct MMKVUUIDV7Tests {
    @Test func `A UUIDV7 Is Stored As Its String`() throws {
      let store = try makeStore()
      let uuid = UUIDV7()

      store.set(uuid, forKey: "uuid")
      store.set(uuid.uuidString.lowercased(), forKey: "lowercase")
      store.set("not a uuid", forKey: "invalid")

      #expect(store.value(forKey: "uuid", as: String.self) == uuid.uuidString)
      #expect(store.value(forKey: "uuid", as: UUIDV7.self) == uuid)
      #expect(store.value(forKey: "lowercase", as: UUIDV7.self) == uuid)
      #expect(store.value(forKey: "invalid", as: UUIDV7.self) == nil)
      #expect(store.value(forKey: "missing", as: UUIDV7.self) == nil)
    }

    @Test func `A UUID Of Another Version Is Not A UUIDV7`() throws {
      let store = try makeStore()
      store.set("E621E1F8-C36C-495A-93FC-0C247A3E6E5F", forKey: "uuid")

      #expect(store.value(forKey: "uuid", as: UUIDV7.self) == nil)
    }

    @Test func `A Typed Key Holds A UUIDV7`() throws {
      let store = try makeStore()
      let key = MMKVStore.Key<UUIDV7>("session")
      let uuid = UUIDV7()

      #expect(store[key] == nil)
      store[key] = uuid

      #expect(store[key] == uuid)
    }

    @Test func `Key Coding Stores A UUIDV7 As Its String`() throws {
      struct Account: Codable, Equatable {
        var id: UUIDV7
        var name: String
      }
      let store = try makeStore()
      let account = Account(id: UUIDV7(), name: "Blob")

      try store.encode(account, intoKeysUnder: "account")

      #expect(store.value(forKey: "account.id", as: String.self) == account.id.uuidString)
      #expect(store.value(forKey: "account.id", as: UUIDV7.self) == account.id)
      #expect(try store.decode(Account.self, fromKeysUnder: "account") == account)
    }

    @Test func `A Reader And Writer Carry A UUIDV7`() throws {
      struct SessionID: MMKVValue, Equatable {
        var rawValue: UUIDV7

        init(rawValue: UUIDV7) { self.rawValue = rawValue }

        init?(from reader: borrowing MMKVValueReader) {
          guard let rawValue = reader.uuidV7() else { return nil }
          self.rawValue = rawValue
        }

        func write(to writer: inout MMKVValueWriter) -> Bool {
          writer.set(self.rawValue)
        }
      }
      let store = try makeStore()
      let id = SessionID(rawValue: UUIDV7())

      store.set(id, forKey: "session")
      store.set("E621E1F8-C36C-495A-93FC-0C247A3E6E5F", forKey: "v4")

      #expect(store.value(forKey: "session", as: String.self) == id.rawValue.uuidString)
      #expect(store.value(forKey: "session", as: SessionID.self) == id)
      #expect(store.value(forKey: "v4", as: SessionID.self) == nil)
    }

    #if Foundation
      @Test func `Reads What A Foundation UUID Wrote`() throws {
        let store = try makeStore()
        let uuid = UUIDV7()

        store.set(uuid.rawValue, forKey: "foundation")
        store.set(uuid, forKey: "v7")

        #expect(store.value(forKey: "foundation", as: UUIDV7.self) == uuid)
        #expect(store.value(forKey: "v7", as: UUID.self) == uuid.rawValue)
      }
    #endif
  }
#endif
