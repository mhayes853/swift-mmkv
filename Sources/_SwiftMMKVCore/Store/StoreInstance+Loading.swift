// Loading a store's files and noticing changes made by other processes, from MMKV_IO.cpp.

extension StoreState {
  /// Reads the metadata, validates the data, and builds the index (`loadFromFile`).
  mutating func loadFromFile() {
    self.hasUndecodableData = false
    self.loadMetaInfoAndCheck()
    // Another process may have resized the file since this instance mapped it.
    if !self.file.isFileValid
      || (self.isMultiProcess && self.file.actualFileSize != self.file.size)
    {
      self.file.reloadFromFile(expectedCapacity: self.expectedCapacity)
    }
    if self.file.isFileValid && self.metaFile.isFileValid && self.recoverInterruptedRewrite() {
      self.loadMetaInfoAndCheck()
    }
    if self.metaInfo.version >= MetaInfo.Version.randomIV {
      self.crypter?.resetIV(self.metaInfo.vector)
    }
    if !self.file.isFileValid {
      Log.error("file [\(self.path)] not valid")
    } else {
      var loadFromFile = false
      var needFullWriteback = false
      self.checkDataValid(&loadFromFile, &needFullWriteback)
      let fileSize = self.file.size
      if loadFromFile && self.actualSize > 0 {
        let didDecode: Bool
        if self.crypter != nil {
          self.dicCrypt.removeAll()
          didDecode = self.decodeCrypt(from: 0, size: self.actualSize, greedy: needFullWriteback)
        } else {
          let input = UnsafeRawBufferPointer(
            start: self.file.memory! + fixed32Size,
            count: self.actualSize
          )
          self.dic.removeAll()
          didDecode = RecordDecoding.decode(input, into: &self.dic, greedy: needFullWriteback)
        }
        self.output = OutputState(position: self.actualSize, size: fileSize - fixed32Size)
        if !didDecode && !needFullWriteback {
          // The data has the checksum it was written with, so it is what was written, and only
          // the key it is read with can be wrong. The C++ core carries on with no keys, and its
          // next write replaces the data.
          Log.error("[\(self.id)] intact data cannot be decoded: wrong encryption key")
          self.hasUndecodableData = true
          IntegrityFailureReport.send(id: self.id, kind: .wrongEncryptionKey)
          self.needLoadFromFile = false
          return
        }
        // An encrypted store without a random IV gets one straight away.
        if !needFullWriteback && self.crypter != nil
          && self.metaInfo.version < MetaInfo.Version.randomIV
        {
          needFullWriteback = true
        }
        if needFullWriteback && !self.isReadOnly {
          self.lockProcess(.exclusive)
          defer { self.unlockProcess(.exclusive) }
          if self.reloadIfChangedWhileUpgradingLock() {
            return
          }
          self.fullWriteback()
        }
      } else {
        // The file is empty or unreadable: discard everything.
        self.lockProcess(.exclusive)
        defer { self.unlockProcess(.exclusive) }
        if self.reloadIfChangedWhileUpgradingLock() {
          return
        }
        let dataOffset = min(fileSize, fixed32Size)
        self.output = OutputState(position: 0, size: fileSize - dataOffset)
        if !self.isReadOnly {
          let hadData = self.actualSize > 0
          self.writeActualSize(0, crcDigest: 0, iv: nil, increaseSequence: hadData)
          if hadData {
            self.sync()
          }
        }
      }
    }
    self.needLoadFromFile = false
  }

  /// Loads again if another process changed the store since this load read the metadata, with
  /// the exclusive file lock held.
  ///
  /// A load runs under the shared lock and takes the exclusive one to write. Upgrading gives up
  /// the shared lock if another process holds one too, and that process can then write before
  /// this one gets the exclusive lock. Writing what this load decided before that, an empty store
  /// or a rewrite of the records it read, would discard what the other process wrote. The C++
  /// core does not check.
  ///
  /// - Returns: Whether it loaded again, which leaves nothing more for the caller to do.
  private mutating func reloadIfChangedWhileUpgradingLock() -> Bool {
    guard self.isMultiProcess, self.metaFile.isFileValid else { return false }
    let metaInfo = MetaInfo.Summary(reading: self.metaFile.memory!)
    if self.metaInfo.sequence == metaInfo.sequence && self.metaInfo.crcDigest == metaInfo.crcDigest
      && self.metaInfo.actualSize == metaInfo.actualSize
    {
      return false
    }
    self.dic.removeAll()
    self.dicCrypt.removeAll()
    self.loadFromFile()
    return true
  }

