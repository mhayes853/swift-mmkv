// One open store: the Swift port of MMKV's `MMKV` class (MMKV.cpp, MMKV_IO.cpp, MMKV_Android.cpp)
// together with what the package's C shim (SwiftMMKVShim.cpp) adds around it.
//
// The port follows the C++ closely, function by function, so that both cores write the same
// bytes for the same operations. Where the C++ names a function, the Swift one has the same name.

/// One open store. Every open of the same files in a process shares one instance, which
/// ``StoreRegistry`` hands out, and an instance lives for the rest of the process.
///
/// Thread-safe: every operation takes ``state``'s lock, and a multi-process store also takes a
/// file lock that excludes other processes and other copies of MMKV. The operations themselves are
/// ``StoreState``'s, which the lock hands out one at a time.
package final class StoreInstance: Sendable {
  package let id: String
  let path: String
  package let isMultiProcess: Bool
  package let isReadOnly: Bool
  let state: StoreLock<StoreState>

  init(_ configuration: StoreConfiguration, root: String) {
    let state = StoreState(configuration, root: root)
    self.id = state.id
    self.path = state.path
    self.isMultiProcess = state.isMultiProcess
    self.isReadOnly = state.isReadOnly
    self.state = StoreLock(state)
  }

  /// Runs `body` with the state, then calls the content-changed handler if `body` noticed another
  /// process's changes.
  @inline(__always)
  func withState<R>(_ body: (inout StoreState) -> R) -> R {
    let (result, handler) = self.state.withLock { state in
      let result = body(&state)
      return (result, state.takePendingContentChangedHandler())
    }
    handler?()
    return result
  }

  /// Loads the files if they are not loaded, and says whether the data, though intact, could not
  /// be decoded: the store is encrypted with another key than the one it was opened with.
  package func loadAndCheckForWrongEncryptionKey() -> Bool {
    self.withState {
      $0.checkLoadData()
      return $0.hasUndecodableData
    }
  }

  /// Whether the data last loaded was intact but could not be decoded.
  package var hasUndecodableData: Bool {
    self.withState { $0.hasUndecodableData }
  }

  /// Called just after an operation that noticed that another process, or another copy of MMKV,
  /// changed the store's files (`onContentChangedByOuterProcess`). The C++ core calls it with its
  /// lock held; this calls it once the lock is released.
  package func setContentChangedHandler(_ handler: (@Sendable () -> Void)?) {
    self.withState { $0.contentChangedHandler = handler }
  }
}

/// Calls `body` with the UTF-8 bytes of `key`, without copying them when the string is stored
/// contiguously.
@inline(__always)
func withKeyBytes<R>(_ key: String, _ body: (UnsafeRawBufferPointer) -> R) -> R {
  var key = key
  return key.withUTF8 { body(UnsafeRawBufferPointer($0)) }
}

/// Everything about an open store that changes, with the operations on it. ``StoreInstance``'s
/// lock owns it, so it is only ever reached by one thread, through one `inout`, at a time.
struct StoreState: ~Copyable {
  let id: String
  let path: String
  let crcPath: String
  /// Where the store's data is kept while it is rewritten. See StoreInstance+RewriteJournal.swift.
  let journalPath: String
  /// The journal's descriptor, open from the store's first rewrite until its memory is given up.
  var journalDescriptor: Int32 = -1
  let isMultiProcess: Bool
  let isReadOnly: Bool
  let expectedCapacity: Int
  let fileSystem: FileSystem

  /// Where each key's latest record is in a plain-text store (`m_dic`).
  var dic = RecordIndex()
  /// Each key's entry in an encrypted store (`m_dicCrypt`).
  var dicCrypt = CryptIndex()
  /// The cryptor of an encrypted store, whose state is the end of the data (`m_crypter`).
  var crypter: AESCryptor?
  /// The stream's state where the last appended record started, if its value is left in the file
  /// (`t_status`).
  var appendState: CipherState?
  var file: MemoryFile
  var metaFile: MemoryFile
  var metaInfo = MetaInfo()
  /// Where the next record is written (`m_output`), relative to the start of the data.
  var output: OutputState?
  /// How many bytes of data follow the header (`m_actualSize`).
  var actualSize = 0
  var crcDigest: UInt32 = 0
  var needLoadFromFile = true
  var hasFullWriteback = false
  var isSecondLoad = false
  /// Whether the data last loaded had its checksum but could not be decoded, which means the
  /// store was opened with the wrong encryption key, or with none. Nothing is written over such
  /// data except by ``clearAll(keepSpace:)``.
  var hasUndecodableData = false

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

