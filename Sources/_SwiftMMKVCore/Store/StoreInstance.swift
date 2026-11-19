// One open store: the Swift port of MMKV's `MMKV` class (MMKV.cpp, MMKV_IO.cpp, MMKV_Android.cpp)
// together with what the package's C shim (SwiftMMKVShim.cpp) adds around it.
//
// The port follows the C++ closely, function by function, so that both cores write the same
// bytes for the same operations. Where the C++ names a function, the Swift one has the same name.

/// One open store. Every open of the same files in a process shares one instance, which
/// ``StoreRegistry`` hands out, and an instance lives for the rest of the process.
///
/// Thread-safe: every operation takes ``lock``, a recursive mutex, and a multi-process store also
/// takes a file lock that excludes other processes and other copies of MMKV.
///
/// The mutable properties are marked `@exclusivity(unchecked)`, because checking every access to
/// them at run time made writes about a third slower. The checks only ever caught two accesses
/// to a property overlapping on one thread, so the class keeps two rules in their place:
///
/// 1. The properties, and those of ``file`` and ``metaFile``, are read and written only with
///    ``lock`` held.
/// 2. While an access to one of them is open across a call, such as an `inout` argument or a
///    method of the property that takes a closure, nothing the call reaches writes to that
///    property, or reads it if the open access writes. Reads may overlap reads, as when a
///    closure passed to `forEachEntry` looks up a key in the same index. Breaking this rule is
///    undefined behaviour, not a trap.
///
/// The places that hold a writing access across a call say so where they do it.
package final class StoreInstance: @unchecked Sendable {
  package let id: String
  let path: String
  let crcPath: String
  package let isMultiProcess: Bool
  package let isReadOnly: Bool
  let expectedCapacity: Int
  let fileSystem: FileSystem

  /// Where each key's latest record is in a plain-text store (`m_dic`).
  @exclusivity(unchecked) var dic = RecordIndex()
  /// Each key's entry in an encrypted store (`m_dicCrypt`).
  @exclusivity(unchecked) var dicCrypt = CryptIndex()
  /// The cryptor of an encrypted store, whose state is the end of the data (`m_crypter`).
  @exclusivity(unchecked) var crypter: AESCryptor?
  /// The stream's state where the last appended record started, if its value is left in the file
  /// (`t_status`).
  @exclusivity(unchecked) var appendState: CipherState?
  let file: MemoryFile
  let metaFile: MemoryFile
  @exclusivity(unchecked) var metaInfo = MetaInfo()
  /// Where the next record is written (`m_output`), relative to the start of the data.
  @exclusivity(unchecked) var output: OutputState?
  /// How many bytes of data follow the header (`m_actualSize`).
  @exclusivity(unchecked) var actualSize = 0
  @exclusivity(unchecked) var crcDigest: UInt32 = 0
  @exclusivity(unchecked) var needLoadFromFile = true
  @exclusivity(unchecked) var hasFullWriteback = false
  @exclusivity(unchecked) var isSecondLoad = false

  let lock = ThreadLock()
  let fileLock: FileLock
  @exclusivity(unchecked) var sharedProcessLock: InterProcessLock
  @exclusivity(unchecked) var exclusiveProcessLock: InterProcessLock
  #if os(Android)
    /// Held shared for the instance's life, so that Android's MMKV knows the file is in use and
    /// does not migrate it to another name.
    private let migrationLock: FileLock?
  #endif

  let recoverOnError: Bool
  let itemSizeLimit: UInt32
  @exclusivity(unchecked) var enableKeyExpire = false
  @exclusivity(unchecked) var expiredInSeconds: UInt32 = 0
  @exclusivity(unchecked) var enableCompareBeforeSet = false

  @exclusivity(unchecked) private var contentChangedHandler: (@Sendable () -> Void)?

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
    // The handler runs with the lock held and can call back into the store, so it is called
    // outside any access to a property (rule 2 in the class's documentation).
    let handler = self.contentChangedHandler
    handler?()
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

  /// The start of the data in the mapped file, which locations are measured from.
  var dataBase: UnsafeRawPointer? {
    self.file.memory.map { UnsafeRawPointer($0 + fixed32Size) }
  }

  /// Calls `body` with the UTF-8 bytes of `key`, without copying them when the string is stored
  /// contiguously.
  @inline(__always)
  func withKeyBytes<R>(_ key: String, _ body: (UnsafeRawBufferPointer) -> R) -> R {
    var key = key
    return key.withUTF8 { body(UnsafeRawBufferPointer($0)) }
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
    forKey key: String,
    _ body: (UnsafeRawBufferPointer) throws(CodingError) -> R
  ) -> R? {
    guard !key.isEmpty else { return nil }
    return self.withKeyBytes(key) { key in
      self.withValue(forKey: key, body)
    }
  }

  func withValue<R>(
    forKey key: UnsafeRawBufferPointer,
    _ body: (UnsafeRawBufferPointer) throws(CodingError) -> R
  ) -> R? {
    self.withLocks(.shared) {
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

  package func bool(forKey key: String) -> Bool? {
    self.withValue(forKey: key) { (data) throws(CodingError) in try ValueDecoding.bool(data) }
  }

  package func int32(forKey key: String) -> Int32? {
    self.withValue(forKey: key) { (data) throws(CodingError) in try ValueDecoding.int32(data) }
  }

  package func uint32(forKey key: String) -> UInt32? {
    self.withValue(forKey: key) { (data) throws(CodingError) in try ValueDecoding.uint32(data) }
  }

  package func int64(forKey key: String) -> Int64? {
    self.withValue(forKey: key) { (data) throws(CodingError) in try ValueDecoding.int64(data) }
  }

  package func uint64(forKey key: String) -> UInt64? {
    self.withValue(forKey: key) { (data) throws(CodingError) in try ValueDecoding.uint64(data) }
  }

  package func float(forKey key: String) -> Float? {
    self.withValue(forKey: key) { (data) throws(CodingError) in try ValueDecoding.float(data) }
  }

  package func double(forKey key: String) -> Double? {
    self.withValue(forKey: key) { (data) throws(CodingError) in try ValueDecoding.double(data) }
  }

  /// The bytes of a string or of raw bytes, copied out of the file.
  package func bytes(forKey key: String) -> [UInt8]? {
    self.withValue(forKey: key) { (data) throws(CodingError) in Array(try ValueDecoding.bytes(data))
    }
  }

  /// A string, decoded straight out of the file.
  package func string(forKey key: String) -> String? {
    self.withValue(forKey: key) { (data) throws(CodingError) in
      String(decoding: try ValueDecoding.bytes(data), as: UTF8.self)
    }
  }

  package func strings(forKey key: String) -> [String]? {
    self.withValue(forKey: key) { (data) throws(CodingError) in try ValueDecoding.strings(data) }
  }
}

// MARK: - Writes

extension StoreInstance {
  /// Stores `value` under `key`, as the package's `mmkv_set_*` functions do: a read-only store
  /// refuses the write, and an expiring write first turns on expiry for the whole store.
  ///
  /// - Parameter expiresInSeconds: How long to keep the value, or 0 to keep it until it is removed.
  package func set(_ value: EncodedValue, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    // The C++ core only refuses a read-only write when it has to grow the file, and overwriting
    // a key in place would write into the read-only mapping, so the shim refuses them all.
    if self.isReadOnly {
      return false
    }
    let isExpirationEnabled = self.lock.withLock { self.enableKeyExpire }
    if expiresInSeconds != 0 && !isExpirationEnabled && !self.enableAutoKeyExpire(0) {
      return false
    }
    return self.withKeyBytes(key) { key in
      self.set(value, forKey: key, expireDuration: expiresInSeconds)
    }
  }

  /// MMKV's typed `set(value, key, expireDuration)`.
  private func set(
    _ value: EncodedValue,
    forKey key: UnsafeRawBufferPointer,
    expireDuration: UInt32
  ) -> Bool {
    guard !key.isEmpty else { return false }
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
        return value.withEncoded(expiry: expiry) { data in
          self.setDataForKey(data, key, isDataHolder: false)
        } ?? false
      }
    }
  }

  /// `setDataForKey(data, key, expireDuration, isDataHolder)`: adds the expiry time when the store
  /// has expiring keys.
  func setDataForKey(
    _ data: UnsafeRawBufferPointer,
    _ key: UnsafeRawBufferPointer,
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
      let time = expireDuration != 0 ? Self.safeExpirationPlusCurrentTime(expireDuration) : 0
      // On the stack unless the value is large.
      return withUnsafeTemporaryAllocation(byteCount: encodedLength, alignment: 1) { buffer in
        var output = CodedOutput(buffer)
        do throws(CodingError) {
          if isDataHolder {
            try output.writeData(data)
          } else {
            try output.writeRawData(data)
          }
          try output.writeRawLittleEndian32(time)
        } catch {
          return false
        }
        return self.setDataForKey(UnsafeRawBufferPointer(buffer), key, isDataHolder: false)
      }
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
  package var keys: [String] {
    self.lock.withLock {
      self.checkLoadData()
      self.filterExpiredKeysBeforeListing()
      if self.crypter != nil {
        var keys = [String]()
        keys.reserveCapacity(self.dicCrypt.count)
        self.dicCrypt.forEachEntry { slot, _ in
          keys.append(String(decoding: self.dicCrypt.key(at: slot), as: UTF8.self))
        }
        return keys
      }
      guard let base = self.dataBase else { return [] }
      var keys = [String]()
      keys.reserveCapacity(self.dic.count)
      self.dic.forEachRecord { _, location in
        keys.append(String(decoding: RecordIndex.key(at: location, in: base), as: UTF8.self))
      }
      return keys
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

  package func contains(_ key: String) -> Bool {
    self.withKeyBytes(key) { key in
      self.lock.withLock {
        self.checkLoadData()
        if !self.enableKeyExpire {
          return self.crypter == nil
            ? self.dic.slot(of: key, base: self.dataBase) != nil
            : self.dicCrypt.contains(key)
        }
        return self.getDataWithoutMTimeForKey(key).count != 0
      }
    }
  }
}

// MARK: - Removal

extension StoreInstance {
  @discardableResult
  package func removeValue(forKey key: String) -> Bool {
    self.withKeyBytes(key) { self.removeValue(forKey: $0) }
  }

  @discardableResult
  func removeValue(forKey key: UnsafeRawBufferPointer) -> Bool {
    guard !key.isEmpty else { return false }
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
  package func removeValues(forKeys keys: [String]) -> Bool {
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
        let removed = self.withKeyBytes(key) { key in
          self.crypter == nil
            ? self.dic.remove(key, base: self.dataBase) != nil
            : self.dicCrypt.remove(key)
        }
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

  func removeDataForKey(_ key: UnsafeRawBufferPointer) -> Bool {
    guard !key.isEmpty else { return false }
    let empty = UnsafeRawBufferPointer(start: nil, count: 0)
    if self.crypter != nil {
      guard self.dicCrypt.contains(key) else { return false }
      self.hasFullWriteback = false
      let result = self.appendDataWithKey(empty, key: key, isDataHolder: false)
      if result != nil {
        self.dicCrypt.remove(key)
      }
      return result != nil
    }
    guard let slot = self.dic.slot(of: key, base: self.dataBase) else { return false }
    let version = self.dic.version
    self.hasFullWriteback = false
    let result =
      self.enableKeyExpire
      ? self.appendDataWithKey(empty, key: key, isDataHolder: false)
      : self.appendDataWithKey(empty, holderOf: key, isDataHolder: false)
    if result != nil {
      // Making space can remove expired keys, which moves others between slots.
      if self.dic.version == version {
        self.dic.remove(at: slot)
      } else {
        self.dic.remove(key, base: self.dataBase)
      }
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
        for key in source.keysInRecordOrder() {
          // Copied, because the source may move its records while this store is written.
          let didSet = key.bytes.withUnsafeBytes { key in
            var value = source.getDataForKey(key).array
            guard !value.isEmpty else { return false }
            if self.enableKeyExpire {
              withUnsafeBytes(of: time.littleEndian) { value.append(contentsOf: $0) }
            }
            return value.withUnsafeBytes { self.setDataForKey($0, key, isDataHolder: false) }
          }
          count += didSet ? 1 : 0
        }
        return count
      }
    }
  }
}

extension StoreInstance {
  /// Copies of every key, in the order of their records in the file, for the operations that
  /// rewrite every key and so cannot keep pointing into the file.
  func keysInRecordOrder() -> [StoreKey] {
    if self.crypter != nil {
      var keys = [StoreKey]()
      keys.reserveCapacity(self.dicCrypt.count)
      for slot in self.dicCrypt.slotsInRecordOrder() {
        keys.append(StoreKey(self.dicCrypt.key(at: slot)))
      }
      return keys
    }
    guard let base = self.dataBase else { return [] }
    var keys = [StoreKey]()
    keys.reserveCapacity(self.dic.count)
    for slot in self.dic.slotsInRecordOrder() {
      keys.append(StoreKey(RecordIndex.key(at: self.dic.location(at: slot), in: base)))
    }
    return keys
  }
}
