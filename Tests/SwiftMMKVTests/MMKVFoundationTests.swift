#if Foundation
  import Foundation
  import SwiftMMKV
  import Testing

  @Suite struct MMKVFoundationTests {
    struct Settings: Codable, Equatable {
      var notificationsEnabled: Bool
      var fontSize: Double
    }

    /// Writes one of the Foundation types through the writer directly.
    struct Profile: MMKVValue {
      enum Field { case data, url, uuid, decimal }

      var field: Field
      var data = Data()
      var url = URL(string: "https://example.com")!
      var uuid = UUID()
      var decimal = Decimal(1)

      init(field: Field) { self.field = field }

      init?(from reader: borrowing MMKVValueReader) { nil }

      func write(to writer: inout MMKVValueWriter) -> Bool {
        switch self.field {
        case .data: writer.set(self.data)
        case .url: writer.set(self.url)
        case .uuid: writer.set(self.uuid)
        case .decimal: writer.set(self.decimal)
        }
      }
    }

    @Test func `A Writer Stores Foundation Values As They Are Stored Alone`() throws {
      let store = try makeStore()
      var profile = Profile(field: .data)
      profile.data = Data([1, 2, 3])
      store.set(profile, forKey: "data")
      profile.field = .url
      store.set(profile, forKey: "url")
      profile.field = .uuid
      store.set(profile, forKey: "uuid")
      profile.field = .decimal
      profile.decimal = Decimal(string: "12.50")!
      store.set(profile, forKey: "decimal")
      profile.decimal = .nan

      #expect(store.value(forKey: "data", as: Data.self) == Data([1, 2, 3]))
      #expect(store.value(forKey: "url", as: URL.self) == profile.url)
      #expect(store.value(forKey: "uuid", as: UUID.self) == profile.uuid)
      #expect(store.value(forKey: "decimal", as: Decimal.self) == Decimal(string: "12.5"))
      #expect(!store.set(profile, forKey: "nan"))
    }

    @Test func `A Reader Reads Foundation Values As They Are Read Alone`() throws {
      struct Read: MMKVValue {
        var data: Data?
        var url: URL?
        var uuid: UUID?
        var decimal: Decimal?

        init?(from reader: borrowing MMKVValueReader) {
          self.data = reader.data()
          self.url = reader.url()
          self.uuid = reader.uuid()
          self.decimal = reader.decimal()
        }

        func write(to writer: inout MMKVValueWriter) -> Bool { false }
      }
      let store = try makeStore()
      let uuid = UUID()
      store.set(uuid.uuidString.lowercased(), forKey: "uuid")
      store.set("https://example.com/a", forKey: "url")
      store.set(0.1, forKey: "number")
      store.set("12abc", forKey: "text")

      let fromUUID = try #require(store.value(forKey: "uuid", as: Read.self))
      let fromURL = try #require(store.value(forKey: "url", as: Read.self))
      let fromNumber = try #require(store.value(forKey: "number", as: Read.self))
      let fromText = try #require(store.value(forKey: "text", as: Read.self))
      let missing = try #require(store.value(forKey: "missing", as: Read.self))

      #expect(fromUUID.uuid == uuid)
      #expect(fromUUID.data == Data(uuid.uuidString.lowercased().utf8))
      #expect(fromURL.url == URL(string: "https://example.com/a"))
      #expect(fromURL.uuid == nil)
      #expect(fromNumber.decimal == Decimal(string: "0.1"))
      #expect(fromText.decimal == nil)
      #expect(missing.data == nil)
      #expect(missing.url == nil)
      #expect(missing.uuid == nil)
      #expect(missing.decimal == nil)
    }

    @Test func `A URL Is Stored As Its String`() throws {
      let store = try makeStore()
      let url = try #require(URL(string: "https://example.com/a?b=c#d"))

      store.set(url, forKey: "url")
      store.set("", forKey: "invalid")

      #expect(store.value(forKey: "url", as: String.self) == "https://example.com/a?b=c#d")
      #expect(store.value(forKey: "url", as: URL.self) == url)
      #expect(store.value(forKey: "invalid", as: URL.self) == nil)
      #expect(store.value(forKey: "missing", as: URL.self) == nil)
    }

    @Test func `A UUID Is Stored As Its String`() throws {
      let store = try makeStore()
      let uuid = UUID()

      store.set(uuid, forKey: "uuid")
      store.set(uuid.uuidString.lowercased(), forKey: "lowercase")
      store.set("not a uuid", forKey: "invalid")

      #expect(store.value(forKey: "uuid", as: String.self) == uuid.uuidString)
      #expect(store.value(forKey: "uuid", as: UUID.self) == uuid)
      #expect(store.value(forKey: "lowercase", as: UUID.self) == uuid)
      #expect(store.value(forKey: "invalid", as: UUID.self) == nil)
    }

    @Test func `A Decimal Is Stored As Its String`() throws {
      let store = try makeStore()
      let decimal = try #require(Decimal(string: "-12345678901234567890.123456789"))

      store.set(decimal, forKey: "decimal")
      store.set(Decimal(string: "12.50")!, forKey: "price")

      #expect(
        store.value(forKey: "decimal", as: String.self) == "-12345678901234567890.123456789"
      )
      #expect(store.value(forKey: "decimal", as: Decimal.self) == decimal)
      #expect(store.value(forKey: "price", as: Decimal.self) == Decimal(string: "12.5"))
      #expect(store.value(forKey: "missing", as: Decimal.self) == nil)
      #expect(!store.set(Decimal.nan, forKey: "nan"))
    }

    @Test(arguments: ["1e3", "+7", ".5", "0", "1234.56", "1E-7"])
    func `A Decimal Reads Number Strings`(string: String) throws {
      let store = try makeStore()

      store.set(string, forKey: "decimal")

      #expect(store.value(forKey: "decimal", as: Decimal.self) == Decimal(string: string))
    }

    /// `Decimal(string:)` reads the number a string starts with, which must not be taken for
    /// the value of a key that holds something else.
    @Test(arguments: ["12abc", "1.2.3", "1-2", "7 days"])
    func `A Decimal Does Not Read The Start Of Another String`(string: String) throws {
      let store = try makeStore()
      let start = try #require(Decimal(string: string))

      store.set(string, forKey: "decimal")

      #expect(store.value(forKey: "decimal", as: Decimal.self) != start)
    }

    @Test(arguments: [0.1, 12.5, -3, 0, 1e-7, 1_234_567.25, 1234.56, 1e21])
    func `A Decimal Reads A Double`(double: Double) throws {
      let store = try makeStore()

      store.set(double, forKey: "number")

      #expect(store.value(forKey: "number", as: Decimal.self) == Decimal(string: "\(double)"))
    }

    @Test func `Typed Keys Hold Foundation Values`() throws {
      let store = try makeStore()
      let homepage = MMKVStore.Key<URL>("homepage")
      let price = MMKVStore.DefaultedKey<Decimal>("price", default: 0)
      let url = try #require(URL(string: "https://example.com"))

      store.set(url, for: homepage)

      #expect(store.value(for: homepage) == url)
      #expect(store.value(for: price) == 0)
    }

    @Test func `Data Round Trips As Raw Bytes`() throws {
      let store = try makeStore()
      let data = Data([0, 1, 2, 255])

      store.set(data, forKey: "data")
      store.set(Data(), forKey: "empty")

      #expect(store.value(forKey: "data", as: Data.self) == data)
      #expect(store.value(forKey: "data", as: [UInt8].self) == [0, 1, 2, 255])
      #expect(store.value(forKey: "empty", as: Data.self) == Data())
      #expect(store.value(forKey: "missing", as: Data.self) == nil)
    }

    @Test func `A URL Directory Opens The Same Store As Its Path`() throws {
      let rootDirectory = temporaryRootDirectory()
      let directory = MMKVDirectory(url: URL(fileURLWithPath: rootDirectory))
      #expect(directory == MMKVDirectory(path: rootDirectory))

      try MMKVStore(MMKVConfiguration(directory: directory, mode: .singleProcess))
        .set("value", forKey: "key")
      #expect(try makeStore(rootDirectory: rootDirectory)["key", as: String.self] == "value")
    }

    #if canImport(Darwin)
      @Test func `An App Group Without A Container Is Reported`() {
        // A test process has no app group entitlement. macOS and the simulators hand out a
        // container path anyway, so either outcome is checked.
        let identifier = "group.swift-mmkv.tests.unavailable"
        do {
          let directory = try MMKVDirectory.appGroup(identifier: identifier)
          #expect(directory.path.hasSuffix("/mmkv"))
        } catch {
          #expect(error.code == .appGroupContainerUnavailable)
          #expect(error.message.contains(identifier))
        }
      }
    #endif

    @Test func `JSON Values Are Stored As Strings JavaScript Can Parse`() throws {
      let store = try makeStore()
      let settings = Settings(notificationsEnabled: true, fontSize: 16)
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys

      #expect(try store.encode(settings, forKey: "settings", with: encoder))

      #expect(
        store.value(forKey: "settings", as: String.self)
          == #"{"fontSize":16,"notificationsEnabled":true}"#
      )
      #expect(try store.decode(Settings.self, forKey: "settings") == settings)
    }

    @Test func `Updates A JSON Value In Place`() throws {
      let store = try makeStore()
      try store.encode(Settings(notificationsEnabled: true, fontSize: 16), forKey: "settings")

      #expect(try store.update(jsonForKey: "settings", as: Settings.self) { $0?.fontSize = 18 })

      #expect(
        try store.decode(Settings.self, forKey: "settings")
          == Settings(notificationsEnabled: true, fontSize: 18)
      )
      #expect(store.value(forKey: "settings", as: String.self)?.hasPrefix("{") == true)
    }

    @Test func `A JSON Update Starts From Nil And Removes The Key When Set To Nil`() throws {
      let store = try makeStore()
      var seen = [Settings?]()
      let settings = Settings(notificationsEnabled: false, fontSize: 12)

      try store.update(jsonForKey: "settings", as: Settings.self) {
        seen.append($0)
        $0 = settings
      }
      #expect(seen == [nil])
      #expect(try store.decode(Settings.self, forKey: "settings") == settings)

      try store.update(jsonForKey: "settings", as: Settings.self) { $0 = nil }
      #expect(!store.contains("settings"))
    }

    @Test func `A JSON Update Stores JSON For A Type MMKV Also Stores Natively`() throws {
      let store = try makeStore()

      try store.update(jsonForKey: "name") { (name: inout String?) in name = "blob" }

      #expect(store.value(forKey: "name", as: String.self) == #""blob""#)
      #expect(try store.decode(String.self, forKey: "name") == "blob")
    }

    @Test func `A JSON Update Of A Value That Is Not JSON Throws Without Running The Body`()
      throws
    {
      let store = try makeStore()
      store.set("not json", forKey: "settings")
      var runs = 0

      #expect(throws: DecodingError.self) {
        try store.update(jsonForKey: "settings", as: Settings.self) { _ in runs += 1 }
      }

      #expect(runs == 0)
      #expect(store.value(forKey: "settings", as: String.self) == "not json")
    }

    @Test func `A JSON Update Of A Closed Store Throws Without Running The Body`() throws {
      let store = try makeStore(id: "json-update-closed")
      store.close()
      var runs = 0

      expectError(.storeIsClosed) {
        try store.update(jsonForKey: "settings", as: Settings.self) { _ in runs += 1 }
      }

      #expect(runs == 0)
    }

    @Test func `Reads A JSON String Written As A Plain String`() throws {
      let store = try makeStore()

      store.set(#"{"notificationsEnabled":false,"fontSize":18}"#, forKey: "settings")

      #expect(
        try store.decode(Settings.self, forKey: "settings")
          == Settings(notificationsEnabled: false, fontSize: 18)
      )
      #expect(try store.decode(Settings.self, forKey: "missing") == nil)
    }

    @Test func `A Value That Does Not Decode Throws`() throws {
      let store = try makeStore()
      store.set("not json", forKey: "garbage")

      #expect(throws: DecodingError.self) {
        try store.decode(Settings.self, forKey: "garbage")
      }
    }

    @Test func `A Value That Does Not Encode Throws And Stores Nothing`() throws {
      let store = try makeStore()

      #expect(throws: EncodingError.self) {
        try store.encode(Double.nan, forKey: "nan")
      }
      #expect(!store.contains("nan"))
    }

    @Test func `Encoding Reports A Failed Write`() throws {
      let store = try makeStore(itemSizeLimit: 16)

      #expect(try !store.encode(String(repeating: "a", count: 64), forKey: "large"))
      #expect(!store.contains("large"))
    }

    @Test func `Encoded Values Round Trip Through Other Coders`() throws {
      let store = try makeStore()
      let settings = Settings(notificationsEnabled: true, fontSize: 16)

      try store.encode(settings, forKey: "settings", with: PropertyListEncoder())

      #expect(
        try store.decode(Settings.self, forKey: "settings", with: PropertyListDecoder())
          == settings
      )
      #expect(throws: DecodingError.self) {
        try store.decode(Settings.self, forKey: "settings")
      }
    }

    @Test func `Encoding Notifies Listeners`() throws {
      let store = try makeStore()
      let recorder = ChangeRecorder()
      let subscription = store.subscribe(recorder.record)

      try store.encode([1, 2, 3], forKey: "numbers")

      #expect(recorder.all == [.key("numbers")])
      subscription.cancel()
    }

    @Test func `JSON Data Matches The Byte Form`() throws {
      let store = try makeStore(id: "json")
      store.set(1.0, forKey: "a")

      #expect(store.toJSONData() == Data(#"{"json":["a"]}"#.utf8))
    }

    @Test func `A JSON Coded Key Stores What The JSON Methods Do`() throws {
      let store = try makeStore()
      let key = MMKVStore.CodedKey<Settings>("settings")
      let settings = Settings(notificationsEnabled: true, fontSize: 16)

      #expect(try store.value(for: key) == nil)
      #expect(try store.set(settings, for: key))

      #expect(try store.value(for: key) == settings)
      #expect(try store.decode(Settings.self, forKey: "settings") == settings)
      let json = try #require(store["settings", as: String.self])
      #expect(try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) == settings)
    }

    @Test func `A JSON Coded Key Reads JSON Written As A String`() throws {
      let store = try makeStore()
      store.set(#"{"notificationsEnabled":false,"fontSize":18}"#, forKey: "settings")

      #expect(
        try store.value(for: MMKVStore.CodedKey<Settings>("settings"))
          == Settings(notificationsEnabled: false, fontSize: 18)
      )
    }

    @Test func `A JSON Coded Key Throws For A Value That Is Not JSON`() throws {
      let store = try makeStore()
      store.set("not json", forKey: "settings")

      #expect(throws: DecodingError.self) {
        try store.value(for: MMKVStore.CodedKey<Settings>("settings"))
      }
    }

    @Test func `JSON Coded Keys With The Same Name Are Equal`() {
      #expect(MMKVStore.CodedKey<Settings>("settings") == MMKVStore.CodedKey("settings"))
      #expect(MMKVStore.CodedKey<Settings>("settings") != MMKVStore.CodedKey("other"))
      #expect(
        MMKVStore.CodedKey<Settings>("settings")
          != MMKVStore.CodedKey("settings", encoder: JSONEncoder(), decoder: JSONDecoder())
      )
    }

    @Test func `A Defaulted JSON Coded Key Reads Its Default Until A Value Is Stored`() throws {
      let store = try makeStore()
      let fallback = Settings(notificationsEnabled: false, fontSize: 12)
      let key = MMKVStore.DefaultedCodedKey("settings", default: fallback)

      #expect(try store.value(for: key) == fallback)
      #expect(key == MMKVStore.DefaultedCodedKey(MMKVStore.CodedKey("settings"), default: fallback))

      try store.set(Settings(notificationsEnabled: true, fontSize: 20), for: key)

      #expect(try store.value(for: key) == Settings(notificationsEnabled: true, fontSize: 20))
    }
  }
#endif
