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

  // MARK: - JSON values

  extension MMKVStore {
    /// Stores `value` under `key` as a JSON string, which is how React Native apps store objects.
    ///
    /// ```swift
    /// store.set(json: Settings(fontSize: 16), forKey: "settings")
    /// // JavaScript: JSON.parse(storage.getString('settings'))
    /// ```
    ///
    /// - Returns: Whether the value was encoded and stored.
    @discardableResult
    public func set<V: Encodable>(
      json value: V,
      forKey key: String,
      encoder: JSONEncoder = JSONEncoder(),
      expiringIn: Duration? = nil
    ) -> Bool {
      guard let data = try? encoder.encode(value) else { return false }
      // MMKV stores a string as its UTF-8 bytes, so this is read back as a string.
      return data.withUnsafeBytes { buffer in
        self.set(bytes: buffer.bytes, forKey: key, expiringIn: expiringIn)
      }
    }

    /// Reads the JSON string stored under `key` and decodes it as a `V`.
    ///
    /// - Returns: The value, or `nil` if the key has no value or its value does not decode.
    public func value<V: Decodable>(
      forKey key: String,
      asJSON type: V.Type = V.self,
      decoder: JSONDecoder = JSONDecoder()
    ) -> V? {
      let data = self.withBytes(forKey: key) { span in
        span.withUnsafeBytes { Data($0) }
      }
      guard let data else { return nil }
      return try? decoder.decode(type, from: data)
    }

    /// The store's identifier and keys as JSON. See ``toJSON()``.
    public func toJSONData() -> Data {
      Data(self.toJSON())
    }
  }
#endif
