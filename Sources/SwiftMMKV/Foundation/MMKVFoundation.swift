#if Foundation
  import _SwiftMMKVFoundation

  extension Data: MMKVValue {
    public init?(from reader: borrowing MMKVValueReader) {
      guard let data = reader.data() else { return nil }
      self = data
    }

    public func write(to writer: inout MMKVValueWriter) -> Bool {
      writer.set(self)
    }
  }

  extension MMKVValueReader {
    /// Reads the key as raw bytes, copied into a `Data`.
    ///
    /// A string value reads as its UTF-8 bytes, because MMKV stores the two the same way.
    public func data() -> Data? {
      self.withBytes { span in
        span.withUnsafeBytes { Data($0) }
      }
    }
  }

  extension MMKVValueWriter {
    /// Stores the bytes of `value`, which JavaScript reads with `getBuffer`.
    public mutating func set(_ value: Data) -> Bool {
      value.withUnsafeBytes { self.set(bytes: $0.bytes) }
    }
  }

  extension MMKVDirectory {
    /// Creates a directory from a file URL.
    public init(url: URL) {
      self.init(path: url.path)
    }
  }

  #if canImport(Darwin)
    extension MMKVDirectory {
      /// The `mmkv` directory inside an app group's container, for stores an app shares with
      /// its extensions.
      ///
      /// ```swift
      /// let store = try MMKVStore(
      ///   MMKVConfiguration(
      ///     directory: .appGroup(identifier: "group.com.example.app"),
      ///     mode: .multiProcess
      ///   )
      /// )
      /// ```
      ///
      /// The app and each extension are separate processes, so every one of them must open
      /// the store in multi-process mode.
      ///
      /// react-native-mmkv keeps an app group's stores in the container itself rather than in
      /// a directory of their own. Use ``reactNative()`` for a store shared with JavaScript.
      ///
      /// - Throws: ``MMKVError/appGroupContainerUnavailable(identifier:)`` if the app group has
      ///   no container this process can reach.
      public static func appGroup(identifier: String) throws(MMKVError) -> MMKVDirectory {
        guard
          let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
          )
        else {
          throw .appGroupContainerUnavailable(identifier: identifier)
        }
        return MMKVDirectory(url: container.appendingPathComponent("mmkv", isDirectory: true))
      }
    }

    extension MMKVDirectory {
      /// The directory react-native-mmkv keeps its stores in on Apple platforms when its `path`
      /// option is not set.
      ///
      /// That is the app group's container when the app's `Info.plist` has an
      /// `AppGroupIdentifier` key, and otherwise the `mmkv` directory inside the app's Documents
      /// directory, or inside its Caches directory on tvOS.
      ///
      /// On Android the directory depends on the app's `Context`, so the app passes its files
      /// directory to ``reactNative(filesDirectory:)`` instead.
      ///
      /// - Throws: ``MMKVError/appGroupContainerUnavailable(identifier:)`` if the app group named
      ///   in `Info.plist` has no container this process can reach.
      public static func reactNative() throws(MMKVError) -> MMKVDirectory {
        if let identifier = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier")
          as? String
        {
          guard
            let container = FileManager.default.containerURL(
              forSecurityApplicationGroupIdentifier: identifier
            )
          else {
            throw .appGroupContainerUnavailable(identifier: identifier)
          }
          return MMKVDirectory(url: container)
        }
        #if os(tvOS)
          let directory = FileManager.SearchPathDirectory.cachesDirectory
        #else
          let directory = FileManager.SearchPathDirectory.documentDirectory
        #endif
        let base =
          FileManager.default.urls(for: directory, in: .userDomainMask).first
          ?? FileManager.default.temporaryDirectory
        return MMKVDirectory(url: base.appendingPathComponent("mmkv", isDirectory: true))
      }
    }
  #endif

  // MARK: - Coders

  extension JSONEncoder: MMKVTopLevelEncoder {}
  extension JSONDecoder: MMKVTopLevelDecoder {}
  extension PropertyListEncoder: MMKVTopLevelEncoder {}
  extension PropertyListDecoder: MMKVTopLevelDecoder {}

  extension MMKVStore {
    /// Stores `value` under `key` as a JSON string, which is how React Native apps store objects.
    ///
    /// ```swift
    /// try store.encode(Settings(fontSize: 16), forKey: "settings")
    /// // JavaScript: JSON.parse(storage.getString('settings'))
    /// ```
    ///
    /// - Returns: Whether the encoded value was stored.
    /// - Throws: An `EncodingError` if `value` does not encode, in which case nothing is stored.
    @discardableResult
    public func encode<T: Encodable>(
      _ value: T,
      forKey key: String,
      expiringIn: Duration? = nil
    ) throws -> Bool {
      try self.encode(value, forKey: key, expiringIn: expiringIn, with: JSONEncoder())
    }

    /// Reads the JSON string stored under `key` and decodes it as a `T`.
    ///
    /// - Returns: The value, or `nil` if the key has no value.
    /// - Throws: A `DecodingError` if the stored value does not decode.
    public func decode<T: Decodable>(_ type: T.Type = T.self, forKey key: String) throws -> T? {
      try self.decode(type, forKey: key, with: JSONDecoder())
    }

    /// The store's identifier and keys as JSON. See ``toJSON()``.
    public func toJSONData() -> Data {
      Data(self.toJSON())
    }
  }

  // MARK: - JSON keys

  extension MMKVStore.CodedKey {
    /// Creates a key for a value stored as a JSON string, which is how React Native apps store
    /// objects.
    ///
    /// ```swift
    /// extension MMKVStore.CodedKey where Value == Settings {
    ///   static let settings = Self("settings")
    /// }
    ///
    /// try store.set(Settings(fontSize: 16), for: .settings)
    /// // JavaScript: JSON.parse(storage.getString('settings'))
    /// ```
    ///
    /// Every key made this way shares one `JSONEncoder` and one `JSONDecoder`, both with their
    /// default settings, so two such keys with the same name are equal. For other settings,
    /// such as a date strategy, pass coders to ``init(_:as:encoder:decoder:)``.
    ///
    /// - Parameters:
    ///   - name: The key in the store, which must not be empty.
    ///   - type: The type the value is read and written as.
    public init(_ name: String, as type: Value.Type = Value.self) {
      self.init(name, as: type, encoder: JSONCoders.encoder, decoder: JSONCoders.decoder)
    }
  }

  extension MMKVStore.DefaultedCodedKey {
    /// Creates a key for a value stored as a JSON string, which reads `defaultValue` when the
    /// store has no value for `name`. See ``MMKVStore/CodedKey/init(_:as:)``.
    ///
    /// ```swift
    /// extension MMKVStore.DefaultedCodedKey where Value == Settings {
    ///   static let settings = Self("settings", default: Settings())
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - name: The key in the store, which must not be empty.
    ///   - defaultValue: The value to read when the store has none.
    public init(_ name: String, default defaultValue: Value) {
      self.init(MMKVStore.CodedKey(name), default: defaultValue)
    }
  }

  // MARK: - JSON arrays

  extension MMKVKeyCodingOptions.Arrays {
    /// Every array is stored as a JSON string, which is how React Native apps store arrays.
    ///
    /// ```swift
    /// try store.encode(Search(recent: ["a", "b"]), intoKeysUnder: "search")
    /// // JavaScript: JSON.parse(storage.getString('search.recent'))
    /// ```
    public static var json: Self {
      .coded(encoder: JSONCoders.encoder, decoder: JSONCoders.decoder)
    }
  }

  /// The coders every JSON key shares, so that such keys compare by name.
  private enum JSONCoders {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()
  }
#endif