  var contentChangedHandler: (@Sendable () -> Void)?
  /// Whether an operation noticed another process's changes, which ``StoreInstance`` reports once
  /// the operation ends.
  var hasPendingContentChange = false

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
    let path = "\(root)/\(relative.path)"
    self.path = path
    let crcPath = StorePaths.metaPath(dataPath: path)
    self.crcPath = crcPath
    self.journalPath = StorePaths.journalPath(dataPath: path)
    let expectedCapacity = max(
      pageSize,
      roundUp(max(configuration.expectedCapacity, 0), toMultipleOf: pageSize)
    )
    self.expectedCapacity = expectedCapacity
    self.file = MemoryFile(
      path: path,
      expectedCapacity: expectedCapacity,
      isReadOnly: configuration.isReadOnly,
      isMayflyFD: true,
      fileSystem: configuration.fileSystem
    )
    #if os(Android)
      // Android keeps the metadata file open, and always locks it with flock.
      var metaFile = MemoryFile(
        path: crcPath,
        expectedCapacity: pageSize,
        isReadOnly: configuration.isReadOnly,
        isMayflyFD: false,
        fileSystem: configuration.fileSystem
      )
      let fileLock = FileLock(
        descriptor: metaFile.fileDescriptor,
        fileSystem: configuration.fileSystem
      )
      let migrationLock = FileLock(
        descriptor: metaFile.fileDescriptor,
        kind: .openFileDescription(start: 2, length: 3),
        fileSystem: configuration.fileSystem
      )
      _ = migrationLock.tryLock(.shared)
      self.migrationLock = migrationLock
    #else
      var metaFile = MemoryFile(
        path: crcPath,
        isReadOnly: configuration.isReadOnly,
        isMayflyFD: !configuration.isMultiProcess,
        fileSystem: configuration.fileSystem
      )
      let fileLock = FileLock(
        descriptor: configuration.isMultiProcess ? metaFile.fileDescriptor : -1,
        fileSystem: configuration.fileSystem
      )
    #endif
    self.metaFile = metaFile
    self.sharedProcessLock = InterProcessLock(fileLock: fileLock, type: .shared)
    self.exclusiveProcessLock = InterProcessLock(fileLock: fileLock, type: .exclusive)
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

  deinit {
    if self.journalDescriptor >= 0 {
      _ = self.fileSystem.close(self.journalDescriptor)
    }
  }

  mutating func notifyContentChanged() {
    self.hasPendingContentChange = true
  }

