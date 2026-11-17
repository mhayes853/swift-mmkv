/// A directory that holds MMKV stores.
///
/// A directory is only a path. Creating one touches nothing on disk, and two directories with
/// the same path are the same directory.
///
/// ```swift
/// let directory = MMKVDirectory(path: "/path/to/app/files/mmkv")
/// let store = try MMKVStore(MMKVConfiguration(directory: directory, mode: .singleProcess))
/// ```
public struct MMKVDirectory: Sendable, Hashable {
  /// The directory's path.
  public var path: String

  /// Creates a directory from its path.
  public init(path: String) {
    self.path = path
  }
}

extension MMKVDirectory {
  /// The directory react-native-mmkv keeps its stores in on Android when its `path` option is
  /// not set, which is the `mmkv` directory inside the app's files directory.
  ///
  /// - Parameter filesDirectory: The path of the app's `Context.getFilesDir()`.
  public static func reactNative(filesDirectory: String) -> MMKVDirectory {
    let separator = filesDirectory.hasSuffix("/") ? "" : "/"
    return MMKVDirectory(path: filesDirectory + separator + "mmkv")
  }
}
