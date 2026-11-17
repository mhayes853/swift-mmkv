// One open store: the Swift port of MMKV's `MMKV` class (MMKV.cpp, MMKV_IO.cpp, MMKV_Android.cpp)
// together with what the package's C shim (SwiftMMKVShim.cpp) adds around it.
//
// The port follows the C++ closely, function by function, so that both cores write the same
// bytes for the same operations. Where the C++ names a function, the Swift one has the same name.
// Encryption is not ported yet.

/// One open store. Every open of the same files in a process shares one instance, which
/// ``StoreRegistry`` hands out, and an instance lives for the rest of the process.
///
/// Thread-safe: every operation takes ``lock``, a recursive mutex, and a multi-process store also
/// takes a file lock that excludes other processes and other copies of MMKV.
package final class StoreInstance: @unchecked Sendable {
  package let id: String
  let path: String
  let crcPath: String
  package let isMultiProcess: Bool
  package let isReadOnly: Bool
  let expectedCapacity: Int
  let fileSystem: FileSystem

  /// Where each key's latest record is in a plain-text store (`m_dic`).
  var dic = [StoreKey: RecordLocation]()
  /// Each key's entry in an encrypted store (`m_dicCrypt`).
  var dicCrypt = [StoreKey: CryptEntry]()
  /// The cryptor of an encrypted store, whose state is the end of the data (`m_crypter`).
  var crypter: AESCryptor?
  /// The stream's state where the last appended record started, if its value is left in the file
  /// (`t_status`).
  var appendState: CipherState?
  let file: MemoryFile
  let metaFile: MemoryFile
  var metaInfo = MetaInfo()
  /// Where the next record is written (`m_output`), relative to the start of the data.
  var output: OutputState?
  /// How many bytes of data follow the header (`m_actualSize`).
  var actualSize = 0
  var crcDigest: UInt32 = 0
  var needLoadFromFile = true
  var hasFullWriteback = false
  var isSecondLoad = false

  let lock = ThreadLock()
  let fileLock: FileLock
  var sharedProcessLock: InterProcessLock
  var exclusiveProcessLock: InterProcessLock
  #if os(Android)
    /// Held shared for the instance's life, so that Android's MMKV knows the file is in use and
    /// does not migrate it to another name.
    private let migrationLock: FileLock?
  #endif

  let recoverOnError: Bool
  let itemSizeLimit: UInt32
  var enableKeyExpire = false
  var expiredInSeconds: UInt32 = 0
  var enableCompareBeforeSet = false

  private var contentChangedHandler: (@Sendable () -> Void)?

  /// The position and size of the output, as `CodedOutputData` keeps them. The size is fixed when
  /// the output is created, as the C++ one is.
  struct OutputState {
    var position: Int
    let size: Int

    var spaceLeft: Int {
      self.size <= self.position ? 0 : self.size - self.position
    }
  }

  init(_ configuration: StoreConfiguration, root: String) {
    self.id = configuration.id
    self.isMultiProcess = configuration.isMultiProcess
    self.isReadOnly = configuration.isReadOnly
    self.fileSystem = configuration.fileSystem
    let relative = StorePaths.relativeDataPath(id: configuration.id)
    if relative.isSpecial {
      // encodeFilePath creates the directory whether or not the store is read-only.
      makeDirectories("\(root)/\(StorePaths.specialCharacterDirectoryName)")
    }
    self.path = "\(root)/\(relative.path)"
    self.crcPath = StorePaths.metaPath(dataPath: self.path)
    self.expectedCapacity = max(
      pageSize,
      roundUp(max(configuration.expectedCapacity, 0), toMultipleOf: pageSize)
    )
    self.file = MemoryFile(
      path: self.path,
      expectedCapacity: self.expectedCapacity,
      isReadOnly: configuration.isReadOnly,
      isMayflyFD: true,
      fileSystem: configuration.fileSystem
    )
    #if os(Android)
      // Android keeps the metadata file open, and always locks it with flock.
      self.metaFile = MemoryFile(
        path: self.crcPath,
        expectedCapacity: pageSize,
        isReadOnly: configuration.isReadOnly,
        isMayflyFD: false,
        fileSystem: configuration.fileSystem
      )
      self.fileLock = FileLock(
        descriptor: self.metaFile.fileDescriptor,
        fileSystem: configuration.fileSystem
      )
      let migrationLock = FileLock(
        descriptor: self.metaFile.fileDescriptor,
        kind: .openFileDescription(start: 2, length: 3),
        fileSystem: configuration.fileSystem
      )
      _ = migrationLock.tryLock(.shared)
      self.migrationLock = migrationLock
    #else
      self.metaFile = MemoryFile(
        path: self.crcPath,
        isReadOnly: configuration.isReadOnly,
        isMayflyFD: !configuration.isMultiProcess,
        fileSystem: configuration.fileSystem
      )
      self.fileLock = FileLock(
        descriptor: configuration.isMultiProcess ? self.metaFile.fileDescriptor : -1,
        fileSystem: configuration.fileSystem
      )
    #endif
    self.sharedProcessLock = InterProcessLock(fileLock: self.fileLock, type: .shared)
    self.exclusiveProcessLock = InterProcessLock(fileLock: self.fileLock, type: .exclusive)
    self.sharedProcessLock.isEnabled = configuration.isMultiProcess
    self.exclusiveProcessLock.isEnabled = configuration.isMultiProcess
    self.recoverOnError = configuration.recoverOnError
    self.itemSizeLimit = configuration.itemSizeLimit
    if let key = configuration.encryptionKey, !key.isEmpty {
      self.crypter = AESCryptor(key: key, isAES256: configuration.isAES256)
    }
    // Compare-before-set does nothing in an encrypted store.
    if configuration.compareBeforeSet && self.crypter == nil {
      self.enableCompareBeforeSet = true
    }
  }

  /// Called with the instance's locks held when it notices that another process, or another copy
  /// of MMKV, changed its files (`onContentChangedByOuterProcess`).
  package func setContentChangedHandler(_ handler: (@Sendable () -> Void)?) {
    self.lock.withLock { self.contentChangedHandler = handler }
  }

  func notifyContentChanged() {
    self.contentChangedHandler?()
  }

  var isFileValid: Bool {
    self.file.isFileValid
  }

  var isCompareBeforeSetEnabled: Bool {
    self.enableCompareBeforeSet && !self.enableKeyExpire && self.crypter == nil
  }

  /// The number of keys in the index.
  var indexCount: Int {
    self.crypter == nil ? self.dic.count : self.dicCrypt.count
  }

  /// Runs `body` holding both the instance's lock and its file lock of `type`.
  func withLocks<R>(_ type: LockType, _ body: () -> R) -> R {
    self.lock.withLock {
      let processLock = type == .shared ? self.sharedProcessLock : self.exclusiveProcessLock
      return processLock.withLock(body)
    }
  }
}

