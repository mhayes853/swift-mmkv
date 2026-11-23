import _SwiftMMKVCore

/// The Swift core that is replacing the C++ one (`Sources/_SwiftMMKVCore`). See
/// `Docs/swift-core-migration.md`.
struct SwiftEngine: MMKVEngine {
  private let store: StoreInstance

  init(_ configuration: MMKVConfiguration) throws(MMKVError) {
    var hasWrongEncryptionKey = false
    let store = MMKVStorage(path: configuration.directory.path)
      .opening(id: configuration.id) { () -> StoreInstance? in
        do throws(StoreRegistry.OpenError) {
          return try StoreRegistry.open(
          StoreConfiguration(
            id: configuration.id.rawValue,
            rootDirectory: configuration.directory.path,
            isMultiProcess: configuration.mode == .multiProcess,
            isReadOnly: configuration.isReadOnly,
            expectedCapacity: max(configuration.expectedCapacity, 0),
            recoverOnError: configuration.recovery == .recover,
            compareBeforeSet: configuration.compareBeforeSet,
            itemSizeLimit: UInt32(clamping: configuration.itemSizeLimit ?? 0),
            encryptionKey: configuration.encryption?.key,
            isAES256: configuration.encryption?.isAES256 ?? false
          )
        )
        } catch {
          hasWrongEncryptionKey = error == .wrongEncryptionKey
          return nil
        }
      }
    if hasWrongEncryptionKey {
      throw .wrongEncryptionKey(id: configuration.id, directory: configuration.directory)
    }
    guard let store else {
      throw .openFailed(id: configuration.id, directory: configuration.directory)
    }
    self.store = store
    let instance = self.instance
    store.setContentChangedHandler {
      MMKVStoreState.markExternalChange(instance: instance)
    }
  }

  var instance: UInt {
    UInt(bitPattern: Unmanaged.passUnretained(self.store).toOpaque())
  }
}

// MARK: - Reads

extension SwiftEngine {
  func bool(forKey key: String) -> Bool? {
    self.store.bool(forKey: key)
  }

  func int32(forKey key: String) -> Int32? {
    self.store.int32(forKey: key)
  }

  func uint32(forKey key: String) -> UInt32? {
    self.store.uint32(forKey: key)
  }

  func int64(forKey key: String) -> Int64? {
    self.store.int64(forKey: key)
  }

  func uint64(forKey key: String) -> UInt64? {
    self.store.uint64(forKey: key)
  }

  func float(forKey key: String) -> Float? {
    self.store.float(forKey: key)
  }

  func double(forKey key: String) -> Double? {
    self.store.double(forKey: key)
  }

  func string(forKey key: String) -> String? {
    self.store.string(forKey: key)
  }

  func strings(forKey key: String) -> [String]? {
    self.store.strings(forKey: key)
  }

  func withBytes<R, E: Error>(
    forKey key: String,
    _ body: (RawSpan) throws(E) -> R
  ) throws(E) -> R? {
    // Copied, so that `body` runs without the store's locks held, as with the C++ core.
    guard let bytes = self.store.bytes(forKey: key) else { return nil }
    return
      try bytes.withUnsafeBytes { buffer in
        Result { () throws(E) -> R in try body(buffer.bytes) }
      }
      .get()
  }
}

// MARK: - Writes

extension SwiftEngine {
  func set(_ value: Bool, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.store.set(.bool(value), forKey: key, expiresInSeconds: expiresInSeconds)
  }

  func set(_ value: Int32, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.store.set(.int32(value), forKey: key, expiresInSeconds: expiresInSeconds)
  }

  func set(_ value: UInt32, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.store.set(.uint32(value), forKey: key, expiresInSeconds: expiresInSeconds)
  }

  func set(_ value: Int64, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.store.set(.int64(value), forKey: key, expiresInSeconds: expiresInSeconds)
  }

  func set(_ value: UInt64, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.store.set(.uint64(value), forKey: key, expiresInSeconds: expiresInSeconds)
  }

  func set(_ value: Float, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.store.set(.float(value), forKey: key, expiresInSeconds: expiresInSeconds)
  }

  func set(_ value: Double, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.store.set(.double(value), forKey: key, expiresInSeconds: expiresInSeconds)
  }

  func set(_ value: String, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    var value = value
    return value.withUTF8 { utf8 in
      self.store.set(
        .bytes(UnsafeRawBufferPointer(utf8)),
        forKey: key,
        expiresInSeconds: expiresInSeconds
      )
    }
  }

  func set(_ value: [String], forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.store.set(.strings(value), forKey: key, expiresInSeconds: expiresInSeconds)
  }

  func set(bytes: RawSpan, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    bytes.withUnsafeBytes { buffer in
      self.store.set(.bytes(buffer), forKey: key, expiresInSeconds: expiresInSeconds)
    }
  }
}

// MARK: - Keys

extension SwiftEngine {
  var count: Int {
    self.store.count
  }

  var keys: Set<String> {
    Set(self.store.keys)
  }

  func contains(_ key: String) -> Bool {
    self.store.contains(key)
  }

  func remove(_ key: String) -> Bool {
    self.store.removeValue(forKey: key)
  }

  func remove(_ keys: [String]) {
    self.store.removeValues(forKeys: keys)
  }

  func removeAll(keepingCapacity: Bool) {
    self.store.clearAll(keepSpace: keepingCapacity)
  }

  func importAll(from source: any MMKVEngine) -> Int {
    // Both stores of an import are opened by one configuration's engine.
    guard let source = source as? SwiftEngine else { return 0 }
    return self.store.importAll(from: source.store)
  }
}

// MARK: - Locking and maintenance

extension SwiftEngine {
  func lock() {
    self.store.lockExclusively()
  }

  func unlock() {
    self.store.unlockExclusively()
  }

  var totalSize: Int {
    self.store.totalSize
  }

  var actualSize: Int {
    self.store.dataSize
  }

  func checkContentChanged() {
    self.store.checkContentChanged()
  }

  func trim() {
    self.store.trim()
  }

  func sync() {
    self.store.sync()
  }

  func rekey(_ encryption: MMKVConfiguration.Encryption?) -> Bool {
    self.store.rekey(key: encryption?.key, isAES256: encryption?.isAES256 ?? false)
  }
}
