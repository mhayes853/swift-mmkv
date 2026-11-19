#if Foundation
  import Foundation
  @_spi(Engines) import SwiftMMKV
  import Testing

  @Suite(.requires(.store)) struct MMKVFoundationTests {
    struct Settings: Codable, Equatable {
      var notificationsEnabled: Bool
      var fontSize: Double
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

      var configuration = MMKVConfiguration(directory: directory, mode: .singleProcess)
      configuration.engine = engineUnderTest
      try MMKVStore(configuration).set("value", forKey: "key")
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
          #expect(error == .appGroupContainerUnavailable(identifier: identifier))
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