// MARK: - Reads

extension StoreInstance {
  /// Calls `body` with the value stored under `key`, without its expiry time, while the locks are
  /// held, as each of MMKV's typed getters does.
  ///
  /// - Returns: `nil` if the key has no value or `body` cannot read it.
  package func withValue<R>(
    forKey key: StoreKey,
    _ body: (UnsafeRawBufferPointer) throws(CodingError) -> R
  ) -> R? {
    guard !key.bytes.isEmpty else { return nil }
    return self.withLocks(.shared) {
      let data = self.getDataForKey(key)
      guard data.count > 0 else { return nil }
      do throws(CodingError) {
        return try data.withBytes(body)
      } catch {
        Log.error("cannot read the value of a key in [\(self.id)]: \(error)")
        return nil
      }
    }
  }

  package func bool(forKey key: StoreKey) -> Bool? {
    self.withValue(forKey: key) { (data) throws(CodingError) in try ValueDecoding.bool(data) }
  }

  package func int32(forKey key: StoreKey) -> Int32? {
    self.withValue(forKey: key) { (data) throws(CodingError) in try ValueDecoding.int32(data) }
  }

  package func uint32(forKey key: StoreKey) -> UInt32? {
    self.withValue(forKey: key) { (data) throws(CodingError) in try ValueDecoding.uint32(data) }
  }