  /// The handler to call for changes noticed since this was last asked, if any.
  mutating func takePendingContentChangedHandler() -> (@Sendable () -> Void)? {
    guard self.hasPendingContentChange else { return nil }
    self.hasPendingContentChange = false
    return self.contentChangedHandler
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

  /// Whether the store can be written, warning that it cannot when it is read-only, as MMKV's
  /// writing operations check first.
  @inline(__always)
  func checkWritable(function: StaticString = #function) -> Bool {
    if self.isReadOnly {
      Log.warning("[\(self.id)] file readonly", function: function)
      return false
    }
    return true
  }

  /// Whether the data could be decoded, warning that it could not when it could not.
  func checkDecodable(function: StaticString = #function) -> Bool {
    if self.hasUndecodableData {
      Log.warning("[\(self.id)] wrong encryption key", function: function)
      return false
    }
    return true
  }

  /// Whether the data file is mapped, warning that it is not when it is not.
  @inline(__always)
  func checkFileValid(function: StaticString = #function) -> Bool {
    guard self.isFileValid else {
      Log.warning("[\(self.id)] file not valid", function: function)
      return false
    }
    return true
  }

  /// Takes the file lock of `type`. A single-process store's is turned off.
  @inline(__always)
  func lockProcess(_ type: LockType) {
    switch type {
    case .shared: self.sharedProcessLock.lock()
    case .exclusive: self.exclusiveProcessLock.lock()
    }
  }

  @inline(__always)
  func unlockProcess(_ type: LockType) {
    switch type {
    case .shared: self.sharedProcessLock.unlock()
    case .exclusive: self.exclusiveProcessLock.unlock()
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
    return withKeyBytes(key) { key in
      self.withState { $0.withValue(forKey: key, body) }
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

extension StoreState {
  mutating func withValue<R>(
    forKey key: UnsafeRawBufferPointer,
    _ body: (UnsafeRawBufferPointer) throws(CodingError) -> R
  ) -> R? {
    self.lockProcess(.shared)
    defer { self.unlockProcess(.shared) }
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
    return withKeyBytes(key) { key in
      self.withState { $0.set(value, forKey: key, expiresInSeconds: expiresInSeconds) }
    }
  }
}

extension StoreState {
  /// The shim's `mmkv_set_*`, after the read-only check, then MMKV's typed
  /// `set(value, key, expireDuration)`.
  mutating func set(
    _ value: EncodedValue,
    forKey key: UnsafeRawBufferPointer,
    expiresInSeconds: UInt32
  ) -> Bool {
    if expiresInSeconds != 0 && !self.enableKeyExpire && !self.enableAutoKeyExpire(0) {
      return false
    }
    guard !key.isEmpty else { return false }
    switch value {
    case .bytes(let bytes):
      return self.setDataForKey(bytes, key, expireDuration: expiresInSeconds, isDataHolder: true)
    case .strings:
      return value.withEncoded(expiry: nil) { data in
        self.setDataForKey(data, key, expireDuration: expiresInSeconds, isDataHolder: false)
      } ?? false
    default:
      self.lockProcess(.exclusive)
      defer { self.unlockProcess(.exclusive) }
      self.checkLoadData()
      let expiry: UInt32? =
        self.enableKeyExpire
        ? Self.expirationTime(after: expiresInSeconds) : nil
      return value.withEncoded(expiry: expiry) { data in
        self.setDataForKey(data, key, isDataHolder: false)
      } ?? false
    }
  }

  /// `setDataForKey(data, key, expireDuration, isDataHolder)`: adds the expiry time when the store
  /// has expiring keys.
  mutating func setDataForKey(
    _ data: UnsafeRawBufferPointer,
    _ key: UnsafeRawBufferPointer,
    expireDuration: UInt32,
    isDataHolder: Bool
  ) -> Bool {
    if !isDataHolder && data.isEmpty {
      return false
    }
    self.lockProcess(.exclusive)
    defer { self.unlockProcess(.exclusive) }
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
    let time = Self.expirationTime(after: expireDuration)
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

// MARK: - Keys

extension StoreInstance {
  /// The number of keys, without those that have expired (`count(true)`).
  package var count: Int {
    self.withState { state in
      state.checkLoadData()
      state.filterExpiredKeysBeforeListing()
      return state.indexCount
    }
  }

  /// Every key, without those that have expired (`allKeys(true)`), in no particular order.
  package var keys: [String] {
    self.withState { $0.allKeys() }
  }

  package func contains(_ key: String) -> Bool {
    withKeyBytes(key) { key in
      self.withState { $0.contains(key) }
    }
  }
}

extension StoreState {
  mutating func allKeys() -> [String] {
    self.checkLoadData()
    self.filterExpiredKeysBeforeListing()
    // A plain-text store's keys are read from the file, which another process must not rewrite
    // or shrink meanwhile. The C++ core keeps copies of the keys, and so reads them unlocked.
    self.lockProcess(.shared)
    defer { self.unlockProcess(.shared) }
    self.checkLoadData()
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

  mutating func filterExpiredKeysBeforeListing() {
    guard self.enableKeyExpire else { return }
    if self.isReadOnly {
      self.filterExpiredKeys()
    } else {
      self.lockProcess(.exclusive)
      defer { self.unlockProcess(.exclusive) }
      // The rewrite keeps only the records this instance knows of, so it must know of them all.
      self.checkLoadData()
      self.fullWriteback(onlyWhileExpire: true)
    }
  }

  mutating func contains(_ key: UnsafeRawBufferPointer) -> Bool {
    // Looking a key up compares it with the keys in the file, as ``allKeys()`` reads them.
    self.lockProcess(.shared)
    defer { self.unlockProcess(.shared) }
    self.checkLoadData()
    if !self.enableKeyExpire {
      return self.crypter == nil
        ? self.dic.slot(of: key, base: self.dataBase) != nil
        : self.dicCrypt.contains(key)
    }
    return self.getDataWithoutMTimeForKey(key).count != 0
  }
}

// MARK: - Removal

extension StoreInstance {
  @discardableResult
  package func removeValue(forKey key: String) -> Bool {
    withKeyBytes(key) { key in
      self.withState { $0.removeValue(forKey: key) }
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
    return self.withState { $0.removeValues(forKeys: keys) }
  }
}

extension StoreState {
  @discardableResult
  mutating func removeValue(forKey key: UnsafeRawBufferPointer) -> Bool {
    guard !key.isEmpty, self.checkWritable() else { return false }
    self.lockProcess(.exclusive)
    defer { self.unlockProcess(.exclusive) }
    self.checkLoadData()
    return self.removeDataForKey(key)
  }

  mutating func removeValues(forKeys keys: [String]) -> Bool {
    self.lockProcess(.exclusive)
    defer { self.unlockProcess(.exclusive) }
    self.checkLoadData(checkingFileSize: true)
    var deleteCount = 0
    for key in keys {
      let removed = withKeyBytes(key) { key in
        self.crypter == nil
          ? self.dic.remove(key, base: self.dataBase) != nil
          : self.dicCrypt.remove(key)
      }
      deleteCount += removed ? 1 : 0
    }
    guard deleteCount > 0 else { return true }
    self.hasFullWriteback = false
    let didWriteBack = self.fullWriteback()
    if !didWriteBack {
      self.clearMemoryCache()
    }
    return didWriteBack
  }

  mutating func removeDataForKey(_ key: UnsafeRawBufferPointer) -> Bool {
    guard !key.isEmpty else { return false }
    let empty = UnsafeRawBufferPointer(start: nil, count: 0)
    if self.crypter != nil {
      guard self.dicCrypt.contains(key) else { return false }
      self.hasFullWriteback = false
      guard self.appendDataWithKey(empty, key: key, isDataHolder: false) != nil else {
        return false
      }
      self.dicCrypt.remove(key)
      return true
    }
    guard let slot = self.dic.slot(of: key, base: self.dataBase) else { return false }
    let version = self.dic.version
    self.hasFullWriteback = false
    let result =
      self.enableKeyExpire
      ? self.appendDataWithKey(empty, key: key, isDataHolder: false)
      : self.appendDataWithKey(empty, holderOf: key, isDataHolder: false)
    guard result != nil else { return false }
    // Making space can remove expired keys, which moves others between slots.
    if self.dic.version == version {
      self.dic.remove(at: slot)
    } else {
      self.dic.remove(key, base: self.dataBase)
    }
    return true
  }
}

// MARK: - Locking and maintenance

extension StoreInstance {
  /// Takes the instance's lock and, for a multi-process store, the exclusive file lock. Recursive
  /// on the thread that holds it (the shim's `mmkv_lock`).
  package func lockExclusively() {
    self.state.lock()
    self.withState { $0.lockProcess(.exclusive) }
  }

  package func unlockExclusively() {
    self.withState { $0.unlockProcess(.exclusive) }
    self.state.unlock()
  }

  /// The size of the data file.
  package var totalSize: Int {
    self.withState { state in
      state.checkLoadData(checkingFileSize: true)
      return state.file.size
    }
  }

  /// The number of bytes of data in the file.
  package var dataSize: Int {
    self.withState { state in
      state.checkLoadData()
      return state.actualSize
    }
  }

  package func checkContentChanged() {
    self.withState { $0.checkLoadData() }
  }

  /// Whether the store's file records when each key expires (`isExpirationEnabled`).
  package var isExpiryEnabled: Bool {
    self.withState { state in
      state.checkLoadData()
      return state.enableKeyExpire
    }
  }

  /// Rewrites the file without its expiry times (`disableAutoKeyExpire`).
  package func disableExpiry() -> Bool {
    self.withState { $0.disableAutoKeyExpire() }
  }

  /// Writes the files' mapped memory to disk (`sync`). A synchronous sync does not return until
  /// the drive has it, and then everything written so far survives a loss of power, whatever is
  /// written afterwards.
  package func sync(synchronously: Bool = true) {
    self.withState {
      if synchronously {
        $0.checkpoint()
      } else {
        $0.sync(synchronously: false)
      }
    }
  }

  /// Compacts the file and shrinks it by halves while it is more than twice its data, but not below
  /// the expected capacity (`trim`).
  package func trim() {
    self.withState { $0.trim() }
  }

  /// Lets go of the in-memory copy of the contents and of the mapping of the data file, so that
  /// the next operation loads the file again (`clearMemoryCache`).
  package func clearMemoryCache() {
    self.withState { $0.clearMemoryCache() }
  }

  /// Removes every key, shrinking the file back to the expected capacity unless `keepSpace`
  /// (`clearAll`).
  package func clearAll(keepSpace: Bool = false) {
    self.withState { $0.clearAll(keepSpace: keepSpace) }
  }

  /// Re-encrypts the store with `key`, or decrypts it when `key` is `nil` (`reKey`).
  package func rekey(key: [UInt8]?, isAES256: Bool) -> Bool {
    self.withState { $0.rekey(key: key, isAES256: isAES256) }
  }
}

extension StoreState {
  mutating func sync(synchronously: Bool = true) {
    guard !self.needLoadFromFile, self.isFileValid else { return }
    self.lockProcess(.exclusive)
    defer { self.unlockProcess(.exclusive) }
    self.file.msync(synchronously: synchronously)
    self.metaFile.msync(synchronously: synchronously)
  }

  /// Makes the data as it is now what a load falls back to, once the drive has it.
  ///
  /// The C++ core records a fallback only when it rewrites the file, and never has the drive
  /// write anything out. The system writes the two files' pages out in its own time and order, so
  /// after a loss of power the metadata on the drive can describe data that is not there. A load
  /// then falls back to the last rewrite, however much was synced since.
  ///
  /// The data goes to the drive first, so the fallback never describes data the drive lacks. Any
  /// size and checksum the data once had stay valid until the next rewrite, which records its
  /// own, because records are only ever appended in between.
  mutating func checkpoint() {
    guard !self.needLoadFromFile, self.isFileValid else { return }
    self.lockProcess(.exclusive)
    defer { self.unlockProcess(.exclusive) }
    // What another process appended is part of what the drive is given.
    self.checkLoadData()
    guard self.isFileValid, self.file.syncToDrive(), self.metaFile.isFileValid else { return }
    let size = UInt32(truncatingIfNeeded: self.actualSize)
    if !self.isReadOnly && !self.hasUndecodableData
      && (self.metaInfo.lastActualSize != size || self.metaInfo.lastCRCDigest != self.crcDigest)
    {
      self.metaInfo.lastActualSize = size
      self.metaInfo.lastCRCDigest = self.crcDigest
      self.metaInfo.writeLastConfirmed(to: self.metaFile.memory!)
    }
    self.metaFile.syncToDrive()
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
    let sourceFirst =
      source.path < self.path
      || (source.path == self.path && ObjectIdentifier(source) < ObjectIdentifier(self))
    let (first, second) = sourceFirst ? (source, self) : (self, source)
    return first.withState { first in
      second.withState { second in
        first.lockProcess(.exclusive)
        second.lockProcess(.exclusive)
        defer {
          second.unlockProcess(.exclusive)
          first.unlockProcess(.exclusive)
        }
        return sourceFirst
          ? StoreState.importAll(into: &second, from: &first)
          : StoreState.importAll(into: &first, from: &second)
      }
    }
  }
}

extension StoreState {
  /// `importFrom`, with both stores' exclusive file locks held.
  static func importAll(into target: inout StoreState, from source: inout StoreState) -> Int {
    target.checkLoadData(checkingFileSize: true)
    source.checkLoadData()
    guard target.isFileValid, source.isFileValid else {
      Log.warning("[\(target.id)] or [\(source.id)] file not valid")
      return 0
    }
    let time = Self.expirationTime(after: target.expiredInSeconds)
    var count = 0
    for key in source.keysInRecordOrder() {
      // Copied, because the source may move its records while this store is written.
      let didSet = key.bytes.withUnsafeBytes { key in
        var value = source.getDataForKey(key).array
        guard !value.isEmpty else { return false }
        if target.enableKeyExpire {
          withUnsafeBytes(of: time.littleEndian) { value.append(contentsOf: $0) }
        }
        return value.withUnsafeBytes { target.setDataForKey($0, key, isDataHolder: false) }
      }
      count += didSet ? 1 : 0
    }
    return count
  }

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
