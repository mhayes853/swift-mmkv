#if Foundation
  import Foundation
  import SwiftMMKV
  import Testing

  @Suite struct MMKVFoundationTests {
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

    @Test func `A URL Root Directory Opens The Same Store As Its Path`() throws {
      let rootDirectory = temporaryRootDirectory()
      let configuration = MMKVConfiguration(
        rootDirectory: URL(fileURLWithPath: rootDirectory),
        mode: .singleProcess
      )
      #expect(
        configuration == MMKVConfiguration(rootDirectory: rootDirectory, mode: .singleProcess)
      )

      try MMKVStore(configuration).set("value", forKey: "key")
      #expect(try makeStore(rootDirectory: rootDirectory)["key", as: String.self] == "value")
    }

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
  }
#endif