  /// Reads only what another process appended since the last load (`partialLoadFromFile`), or
  /// loads everything again if the appended data does not match the checksum.
  ///
  /// - Returns: Whether only the appended data was read.
  @discardableResult
  mutating func partialLoadFromFile() -> Bool {
    guard self.file.isFileValid else { return false }
    self.metaInfo = MetaInfo(reading: self.metaFile.memory!)
    let oldActualSize = self.actualSize
    self.actualSize = self.readActualSize()
    let fileSize = self.file.size
    if self.actualSize > oldActualSize && self.actualSize + fixed32Size <= fileSize {
      let position = oldActualSize
      let addedSize = self.actualSize - position
      let base = UnsafeRawPointer(self.file.memory! + fixed32Size)
      self.crcDigest = CRC32.checksum(
        self.crcDigest,
        UnsafeRawBufferPointer(start: base + position, count: addedSize)
      )
      if self.crcDigest == self.metaInfo.crcDigest {
        if self.crypter != nil {
          self.decodeCrypt(from: position, size: self.actualSize, greedy: true)
        } else {
          let input = UnsafeRawBufferPointer(start: base, count: self.actualSize)
          RecordDecoding.decode(input, from: position, into: &self.dic, greedy: true)
        }
        self.output?.position += addedSize
        self.hasFullWriteback = false
        return true
      }
      Log.error(
        "m_crcDigest[\(self.crcDigest)] != m_metaInfo->m_crcDigest[\(self.metaInfo.crcDigest)]"
      )
    }
    // Something is wrong: load everything.
    self.clearMemoryCache()
    self.loadFromFile()
    return false
  }

  /// Loads the files on first use, and in a multi-process store reloads them if another process
  /// changed them since (`checkLoadData`).
  ///
  /// - Parameter checkingFileSize: Whether to also map the data file again if another process
  ///   shrank it without starting a new sequence (see ``remapIfFileShrunk()``). Operations that
  ///   rewrite or measure the whole file pass `true`.
  mutating func checkLoadData(checkingFileSize: Bool = false) {
    if self.needLoadFromFile {
      self.lockProcess(.shared)
      defer { self.unlockProcess(.shared) }
      self.needLoadFromFile = false
      // What changed while nothing was loaded is not reported, so the hashes start again.
      self.changeTracker = nil
      self.loadFromFile()
      return
    }
    guard self.isMultiProcess, self.metaFile.isFileValid else { return }
    self.lockProcess(.shared)
    defer { self.unlockProcess(.shared) }
    let metaInfo = MetaInfo.Summary(reading: self.metaFile.memory!)
    if self.metaInfo.sequence != metaInfo.sequence {
      // Another process rewrote the file.
      let tracker = self.changeTracker
      self.changeTracker = nil
      self.clearMemoryCache()
      self.loadFromFile()
      self.notifyContentChanged(tracker.map { .keys(self.trackRewrite(from: $0)) } ?? .unknown)
      return
    }
    if self.metaInfo.crcDigest != metaInfo.crcDigest
      || self.metaInfo.actualSize != metaInfo.actualSize
    {
      // Another process appended to it.
      let position = self.actualSize
      let tracker = self.changeTracker
      if self.partialLoadFromFile() {
        let keys = self.trackAppendedRecords(from: position)
        self.notifyContentChanged(keys.map { .keys($0) } ?? .unknown)
      } else {
        // The appended data did not match its checksum, and everything was loaded again.
        self.notifyContentChanged(tracker.map { .keys(self.trackRewrite(from: $0)) } ?? .unknown)
      }
    }
    if checkingFileSize {
      self.remapIfFileShrunk()
    }
  }

  /// Maps a multi-process store's data file again if it is now smaller than its mapping.
  ///
  /// MMKV's `trim` starts no new sequence when the records are already written back, so another
  /// instance can shrink the file with nothing in the metadata to say so. The records stay where
  /// they were, but writing to the mapping past the new end of the file stops the process with
  /// `SIGBUS`. Called with the exclusive file lock held, so the file cannot shrink again before
  /// the write. No instance shrinks a file below one page, so a mapping of one page is never
  /// checked.
  mutating func remapIfFileShrunk() {
    guard self.isMultiProcess, self.file.size > pageSize else { return }
    let fileSize = self.file.actualFileSize
    guard fileSize < self.file.size else { return }
    Log.warning("[\(self.id)] file shrank from \(self.file.size) to \(fileSize) unannounced")
    guard self.file.remapToFileSize(), let output = self.output else { return }
    self.output = OutputState(position: output.position, size: self.file.size - fixed32Size)
  }

