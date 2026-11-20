// Expiring keys, from the "auto expire" section of MMKV_IO.cpp.

extension StoreState {
  /// Seconds since 1970, as `time(nullptr)`.
  static func currentTimeInSeconds() -> UInt32 {
    UInt32(truncatingIfNeeded: time(nil))
  }

  /// The time `duration` seconds from now, capped at `UInt32.max`.
  static func safeExpirationPlusCurrentTime(_ duration: UInt32) -> UInt32 {
    let time = UInt64(Self.currentTimeInSeconds()) + UInt64(duration)
    return time > UInt64(UInt32.max) ? UInt32.max : UInt32(time)
  }

  /// The expiry time at the end of an expiring key's value: seconds since 1970, or 0 for never.
  static func expirationTime(of value: UnsafeRawBufferPointer) -> UInt32 {
    UInt32(
      littleEndian: value.loadUnaligned(fromByteOffset: value.count - fixed32Size, as: UInt32.self)
    )
  }

  /// Turns on expiry for the whole store, adding an expiry time to every value already in it
  /// (`enableAutoKeyExpire`).
  ///
  /// The C++ core adds the times in the order of its hash table. This adds them in the order the
  /// records are in the file, so after this the two cores' files hold the same records in a
  /// different order.
  ///
  /// - Parameter expiredInSeconds: How long values written without an expiry of their own last,
  ///   or 0 for never.
  @discardableResult
  mutating func enableAutoKeyExpire(_ expiredInSeconds: UInt32) -> Bool {
    guard self.checkWritable() else { return false }
    self.lockProcess(.exclusive)
    defer { self.unlockProcess(.exclusive) }
    self.checkLoadData(checkingFileSize: true)
    guard self.isFileValid, self.metaFile.isFileValid else {
      Log.warning("[\(self.id)] file not valid")
      return false
    }
    let hasExpireFlag = self.metaInfo.hasFlag(MetaInfo.Flag.enableKeyExpire)
    var records = [(key: StoreKey, value: [UInt8])]()
    if !hasExpireFlag {
      let time =
        expiredInSeconds != 0 ? Self.safeExpirationPlusCurrentTime(expiredInSeconds) : 0
      let maximumMigrationSize = min(
        Int(UInt32.max),
        Int(UInt32.max) - pbRawVarint32Size(UInt32.max) + itemSizeHolderSize
      )
      var prospectiveSize = itemSizeHolderSize
      for key in self.keysInRecordOrder() {
        let value = key.bytes.withUnsafeBytes { self.getRawDataForKey($0) }
        let dataLength = value.count + fixed32Size
        guard
          let entry = Self.encodedEntrySize(
            keyDataLength: key.bytes.count,
            originKeyLength: key.bytes.count,
            dataLength: dataLength,
            isDataHolder: false,
            needsPlainHolder: self.crypter == nil
          )
        else {
          Log.error("[\(self.id)] reject enabling expiration: encoded data would be too large")
          return false
        }
        if entry.totalSize > maximumMigrationSize - prospectiveSize {
          Log.error(
            "[\(self.id)] reject enabling expiration: total encoded data would be too large"
          )
          return false
        }
        prospectiveSize += entry.totalSize
        var data = value.array
        withUnsafeBytes(of: time.littleEndian) { data.append(contentsOf: $0) }
        records.append((key, data))
      }
    }
    if self.enableCompareBeforeSet {
      Log.error("enableCompareBeforeSet will be invalid when Expiration is on")
      self.enableCompareBeforeSet = false
    }
    self.expiredInSeconds = expiredInSeconds
    self.enableKeyExpire = true
    if hasExpireFlag {
      return true
    }
    self.metaInfo.flags |= MetaInfo.Flag.enableKeyExpire
    self.metaInfo.version = MetaInfo.Version.flag
    if self.file.size == self.expectedCapacity && self.actualSize == 0 {
      // A new file needs no rewrite, only the metadata.
      self.writeActualSize(0, crcDigest: 0, iv: nil, increaseSequence: true)
      self.metaFile.msync(synchronously: true)
      return true
    }
    return self.doFullWriteBack(records)
  }

  /// The bytes of `key`'s value without its expiry time. An expired key is removed and reads as
  /// empty (`getDataWithoutMTimeForKey`).
  mutating func getDataWithoutMTimeForKey(_ key: UnsafeRawBufferPointer) -> RawValue {
    self.lockProcess(.shared)
    defer { self.unlockProcess(.shared) }
    self.checkLoadData()
    let raw = self.getRawDataForKey(key)
    if raw.count < fixed32Size {
      if raw.count != 0 {
        Log.warning("key has invalid value size \(raw.count)")
      }
      return raw
    }
    let newLength = raw.count - fixed32Size
    if self.enableKeyExpire {
      let time = raw.withBytes { Self.expirationTime(of: $0) }
      if time != 0 && time <= Self.currentTimeInSeconds() {
        self.removeValue(forKey: key)
        return .empty
      }
    }
    return raw.prefix(newLength)
  }

  /// Drops expired keys from the index, without writing anything (`filterExpiredKeys`).
  ///
  /// - Returns: How many keys were dropped.
  @discardableResult
  mutating func filterExpiredKeys() -> Int {
    guard self.enableKeyExpire, self.indexCount != 0, let memory = self.file.memory else {
      return 0
    }
    self.sharedProcessLock.lock()
    defer { self.sharedProcessLock.unlock() }
    let now = Self.currentTimeInSeconds()
    if let crypter = self.crypter {
      return self.dicCrypt.removeAll { entry in
        guard entry.realValueSize >= fixed32Size else {
          Log.warning("key has invalid value size \(entry.realValueSize)")
          return false
        }
        let time = Self.value(of: entry, memory: memory, crypter: crypter)
          .withBytes { Self.expirationTime(of: $0) }
        return time != 0 && time <= now
      }
    }
    let base = UnsafeRawPointer(memory + fixed32Size)
    return self.dic.removeAll { location in
      guard location.valueSize >= UInt32(fixed32Size) else {
        Log.warning("key has invalid value size \(location.valueSize)")
        return false
      }
      let value = UnsafeRawBufferPointer(
        start: base + location.valueOffset,
        count: Int(location.valueSize)
      )
      let time = Self.expirationTime(of: value)
      return time != 0 && time <= now
    }
  }
}
