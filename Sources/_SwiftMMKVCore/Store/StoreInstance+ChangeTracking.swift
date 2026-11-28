// Telling which keys another process changed. The C++ core has no counterpart: it reports that a
// store changed, and not what changed.
//
// When another process appends to the file, the records it appended are exactly the keys it set
// or removed, and they are read straight from the file. When it rewrites the whole file, as a
// compaction does, the records this instance knew are gone, so it compares the value of each key
// with the one it last saw. For that it keeps a hash of every value, which it updates as it
// appends records of its own. The hashes are only kept while something listens to a
// multi-process store, since nothing else asks what changed.
//
// Nothing here is written to the files, so any process may change the store, whichever core it
// runs.

/// What another process, or another copy of MMKV, changed in a store, as an operation noticed it.
package enum ContentChange: Equatable, Sendable {
  /// The keys that may read differently, each once, in the order they were found.
  case keys([String])
  /// Any key may read differently.
  case unknown

  /// This change and `other` together: the keys of both, or any key if either is unknown.
  mutating func merge(_ other: ContentChange) {
    switch (self, other) {
    case (.keys(let keys), .keys(let others)):
      var seen = Set(keys)
      self = .keys(keys + others.filter { seen.insert($0).inserted })
    default:
      self = .unknown
    }
  }
}

/// A hash of each key's value, as this instance last saw the file.
///
/// A value is hashed as it is stored: the bytes of its record's value, decrypted, with the
/// length of a string or byte value and any expiry time.
struct ChangeTracker {
  var hashes: [String: UInt64]

  static func hash(_ value: UnsafeRawBufferPointer) -> UInt64 {
    var hasher = Hasher()
    hasher.combine(bytes: value)
    return UInt64(bitPattern: Int64(hasher.finalize()))
  }

  /// Records that `key` now has `value`, or no value when `value` is empty.
  mutating func record(_ key: String, value: UnsafeRawBufferPointer) {
    if value.isEmpty {
      self.hashes.removeValue(forKey: key)
    } else {
      self.hashes[key] = Self.hash(value)
    }
  }
}

extension StoreState {
  // MARK: - Turning tracking on and off

  /// Whether the hashes are kept, which only a multi-process store needs.
  var keepsChangeTracker: Bool {
    self.tracksChangedKeys && self.isMultiProcess
  }

  /// Builds the hashes, unless they are already built, nothing loaded, or another process changed
  /// the file since this instance last read it. Called at the end of each operation.
  ///
  /// The hashes are built from the index, whose keys and values are read from the file, so this
  /// takes the shared file lock and checks that the metadata still describes what this instance
  /// loaded. If it does not, the hashes are built at the end of the operation that loads the
  /// change, which reports it as a change to any key.
  mutating func buildChangeTrackerIfNeeded() {
    guard self.keepsChangeTracker, self.changeTracker == nil, !self.needLoadFromFile,
      self.isFileValid, self.metaFile.isFileValid
    else {
      return
    }
    self.lockProcess(.shared)
    defer { self.unlockProcess(.shared) }
    let metaInfo = MetaInfo.Summary(reading: self.metaFile.memory!)
    guard self.metaInfo.sequence == metaInfo.sequence,
      self.metaInfo.crcDigest == metaInfo.crcDigest,
      self.metaInfo.actualSize == metaInfo.actualSize
    else {
      return
    }
    self.changeTracker = self.makeChangeTracker().tracker
  }

  /// The hashes of the values the index holds, and its keys in the order of their records.
  func makeChangeTracker() -> (tracker: ChangeTracker, keys: [String]) {
    var hashes = [String: UInt64]()
    var keys = [String]()
    if self.crypter != nil {
      hashes.reserveCapacity(self.dicCrypt.count)
      keys.reserveCapacity(self.dicCrypt.count)
      for slot in self.dicCrypt.slotsInRecordOrder() {
        let key = String(decoding: self.dicCrypt.key(at: slot), as: UTF8.self)
        hashes[key] = self.value(of: self.dicCrypt.entry(at: slot)).withBytes(ChangeTracker.hash)
        keys.append(key)
      }
    } else if let base = self.dataBase {
      hashes.reserveCapacity(self.dic.count)
      keys.reserveCapacity(self.dic.count)
      for slot in self.dic.slotsInRecordOrder() {
        let location = self.dic.location(at: slot)
        let key = String(decoding: RecordIndex.key(at: location, in: base), as: UTF8.self)
        hashes[key] = ChangeTracker.hash(RecordIndex.value(at: location, in: base))
        keys.append(key)
      }
    }
    return (ChangeTracker(hashes: hashes), keys)
  }

  // MARK: - This instance's writes

  /// Records the record this instance just appended for `key`, whose value is `value`, empty for
  /// a removal. Called with the exclusive file lock held, before the record is encrypted.
  mutating func trackAppend(key: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer) {
    guard self.changeTracker != nil else { return }
    self.changeTracker!.record(String(decoding: key, as: UTF8.self), value: value)
  }

  /// Forgets the hashes after this instance rewrote the whole file, which can change any value's
  /// bytes, so that the end of the operation builds them again.
  mutating func invalidateChangeTracker() {
    self.changeTracker = nil
  }

  // MARK: - Other processes' writes

  /// The keys another process appended from `position` up to the data's end, which a partial
  /// load just read, with the hashes updated to their values. `nil` if the hashes are not kept.
  mutating func trackAppendedRecords(from position: Int) -> [String]? {
    guard self.changeTracker != nil, let keys = self.appendedKeys(from: position) else {
      self.changeTracker = nil
      return nil
    }
    var names = [String]()
    names.reserveCapacity(keys.count)
    for key in keys {
      let name = key.string
      key.bytes.withUnsafeBytes { key in
        self.getRawDataForKey(key).withBytes { self.changeTracker!.record(name, value: $0) }
      }
      names.append(name)
    }
    return names
  }

  /// The keys of the records from `position` to the data's end, each once, in the order of
  /// their first record. `nil` if the records cannot be read.
  private func appendedKeys(from position: Int) -> [StoreKey]? {
    guard let memory = self.file.memory else { return nil }
    let data = UnsafeRawBufferPointer(start: memory + fixed32Size, count: self.actualSize)
    var keys = [StoreKey]()
    var seen = Set<StoreKey>()
    let didRead: Bool
    if let crypter = self.crypter {
      let decrypter = crypter.cloned(at: crypter.state(atOffset: position, in: data))
      var reader = DecryptingReader(ciphertext: data, position: position, decrypter: decrypter)
      didRead = Self.forEachCryptKey(&reader) { key in
        let key = StoreKey(key)
        if seen.insert(key).inserted { keys.append(key) }
      }
    } else {
      didRead = RecordDecoding.forEachKey(data, from: position) { key in
        let key = StoreKey(key)
        if seen.insert(key).inserted { keys.append(key) }
      }
    }
    return didRead ? keys : nil
  }

  /// The keys another process changed by rewriting the whole file, which a full load just read:
  /// those whose values differ from the ones `old` hashes. The hashes are replaced with the new
  /// values'.
  ///
  /// The keys that now have a value come first, in the order of their records, and then the
  /// keys that no longer have one, sorted.
  mutating func trackRewrite(from old: ChangeTracker) -> [String] {
    let (new, order) = self.makeChangeTracker()
    self.changeTracker = new
    var keys = order.filter { old.hashes[$0] != new.hashes[$0] }
    keys += old.hashes.keys.filter { new.hashes[$0] == nil }.sorted()
    return keys
  }
}
