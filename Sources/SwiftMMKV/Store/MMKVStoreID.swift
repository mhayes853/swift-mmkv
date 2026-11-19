extension MMKVStore {
  /// The identifier of a store, which names its files inside an ``MMKVDirectory``.
  ///
  /// Extend this type to name your app's stores in one place.
  ///
  /// ```swift
  /// extension MMKVStore.ID {
  ///   static let settings: Self = "settings"
  ///   static func user(_ userID: String) -> Self { "user.\(userID)" }
  /// }
  ///
  /// let configuration = MMKVConfiguration(id: .settings, directory: directory, mode: .singleProcess)
  /// ```
  ///
  /// An identifier is not validated when it is created. Opening a store with an empty
  /// identifier fails.
  public struct ID: RawRepresentable, Hashable, Sendable, Codable {
    /// The identifier as MMKV, and react-native-mmkv, know it.
    public var rawValue: String

    /// Creates an identifier from the string MMKV knows the store by.
    public init(rawValue: String) {
      self.rawValue = rawValue
    }

    /// The identifier react-native-mmkv, and MMKV itself, use for the default store.
    public static let `default` = Self(rawValue: "mmkv.default")
  }
}

extension MMKVStore.ID: Comparable {
  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

extension MMKVStore.ID: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
  public init(stringLiteral value: String) {
    self.init(rawValue: value)
  }
}

extension MMKVStore.ID: CustomStringConvertible {
  public var description: String {
    self.rawValue
  }
}