  /// Forgets the index and unmaps the data file, so that the next operation loads again
  /// (`clearMemoryCache`).
  mutating func clearMemoryCache(keepSpace: Bool = false) {
    guard !self.needLoadFromFile else { return }
    self.needLoadFromFile = true
    self.hasFullWriteback = false
    self.dic.removeAll()
    self.dicCrypt.removeAll()
    // A read-only store cannot be sure it has a random IV.
    let hasRandomIV = self.metaInfo.version >= MetaInfo.Version.randomIV
    self.crypter?.resetIV(hasRandomIV ? self.metaInfo.vector : nil)
    self.output = nil
    if !keepSpace {
      self.file.clearMemoryCache()
    }
    self.closeRewriteJournal()
    // The metadata file stays open, because a multi-process store's file lock is on it.
    self.actualSize = 0
    self.metaInfo.crcDigest = 0
  }

  // MARK: - Metadata

  mutating func loadMetaInfoAndCheck() {
    if !self.metaFile.isFileValid {
      self.metaFile.reloadFromFile()
    }
    if self.metaFile.isFileValid {
      self.checkFileHasDiskError()
    }
    guard self.metaFile.isFileValid else {
      Log.error("file [\(self.crcPath)] not valid")
      return
    }
    self.metaInfo = MetaInfo(reading: self.metaFile.memory!)
    self.enableKeyExpire =
      self.metaInfo.version >= MetaInfo.Version.flag
      && self.metaInfo.version < MetaInfo.Version.holder
      && self.metaInfo.hasFlag(MetaInfo.Flag.enableKeyExpire)
    if self.isReadOnly {
      return
    }
    if self.metaInfo.version >= MetaInfo.Version.holder {
      Log.warning("meta file [\(self.id)] in specious state, version \(self.metaInfo.version)")
      // MMKVVersionActualSize is the last version that does not check the metadata.
      self.metaInfo.version = MetaInfo.Version.actualSize
      self.metaInfo.flags = 0
      self.metaInfo.write(to: self.metaFile.memory!)
    }
    if self.metaInfo.version >= MetaInfo.Version.flag {
      if self.enableKeyExpire && self.enableCompareBeforeSet {
        Log.error("enableCompareBeforeSet will be invalid when Expiration is on")
        self.enableCompareBeforeSet = false
      }
    } else if self.metaInfo.flags != 0 {
      self.metaInfo.flags = 0
      self.metaInfo.write(to: self.metaFile.memory!)
    }
  }

  /// Deletes a file that cannot even be read, so that it is created again (`checkFileHasDiskError`).
  /// Only done the first time the instance loads.
  mutating func checkFileHasDiskError() {
    if self.isSecondLoad {
      return
    }
    self.isSecondLoad = true
    if Self.isDiskOfMMAPFileCorrupted(&self.metaFile, fileSystem: self.fileSystem) {
      self.metaFile.clearMemoryCache()
      self.deleteOrRenameFile(self.metaFile.path)
      self.metaFile.reloadFromFile()
    }
    if !self.file.isFileValid {
      self.file.reloadFromFile(expectedCapacity: self.expectedCapacity)
    }
    guard self.file.isFileValid else {
      Log.error("file [\(self.path)] not valid")
      return
    }
    if Self.isDiskOfMMAPFileCorrupted(&self.file, fileSystem: self.fileSystem) {
      self.file.clearMemoryCache()
      self.deleteOrRenameFile(self.file.path)
      self.file.reloadFromFile(expectedCapacity: self.expectedCapacity)
    }
  }

  private static func isDiskOfMMAPFileCorrupted(
    _ file: inout MemoryFile,
    fileSystem: FileSystem
  ) -> Bool {
    let descriptor = file.fileDescriptor
    let oldPosition = fileSystem.lseek(descriptor, 0, SEEK_CUR)
    _ = fileSystem.lseek(descriptor, 0, SEEK_SET)
    var info: UInt32 = 0
    let size = withUnsafeMutableBytes(of: &info) {
      fileSystem.read(descriptor, $0.baseAddress!, 4)
    }
    let error = errno
    _ = fileSystem.lseek(descriptor, oldPosition, SEEK_SET)
    if size <= 0 {
      Log.error("fail to read [\(file.path)] from fd [\(descriptor)], errno: \(error)")
      if error == EIO || error == EILSEQ || error == EINVAL || error == ENXIO {
        Log.warning("file fail to read, consider it illegal, delete now: [\(file.path)]")
        return true
      }
    }
    file.cleanMayflyFD()
    return false
  }