  package func int64(forKey key: StoreKey) -> Int64? {
    self.withValue(forKey: key) { (data) throws(CodingError) in try ValueDecoding.int64(data) }
  }

  package func uint64(forKey key: StoreKey) -> UInt64? {
    self.withValue(forKey: key) { (data) throws(CodingError) in try ValueDecoding.uint64(data) }
  }

  package func float(forKey key: StoreKey) -> Float? {
    self.withValue(forKey: key) { (data) throws(CodingError) in try ValueDecoding.float(data) }
  }

  package func double(forKey key: StoreKey) -> Double? {
    self.withValue(forKey: key) { (data) throws(CodingError) in try ValueDecoding.double(data) }
  }

  /// The bytes of a string or of raw bytes, copied out of the file.
  package func bytes(forKey key: StoreKey) -> [UInt8]? {
    self.withValue(forKey: key) { (data) throws(CodingError) in Array(try ValueDecoding.bytes(data))
    }
  }

  package func strings(forKey key: StoreKey) -> [String]? {
    self.withValue(forKey: key) { (data) throws(CodingError) in try ValueDecoding.strings(data) }
  }
}

// MARK: - Writes

extension StoreInstance {
  /// Stores `value` under `key`, as the package's `mmkv_set_*` functions do: a read-only store
  /// refuses the write, and an expiring write first turns on expiry for the whole store.
  ///
  /// - Parameter expiresInSeconds: How long to keep the value, or 0 to keep it until it is removed.
  package func set(_ value: EncodedValue, forKey key: StoreKey, expiresInSeconds: UInt32) -> Bool {
    // The C++ core only refuses a read-only write when it has to grow the file, and overwriting
    // a key in place would write into the read-only mapping, so the shim refuses them all.
    if self.isReadOnly {
      return false
    }
    let isExpirationEnabled = self.lock.withLock { self.enableKeyExpire }
    if expiresInSeconds != 0 && !isExpirationEnabled && !self.enableAutoKeyExpire(0) {
      return false
    }
    return self.set(value, forKey: key, expireDuration: expiresInSeconds)
  }

  /// MMKV's typed `set(value, key, expireDuration)`.
  private func set(_ value: EncodedValue, forKey key: StoreKey, expireDuration: UInt32) -> Bool {
    guard !key.bytes.isEmpty else { return false }
    switch value {
    case .bytes(let bytes):
      return self.setDataForKey(bytes, key, expireDuration: expireDuration, isDataHolder: true)
    case .strings:
      guard let data = try? value.encode(expiry: nil) else { return false }
      return data.withUnsafeBytes {
        self.setDataForKey($0, key, expireDuration: expireDuration, isDataHolder: false)
      }
    default:
      return self.withLocks(.exclusive) {
        self.checkLoadData()
        let expiry: UInt32? =
          self.enableKeyExpire
          ? (expireDuration != 0 ? Self.safeExpirationPlusCurrentTime(expireDuration) : 0)
          : nil
        guard let data = try? value.encode(expiry: expiry) else { return false }
        return data.withUnsafeBytes { self.setDataForKey($0, key, isDataHolder: false) }
      }
    }
  }

