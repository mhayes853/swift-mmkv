#if Foundation
  import _SwiftMMKVFoundation

  extension Data: MMKVValue {
    public init?(from reader: borrowing MMKVValueReader) {
      let data = reader.withBytes { span in
        span.withUnsafeBytes { Data($0) }
      }
      guard let data else { return nil }
      self = data
    }

    public func write(to writer: inout MMKVValueWriter) -> Bool {
      self.withUnsafeBytes { writer.set(bytes: $0.bytes) }
    }
  }

  extension MMKVConfiguration {
    /// Creates a configuration whose root directory is a file URL. The parameters are those of
    /// the initializer that takes the directory as a path.
    public init(
      id: String = MMKVConfiguration.defaultID,
      rootDirectory: URL,
      mode: Mode,
      isReadOnly: Bool = false,
      encryption: Encryption? = nil,
      expectedCapacity: Int = 0,
      recovery: Recovery = .discard,
      compareBeforeSet: Bool = false,
      itemSizeLimit: Int? = nil
    ) {
      self.init(
        id: id,
        rootDirectory: rootDirectory.path,
        mode: mode,
        isReadOnly: isReadOnly,
        encryption: encryption,
        expectedCapacity: expectedCapacity,
        recovery: recovery,
        compareBeforeSet: compareBeforeSet,
        itemSizeLimit: itemSizeLimit
      )
    }
  }

  #if canImport(Darwin)
    extension MMKVConfiguration {
      /// The directory react-native-mmkv keeps its stores in when its `path` option is not set.
      ///
      /// That is the app group's container when the app's `Info.plist` has an
      /// `AppGroupIdentifier` key, and otherwise the `mmkv` directory inside the app's Documents
      /// directory, or inside its Caches directory on tvOS.
      ///
      /// On Android the directory depends on the app's `Context`, so the app passes it instead:
      /// react-native-mmkv uses `context.filesDir` followed by `/mmkv`.
      ///
      /// - Throws: ``MMKVError/appGroupContainerUnavailable(identifier:)`` if the app group named
      ///   in `Info.plist` has no container this process can reach.
      public static func reactNativeRootDirectory() throws(MMKVError) -> String {
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
          return container.path
        }
        #if os(tvOS)
          let directory = FileManager.SearchPathDirectory.cachesDirectory
        #else
          let directory = FileManager.SearchPathDirectory.documentDirectory
        #endif
        let base =
          FileManager.default.urls(for: directory, in: .userDomainMask).first
          ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("mmkv", isDirectory: true).path
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
#endif
