#if Foundation
  import Foundation
  import SwiftMMKV
  import Testing

  @Suite struct MMKVFoundationTests {
    struct Settings: Codable, Equatable {
      var notificationsEnabled: Bool
      var fontSize: Double
    }

    enum Theme: String, MMKVValue, Decodable {
      case light, dark
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

      #expect(store.set(json: settings, forKey: "settings", encoder: encoder))

      #expect(
        store.value(forKey: "settings", as: String.self)
          == #"{"fontSize":16,"notificationsEnabled":true}"#
      )
      #expect(store.value(forKey: "settings", asJSON: Settings.self) == settings)
    }

    @Test func `Reads A JSON String Written As A Plain String`() throws {
      let store = try makeStore()

      store.set(#"{"notificationsEnabled":false,"fontSize":18}"#, forKey: "settings")
      store.set("not json", forKey: "garbage")

      #expect(
        store.value(forKey: "settings", asJSON: Settings.self)
          == Settings(notificationsEnabled: false, fontSize: 18)
      )
      #expect(store.value(forKey: "garbage", asJSON: Settings.self) == nil)
      #expect(store.value(forKey: "missing", asJSON: Settings.self) == nil)
    }

    @Test func `JSON Writes Notify Listeners`() throws {
      let store = try makeStore()
      let recorder = ChangeRecorder()
      let subscription = store.subscribe(recorder.record)

      store.set(json: [1, 2, 3], forKey: "numbers")

      #expect(recorder.all == [.key("numbers")])
      subscription.cancel()
    }

    @Test func `JSON Data Matches The Byte Form`() throws {
      let store = try makeStore(id: "json")
      store.set(1.0, forKey: "a")

      #expect(store.toJSONData() == Data(#"{"json":["a"]}"#.utf8))
    }
  }

  @Suite struct MMKVStoreDecodingTests {
    typealias Settings = MMKVFoundationTests.Settings
    typealias Theme = MMKVFoundationTests.Theme

    struct ExactState: Decodable, Equatable {
      var hasOnboarded: Bool
      var volume: Double
      var ratio: Float
      var launchCount: Int
      var small: Int8
      var identifier: UInt64
      var username: String
      var nickname: String?
      var theme: Theme
      var avatar: Data
      var tags: [String]
      var settings: Settings

      enum CodingKeys: String, CodingKey {
        case hasOnboarded, volume, ratio, launchCount, small, identifier, username, nickname
        case theme, avatar, tags
        case settings = "user.settings"
      }
    }

    struct JavaScriptState: Decodable, Equatable {
      var hasOnboarded: Bool
      var volume: Double
      var launchCount: Int
      var ratio: Float
      var level: UInt8
      var username: String?
      var settings: Settings?
    }

    @Test func `Decodes A Whole Store With Exact Number Encodings`() throws {
      let store = try makeStore()
      store.set(true, forKey: "hasOnboarded")
      store.set(0.8, forKey: "volume")
      store.set(Float(0.25), forKey: "ratio")
      store.set(Int64(42), forKey: "launchCount")
      store.set(Int32(-7), forKey: "small")
      store.set(UInt64.max, forKey: "identifier")
      store.set("blob", forKey: "username")
      store.set(Theme.dark, forKey: "theme")
      store.set(Data([1, 2, 3]), forKey: "avatar")
      store.set(["a", "b"], forKey: "tags")
      store.set(json: Settings(notificationsEnabled: true, fontSize: 16), forKey: "user.settings")
      store.set("ignored", forKey: "unrelated")

      let state = try store.decode(ExactState.self)

      #expect(
        state
          == ExactState(
            hasOnboarded: true,
            volume: 0.8,
            ratio: 0.25,
            launchCount: 42,
            small: -7,
            identifier: .max,
            username: "blob",
            nickname: nil,
            theme: .dark,
            avatar: Data([1, 2, 3]),
            tags: ["a", "b"],
            settings: Settings(notificationsEnabled: true, fontSize: 16)
          )
      )
    }

    @Test func `Decodes A Store Written By JavaScript`() throws {
      let store = try makeStore()
      store.set(true, forKey: "hasOnboarded")
      store.set(0.8, forKey: "volume")
      store.set(3.0, forKey: "launchCount")
      store.set(0.5, forKey: "ratio")
      store.set(200.0, forKey: "level")
      store.set(#"{"notificationsEnabled":true,"fontSize":16}"#, forKey: "settings")

      let state = try store.decode(JavaScriptState.self, numbers: .javaScript)

      #expect(
        state
          == JavaScriptState(
            hasOnboarded: true,
            volume: 0.8,
            launchCount: 3,
            ratio: 0.5,
            level: 200,
            username: nil,
            settings: Settings(notificationsEnabled: true, fontSize: 16)
          )
      )
    }

    @Test func `A JavaScript Number That Does Not Fit Fails To Decode`() throws {
      struct Count: Decodable { var count: Int }
      struct Level: Decodable { var level: UInt8 }
      let store = try makeStore()
      store.set(1.5, forKey: "count")
      store.set(300.0, forKey: "level")

      #expect(throws: DecodingError.self) {
        try store.decode(Count.self, numbers: .javaScript)
      }
      #expect(throws: DecodingError.self) {
        try store.decode(Level.self, numbers: .javaScript)
      }
    }

    @Test func `A Missing Required Key Throws Key Not Found`() throws {
      struct State: Decodable { var username: String }
      let store = try makeStore()

      let error = #expect(throws: DecodingError.self) {
        try store.decode(State.self)
      }
      guard case .keyNotFound(let key, _) = error else {
        Issue.record("Expected keyNotFound, got \(String(describing: error))")
        return
      }
      #expect(key.stringValue == "username")
    }

    @Test func `An Invalid Value Throws Data Corrupted Naming The Key`() throws {
      struct State: Decodable { var theme: Theme }
      struct Nested: Decodable { var settings: Settings }
      let store = try makeStore()
      store.set("sepia", forKey: "theme")
      store.set(#"{"notificationsEnabled":"yes"}"#, forKey: "settings")

      let themeError = #expect(throws: DecodingError.self) { try store.decode(State.self) }
      guard case .dataCorrupted(let context) = themeError else {
        Issue.record("Expected dataCorrupted, got \(String(describing: themeError))")
        return
      }
      #expect(context.codingPath.map(\.stringValue) == ["theme"])

      let nestedError = #expect(throws: DecodingError.self) { try store.decode(Nested.self) }
      guard case .typeMismatch(_, let nestedContext) = nestedError else {
        Issue.record("Expected typeMismatch, got \(String(describing: nestedError))")
        return
      }
      #expect(nestedContext.codingPath.map(\.stringValue) == ["settings", "notificationsEnabled"])
    }

    @Test func `A Type That Is Not Keyed Fails To Decode`() throws {
      let store = try makeStore()
      store.set("value", forKey: "key")

      #expect(throws: DecodingError.self) { try store.decode([String].self) }
      #expect(throws: DecodingError.self) { try store.decode(String.self) }
    }

    @Test func `A Dictionary Decodes Every Key As One Type`() throws {
      let store = try makeStore()
      store.set(1.0, forKey: "a")
      store.set(2.0, forKey: "b")

      #expect(try store.decode([String: Double].self) == ["a": 1, "b": 2])
    }
  }
#endif