  /// `setDataForKey(data, key, expireDuration, isDataHolder)`: adds the expiry time when the store
  /// has expiring keys.
  func setDataForKey(
    _ data: UnsafeRawBufferPointer,
    _ key: StoreKey,
    expireDuration: UInt32,
    isDataHolder: Bool
  ) -> Bool {
    if !isDataHolder && data.isEmpty {
      return false
    }
    return self.withLocks(.exclusive) {
      self.checkLoadData()
      guard self.enableKeyExpire else {
        return self.setDataForKey(data, key, isDataHolder: isDataHolder)
      }
      guard data.count <= Int(UInt32.max) else {
        Log.error("[\(self.id)] reject value too large to encode: \(data.count)")
        return false
      }
      let encodedLength =
        data.count + (isDataHolder ? pbRawVarint32Size(UInt32(data.count)) : 0) + fixed32Size
      guard encodedLength <= Int(UInt32.max) else {
        Log.error("[\(self.id)] reject expiring value too large to encode: \(data.count)")
        return false
      }
      var encoded = [UInt8](repeating: 0, count: encodedLength)
      let time = expireDuration != 0 ? Self.safeExpirationPlusCurrentTime(expireDuration) : 0
      let didEncode = encoded.withUnsafeMutableBytes { buffer in
        var output = CodedOutput(buffer)
        do throws(CodingError) {
          if isDataHolder {
            try output.writeData(data)
          } else {
            try output.writeRawData(data)
          }
          try output.writeRawLittleEndian32(time)
          return true
        } catch {
          return false
        }
      }
      guard didEncode else { return false }
      return encoded.withUnsafeBytes { self.setDataForKey($0, key, isDataHolder: false) }
    }
  }
}

// MARK: - Keys

extension StoreInstance {
  /// The number of keys, without those that have expired (`count(true)`).
  package var count: Int {
    self.lock.withLock {
      self.checkLoadData()
      self.filterExpiredKeysBeforeListing()
      return self.indexCount
    }
  }

  /// Every key, without those that have expired (`allKeys(true)`), in no particular order.
  package var keys: [StoreKey] {
    self.lock.withLock {
      self.checkLoadData()
      self.filterExpiredKeysBeforeListing()
      return self.crypter == nil ? Array(self.dic.keys) : Array(self.dicCrypt.keys)
    }
  }

  private func filterExpiredKeysBeforeListing() {
    guard self.enableKeyExpire else { return }
    if self.isReadOnly {
      self.filterExpiredKeys()
    } else {
      self.exclusiveProcessLock.withLock {
        _ = self.fullWriteback(onlyWhileExpire: true)
      }
    }
  }

  package func contains(_ key: StoreKey) -> Bool {
    self.lock.withLock {
      self.checkLoadData()
      if !self.enableKeyExpire {
        return self.crypter == nil ? self.dic[key] != nil : self.dicCrypt[key] != nil
      }
      return self.getDataWithoutMTimeForKey(key).count != 0
    }
  }
}

// MARK: - Removal

extension StoreInstance {
  @discardableResult
  package func removeValue(forKey key: StoreKey) -> Bool {
    guard !key.bytes.isEmpty else { return false }
    if self.isReadOnly {
      Log.warning("[\(self.id)] file readonly")
      return false
    }
    return self.withLocks(.exclusive) {
      self.checkLoadData()
      return self.removeDataForKey(key)
    }
  }

  /// Removes several keys and rewrites the file once (`removeValuesForKeys`).
  @discardableResult
  package func removeValues(forKeys keys: [StoreKey]) -> Bool {
    if self.isReadOnly {
      Log.warning("[\(self.id)] file readonly")
      return false
    }
    if keys.isEmpty {
      return true
    }
    if keys.count == 1 {
      return self.removeValue(forKey: keys[0])
    }
    return self.withLocks(.exclusive) {
      self.checkLoadData()
      var deleteCount = 0
      for key in keys {
        let removed =
          self.crypter == nil
          ? self.dic.removeValue(forKey: key) != nil
          : self.dicCrypt.removeValue(forKey: key) != nil
        if removed {
          deleteCount += 1
        }
      }
      guard deleteCount > 0 else { return true }
      self.hasFullWriteback = false
      let didWriteBack = self.fullWriteback()
      if !didWriteBack {
        self.clearMemoryCache()
      }
      return didWriteBack
    }
  }

