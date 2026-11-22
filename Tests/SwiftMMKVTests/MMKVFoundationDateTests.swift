#if Foundation
  import Foundation
  import SwiftMMKV
  import Testing

  @Suite struct MMKVFoundationDateTests {
    /// 2026-11-21T08:30:00.250Z, which a `Double` holds exactly in every unit used here.
    let date = Date(timeIntervalSince1970: 1_795_249_800.25)

    @Test func `A Date Is Stored As An ISO 8601 String With Milliseconds`() throws {
      let store = try makeStore()

      store.set(self.date, forKey: "date")

      #expect(store.value(forKey: "date", as: String.self) == "2026-11-21T08:30:00.250Z")
      #expect(store.value(forKey: "date", as: Date.self) == self.date)
      #expect(store.value(forKey: "missing", as: Date.self) == nil)
    }

    @Test func `A Date Keeps Milliseconds`() throws {
      let store = try makeStore()
      let precise = Date(timeIntervalSince1970: 1_795_249_800.123456)

      store.set(precise, forKey: "date")

      let stored = try #require(store.value(forKey: "date", as: Date.self))
      #expect(stored != precise)
      #expect(abs(stored.timeIntervalSince(precise)) < 0.001)
    }

    @Test(
      arguments: [
        ("2026-11-21T08:30:00Z", 1_795_249_800.0),
        ("2026-11-21T08:30:00.5Z", 1_795_249_800.5),
        ("2026-11-21T08:30:00.250+02:00", 1_795_242_600.25),
        ("2026-11-21T08:30:00+0200", 1_795_242_600.0)
      ]
    )
    func `A Date Reads Other ISO 8601 Strings`(string: String, seconds: Double) throws {
      let store = try makeStore()
      store.set(string, forKey: "date")

      #expect(store.value(forKey: "date", as: Date.self) == Date(timeIntervalSince1970: seconds))
    }

    @Test(
      arguments: [
        "", "2026-11-21", "2026-11-21 08:30:00", "2026-11-21T08:30:00",
        "2026-11-21T08:30:00Zabc", "2026-11-21T08:30:00.000Z0", "1795249800250", "tomorrow"
      ]
    )
    func `A Date Does Not Read Other Strings`(string: String) throws {
      let store = try makeStore()
      store.set(string, forKey: "date")

      #expect(store.value(forKey: "date", as: Date.self) == nil)
    }

    @Test func `A Date Does Not Read A Number`() throws {
      let store = try makeStore()
      store.set(1_795_249_800_250.0, forKey: "date")

      #expect(store.value(forKey: "date", as: Date.self) == nil)
    }

    @Test func `Milliseconds Since 1970 Are Stored As A Double`() throws {
      let store = try makeStore()

      store.set(Date.MMKVMillisecondsSince1970(self.date), forKey: "date")

      #expect(store.value(forKey: "date", as: Double.self) == 1_795_249_800_250)
      #expect(
        store.value(forKey: "date", as: Date.MMKVMillisecondsSince1970.self)?.date == self.date
      )
      #expect(store.value(forKey: "missing", as: Date.MMKVMillisecondsSince1970.self) == nil)
    }

    @Test func `Seconds Since 1970 Are Stored As A Double`() throws {
      let store = try makeStore()

      store.set(Date.MMKVSecondsSince1970(self.date), forKey: "date")

      #expect(store.value(forKey: "date", as: Double.self) == 1_795_249_800.25)
      #expect(store.value(forKey: "date", as: Date.MMKVSecondsSince1970.self)?.date == self.date)
    }

    @Test func `Seconds Since The Reference Date Are Stored As A Double`() throws {
      let store = try makeStore()

      store.set(Date.MMKVSecondsSinceReferenceDate(self.date), forKey: "date")

      #expect(
        store.value(forKey: "date", as: Double.self) == self.date.timeIntervalSinceReferenceDate
      )
      #expect(
        store.value(forKey: "date", as: Date.MMKVSecondsSinceReferenceDate.self)?.date
          == self.date
      )
    }

    @Test func `A Date Stored As A Number Also Reads An ISO 8601 String`() throws {
      let store = try makeStore()
      store.set(self.date, forKey: "date")

      #expect(
        store.value(forKey: "date", as: Date.MMKVMillisecondsSince1970.self)?.date == self.date
      )
      #expect(store.value(forKey: "date", as: Date.MMKVSecondsSince1970.self)?.date == self.date)
      #expect(
        store.value(forKey: "date", as: Date.MMKVSecondsSinceReferenceDate.self)?.date
          == self.date
      )
    }

    @Test func `Typed Keys Hold Dates`() throws {
      let store = try makeStore()
      let createdAt = MMKVStore.Key<Date>("createdAt")
      let lastSync = MMKVStore.Key<Date.MMKVMillisecondsSince1970>("lastSync")

      store[createdAt] = self.date
      store[lastSync] = .init(self.date)

      #expect(store[createdAt] == self.date)
      #expect(store[lastSync]?.date == self.date)
      #expect(store.value(forKey: "lastSync", as: Double.self) == 1_795_249_800_250)
    }

    @Test func `A Reader And Writer Carry A Date`() throws {
      struct Timestamp: MMKVValue, Equatable {
        var date: Date

        init(date: Date) { self.date = date }

        init?(from reader: borrowing MMKVValueReader) {
          guard let date = reader.date() else { return nil }
          self.date = date
        }

        func write(to writer: inout MMKVValueWriter) -> Bool {
          writer.set(self.date)
        }
      }
      let store = try makeStore()

      store.set(Timestamp(date: self.date), forKey: "date")

      #expect(store.value(forKey: "date", as: String.self) == "2026-11-21T08:30:00.250Z")
      #expect(store.value(forKey: "date", as: Timestamp.self) == Timestamp(date: self.date))
    }

    struct Profile: Codable, Equatable {
      var createdAt: Date
      var lastSync: Date.MMKVMillisecondsSince1970
      var birthday: Date.MMKVSecondsSince1970
      var updatedAt: Date.MMKVSecondsSinceReferenceDate
    }

    var profile: Profile {
      Profile(
        createdAt: self.date,
        lastSync: .init(self.date),
        birthday: .init(self.date),
        updatedAt: .init(self.date)
      )
    }

    @Test func `Key Coding Stores Dates As They Are Stored Alone`() throws {
      let store = try makeStore()

      try store.encode(self.profile, intoKeysUnder: "profile")

      #expect(
        store.value(forKey: "profile.createdAt", as: String.self) == "2026-11-21T08:30:00.250Z"
      )
      #expect(store.value(forKey: "profile.lastSync", as: Double.self) == 1_795_249_800_250)
      #expect(store.value(forKey: "profile.birthday", as: Double.self) == 1_795_249_800.25)
      #expect(
        store.value(forKey: "profile.updatedAt", as: Double.self)
          == self.date.timeIntervalSinceReferenceDate
      )
      #expect(try store.decode(Profile.self, fromKeysUnder: "profile") == self.profile)
    }

    @Test func `Key Coding Reads A Number's Date From An ISO 8601 String`() throws {
      let store = try makeStore()
      try store.encode(self.profile, intoKeysUnder: "profile")
      store.set("2026-11-21T08:30:00.250Z", forKey: "profile.lastSync")
      store.set("not a date", forKey: "profile.createdAt")

      #expect(
        try store.decode(Date.MMKVMillisecondsSince1970.self, fromKeysUnder: "profile.lastSync")
          .date == self.date
      )
      #expect {
        try store.decode(Profile.self, fromKeysUnder: "profile")
      } throws: { error in
        if case DecodingError.dataCorrupted = error { true } else { false }
      }
    }

    @Test func `A Coder Encodes A Number's Date As The Number Alone`() throws {
      struct Times: Codable, Equatable {
        var lastSync: Date.MMKVMillisecondsSince1970
        var birthday: Date.MMKVSecondsSince1970
        var updatedAt: Date.MMKVSecondsSinceReferenceDate
      }
      let whole = Date(timeIntervalSince1970: 1_795_249_800)
      let times = Times(lastSync: .init(whole), birthday: .init(whole), updatedAt: .init(whole))
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys

      let json = String(decoding: try encoder.encode(times), as: UTF8.self)

      #expect(
        json == #"{"birthday":1795249800,"lastSync":1795249800000,"updatedAt":816942600}"#
      )
      #expect(try JSONDecoder().decode(Times.self, from: Data(json.utf8)) == times)
    }
  }
#endif
