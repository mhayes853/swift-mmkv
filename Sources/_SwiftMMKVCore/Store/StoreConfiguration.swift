/// How to open a store, as the package's C interface describes it to MMKV (`mmkv_configuration`
/// and MMKV's `MMKVConfig`).
package struct StoreConfiguration: Sendable {
  package var id: String
  package var rootDirectory: String
  package var isMultiProcess: Bool
  package var isReadOnly: Bool
  /// The size in bytes to create the data file with, rounded up to whole pages.
  package var expectedCapacity: Int
  /// Whether to keep what can be read from a file that fails its integrity check, rather than
  /// discarding it.
  package var recoverOnError: Bool
  package var compareBeforeSet: Bool
  /// The largest key-value pair the store accepts, or 0 for no limit.
  package var itemSizeLimit: UInt32
  /// The key the store is encrypted with, or `nil` for a plain-text store.
  package var encryptionKey: [UInt8]?
  /// Whether `encryptionKey` is an AES-256 key rather than an AES-128 one.
  package var isAES256: Bool
  package var fileSystem: FileSystem

  package init(
    id: String,
    rootDirectory: String,
    isMultiProcess: Bool,
    isReadOnly: Bool = false,
    expectedCapacity: Int = 0,
    recoverOnError: Bool = false,
    compareBeforeSet: Bool = false,
    itemSizeLimit: UInt32 = 0,
    encryptionKey: [UInt8]? = nil,
    isAES256: Bool = false,
    fileSystem: FileSystem = .live
  ) {
    self.id = id
    self.rootDirectory = rootDirectory
    self.isMultiProcess = isMultiProcess
    self.isReadOnly = isReadOnly
    self.expectedCapacity = expectedCapacity
    self.recoverOnError = recoverOnError
    self.compareBeforeSet = compareBeforeSet
    self.itemSizeLimit = itemSizeLimit
    self.encryptionKey = encryptionKey
    self.isAES256 = isAES256
    self.fileSystem = fileSystem
  }
}