  func removeDataForKey(_ key: StoreKey) -> Bool {
    guard !key.bytes.isEmpty else { return false }
    let empty = UnsafeRawBufferPointer(start: nil, count: 0)
    if self.crypter != nil {
      guard self.dicCrypt[key] != nil else { return false }
      self.hasFullWriteback = false
      let result = self.appendDataWithKey(empty, key: key, isDataHolder: false)
      if result != nil {
        self.dicCrypt.removeValue(forKey: key)
      }
      return result != nil
    }
    guard self.dic[key] != nil else { return false }
    self.hasFullWriteback = false
    let result =
      self.enableKeyExpire
      ? self.appendDataWithKey(empty, key: key, isDataHolder: false)
      : self.appendDataWithKey(empty, holderOf: key, isDataHolder: false)
    if result != nil {
      self.dic.removeValue(forKey: key)
    }
    return result != nil
  }
}

// MARK: - Locking and maintenance

extension StoreInstance {
  /// Takes the instance's lock and, for a multi-process store, the exclusive file lock. Recursive
  /// on the thread that holds it (the shim's `mmkv_lock`).
  package func lockExclusively() {
    self.lock.lock()
    self.lock.withLock { self.exclusiveProcessLock.lock() }
  }

  package func unlockExclusively() {
    self.lock.withLock { self.exclusiveProcessLock.unlock() }
    self.lock.unlock()
  }

  /// The size of the data file.
  package var totalSize: Int {
    self.lock.withLock {
      self.checkLoadData()
      return self.file.size
    }
  }

  /// The number of bytes of data in the file.
  package var dataSize: Int {
    self.lock.withLock {
      self.checkLoadData()
      return self.actualSize
    }
  }

  package func checkContentChanged() {
    self.lock.withLock { self.checkLoadData() }
  }

  /// Writes the files' mapped memory to disk.
  package func sync(synchronously: Bool = true) {
    self.lock.withLock {
      guard !self.needLoadFromFile, self.isFileValid else { return }
      self.exclusiveProcessLock.withLock {
        self.file.msync(synchronously: synchronously)
        self.metaFile.msync(synchronously: synchronously)
      }
    }
  }
}

// MARK: - Import

extension StoreInstance {
  /// Copies every key and value of `source` into this store, replacing the keys it already has
  /// (`importFrom`).
  ///
  /// The C++ core copies the keys in the order of its hash table. This copies them in the order
  /// they are in the source's file, so the two cores write the same records in a different order.
  ///
  /// - Returns: The number of keys copied.
  package func importAll(from source: StoreInstance) -> Int {
    guard source !== self else { return 0 }
    if self.isReadOnly {
      Log.warning("[\(self.id)] file readonly")
      return 0
    }
    // Lock a pair of stores in a stable order, across processes too, so two imports in opposite
    // directions cannot deadlock.
    let (first, second) =
      (source.path < self.path
        || (source.path == self.path && ObjectIdentifier(source) < ObjectIdentifier(self)))
      ? (source, self) : (self, source)
    return first.withLocks(.exclusive) {
      second.withLocks(.exclusive) {
        self.checkLoadData()
        source.checkLoadData()
        guard self.isFileValid, source.isFileValid else {
          Log.warning("[\(self.id)] or [\(source.id)] file not valid")
          return 0
        }
        let time =
          self.expiredInSeconds != 0
          ? Self.safeExpirationPlusCurrentTime(self.expiredInSeconds) : 0
        var count = 0
        let keys =
          source.crypter == nil
          ? source.dic.sorted { $0.value.offset < $1.value.offset }.map(\.key)
          : source.dicCrypt.sorted { $0.value.order < $1.value.order }.map(\.key)
        for key in keys {
          // Copied, because the source may move its records while this store is written.
          var value = source.getDataForKey(key).array
          guard !value.isEmpty else { continue }
          if self.enableKeyExpire {
            withUnsafeBytes(of: time.littleEndian) { value.append(contentsOf: $0) }
          }
          let didSet = value.withUnsafeBytes { self.setDataForKey($0, key, isDataHolder: false) }
          count += didSet ? 1 : 0
        }
        return count
      }
    }
  }
}