  private func deleteOrRenameFile(_ path: String) {
    guard self.fileSystem.unlink(path) != 0 else { return }
    let suffix = UInt64.random(in: .min ... .max)
    _ = self.fileSystem.rename(path, "\(path).\(suffix).tmp")
  }

  /// Decides whether the data can be loaded, falling back to the last confirmed size and checksum
  /// when the current ones do not match, and to the recovery policy when nothing matches
  /// (`checkDataValid`).
  mutating func checkDataValid(_ loadFromFile: inout Bool, _ needFullWriteback: inout Bool) {
    let fileSize = self.file.size
    if fileSize < fixed32Size {
      Log.error("check [\(self.id)] error: file size \(fileSize) is too small")
      self.actualSize = 0
      return
    }
    /// Loads the first `size` bytes of data if they have the checksum `crcDigest`, recording them
    /// as the current size and checksum.
    func loadIfValid(_ size: Int, _ crcDigest: UInt32) -> Bool {
      guard self.checkFileCRCValid(size, crcDigest) else { return false }
      loadFromFile = true
      self.actualSize = size
      self.writeActualSize(size, crcDigest: crcDigest, iv: nil, increaseSequence: false)
      return true
    }

    func checkLastConfirmedInfo() {
      guard self.metaInfo.version >= MetaInfo.Version.actualSize else { return }
      // A downgrade to an older MMKV and back writes the size only into the data file.
      let oldStyleActualSize = Int(
        UInt32(littleEndian: self.file.memory!.loadUnaligned(as: UInt32.self))
      )
      if oldStyleActualSize != self.actualSize {
        Log.warning(
          "oldStyleActualSize \(oldStyleActualSize) not equal to meta actual size \(self.actualSize)"
        )
        if oldStyleActualSize + fixed32Size <= fileSize {
          if loadIfValid(oldStyleActualSize, self.metaInfo.crcDigest) {
            return
          }
        } else {
          Log.warning("oldStyleActualSize \(oldStyleActualSize) greater than file size \(fileSize)")
        }
      }
      let lastActualSize = Int(self.metaInfo.lastActualSize)
      if lastActualSize + fixed32Size <= fileSize {
        let lastCRCDigest = self.metaInfo.lastCRCDigest
        if !loadIfValid(lastActualSize, lastCRCDigest) {
          Log.error(
            "check [\(self.id)] error: lastActualSize \(lastActualSize), lastActualCRC \(lastCRCDigest)"
          )
        }
      } else {
        Log.error(
          "check [\(self.id)] error: lastActualSize \(lastActualSize), file size is \(fileSize)"
        )
      }
    }

    self.actualSize = self.readActualSize()
    if self.actualSize + fixed32Size <= fileSize {
      if self.checkFileCRCValid(self.actualSize, self.metaInfo.crcDigest) {
        loadFromFile = true
      } else {
        checkLastConfirmedInfo()
        if !loadFromFile {
          IntegrityFailureReport.send(id: self.id, kind: .checksum)
          if self.recoverOnError {
            loadFromFile = true
            needFullWriteback = true
          }
        }
      }
    } else {
      Log.error(
        "check [\(self.id)] error: \(self.actualSize) size in total, file size is \(fileSize)"
      )
      checkLastConfirmedInfo()
      if !loadFromFile {
        IntegrityFailureReport.send(id: self.id, kind: .fileLength)
        if self.recoverOnError {
          // Do not read past the end of the file.
          self.actualSize = fileSize - fixed32Size
          loadFromFile = true
          needFullWriteback = true
        }
      }
    }
  }

  /// Whether the first `actualSize` bytes of data have the checksum `crcDigest`, leaving the
  /// computed checksum in ``crcDigest``.
  mutating func checkFileCRCValid(_ actualSize: Int, _ crcDigest: UInt32) -> Bool {
    guard let memory = self.file.memory else { return false }
    self.crcDigest = CRC32.checksum(
      0,
      UnsafeRawBufferPointer(start: memory + fixed32Size, count: actualSize)
    )
    if self.crcDigest == crcDigest {
      return true
    }
    Log.error("check crc [\(self.id)] fail, crc32:\(crcDigest), m_crcDigest:\(self.crcDigest)")
    return false
  }

  /// The size of the data, from the metadata or, for files older than version 3, from the data
  /// file's header (`readActualSize`).
  func readActualSize() -> Int {
    if self.metaInfo.version >= MetaInfo.Version.actualSize {
      return Int(self.metaInfo.actualSize)
    }
    return Int(UInt32(littleEndian: self.file.memory!.loadUnaligned(as: UInt32.self)))
  }
}
