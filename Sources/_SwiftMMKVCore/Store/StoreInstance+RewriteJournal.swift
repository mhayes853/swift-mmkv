// Keeping a store whose process stops while its file is being rewritten. The C++ core has nothing
// like it.
//
// A full write-back moves the records about in place. Until it is done and the metadata describes
// the result, the file matches neither its checksum nor its last confirmed one, so a process that
// stops part way leaves a store that fails its integrity check, and every key is discarded.
//
// Before a rewrite touches the data, the Swift core copies the metadata and the data to a journal
// beside the store, `<store>.journal`. The rewrite ends by writing the metadata, the sequence
// number last, and then empties the journal. A load that finds a journal with the metadata's
// sequence number knows the rewrite did not end, and puts the journal's metadata and data back.
// Either way the store is what it was before the rewrite or what the rewrite made it.
//
// The journal is the metadata file's 112 bytes, the size of the data file's contents that
// follow, and those contents: the size header and the data. Creating, opening, or emptying a file
// each costs several times what a small rewrite does, so the journal is left open and in place
// between rewrites: once the metadata's sequence number has moved on, it means nothing.
//
// Neither of the store's files changes format, and a store is never left needing its journal by a
// rewrite that ended: the C++ core, which ignores the journal, reads the same files it always has.

extension StoreState {
  // MARK: - Writing the journal

  /// Copies the metadata and the data, as they are before a rewrite, to the journal.
  ///
  /// The sequence number goes up first, so that every other process loads again once this one
  /// lets go of the file lock, and finds the journal if the rewrite did not end.
  ///
  /// - Returns: The size of the journal, to pass to ``endRewriteJournal(size:)`` once the rewrite
  ///   ends, or `nil` if there is no journal: the store has no data, or the journal cannot be
  ///   written. The rewrite then goes ahead as the C++ core's does.
  mutating func beginRewriteJournal() -> Int? {
    guard self.actualSize > 0, !self.isReadOnly, self.metaFile.isFileValid,
      let data = self.file.memory, let meta = self.metaFile.memory
    else {
      return nil
    }
    self.invalidateChangeTracker()
    self.metaInfo.sequence &+= 1
    self.metaInfo.writeSequence(to: meta)
    if self.journalDescriptor < 0 {
      self.journalDescriptor = self.fileSystem.open(
        self.journalPath,
        O_WRONLY | O_CREAT | O_CLOEXEC,
        S_IRWXU
      )
      self.giveJournalDataProtection()
    }
    let descriptor = self.journalDescriptor
    guard descriptor >= 0 else {
      Log.warning("[\(self.id)] cannot open the rewrite journal, errno: \(errno)")
      return nil
    }
    let dataSize = fixed32Size + self.actualSize
    let didWrite = withUnsafeTemporaryAllocation(
      byteCount: Self.journalHeaderSize,
      alignment: 4
    ) { header in
      header.baseAddress!.copyMemory(from: meta, byteCount: MetaInfo.size)
      header.storeBytes(
        of: UInt32(truncatingIfNeeded: dataSize).littleEndian,
        toByteOffset: MetaInfo.size,
        as: UInt32.self
      )
      return self.fileSystem.lseek(descriptor, 0, SEEK_SET) == 0
        && self.writeAll(descriptor, UnsafeRawBufferPointer(header))
        && self.writeAll(descriptor, UnsafeRawBufferPointer(start: data, count: dataSize))
    }
    guard didWrite else {
      Log.warning("[\(self.id)] cannot write the rewrite journal, errno: \(errno)")
      // What was written of it must not be taken for a journal.
      _ = self.fileSystem.ftruncate(descriptor, 0)
      self.closeRewriteJournal()
      return nil
    }
    return Self.journalHeaderSize + dataSize
  }

  /// Called once a rewrite has ended and the metadata's sequence number has moved on from its
  /// journal's. A large journal is emptied, so that a store does not take twice its size on disk.
  func endRewriteJournal(size: Int) {
    if size > Self.largestJournalKept {
      _ = self.fileSystem.ftruncate(self.journalDescriptor, 0)
    }
  }

  /// Closes the journal's descriptor, which the next rewrite opens again.
  /// Gives the journal the data file's data protection class, as it holds a copy of that file.
  /// A new file otherwise takes its directory's class, and one stricter than the data file's
  /// could not be written while the device is locked.
  private func giveJournalDataProtection() {
    #if canImport(Darwin)
      guard self.journalDescriptor >= 0 else { return }
      let dataDescriptor = open(self.path, O_RDONLY | O_CLOEXEC)
      guard dataDescriptor >= 0 else { return }
      defer { close(dataDescriptor) }
      let protectionClass = fcntl(dataDescriptor, F_GETPROTECTIONCLASS)
      if protectionClass > 0, fcntl(self.journalDescriptor, F_GETPROTECTIONCLASS) != protectionClass
      {
        _ = fcntl(self.journalDescriptor, F_SETPROTECTIONCLASS, protectionClass)
      }
    #endif
  }

  mutating func closeRewriteJournal() {
    if self.journalDescriptor >= 0 {
      _ = self.fileSystem.close(self.journalDescriptor)
      self.journalDescriptor = -1
    }
  }

  private static var largestJournalKept: Int { 1 << 18 }

  /// The metadata, then the size of what follows.
  private static var journalHeaderSize: Int { MetaInfo.size + fixed32Size }

  private func writeAll(_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
    var written = 0
    while written < bytes.count {
      let count = self.fileSystem.write(
        descriptor,
        bytes.baseAddress! + written,
        bytes.count - written
      )
      if count < 0 && errno == EINTR {
        continue
      }
      guard count > 0 else { return false }
      written += count
    }
    return true
  }

  // MARK: - Recovering from it

  /// Puts back what the journal holds if a rewrite did not end. Called
  /// as a load starts, with the metadata read and the data file mapped.
  ///
  /// - Returns: Whether the metadata was changed, which the load must then read again.
  mutating func recoverInterruptedRewrite() -> Bool {
    guard !self.isReadOnly, (self.fileSystem.fileSizeAtPath(self.journalPath) ?? 0) > 0 else {
      return false
    }
    self.lockProcess(.exclusive)
    defer { self.unlockProcess(.exclusive) }
    // Another process may have recovered while this one waited for the lock.
    guard let journal = self.readJournal(), let meta = self.metaFile.memory else { return false }
    self.metaInfo = MetaInfo(reading: meta)
    var journalMeta = MetaInfo()
    var dataSize = 0
    var isWhole = false
    journal.withUnsafeBytes { journal in
      guard journal.count >= Self.journalHeaderSize + fixed32Size else { return }
      journalMeta = MetaInfo(reading: journal.baseAddress!)
      dataSize = Int(
        UInt32(littleEndian: journal.loadUnaligned(fromByteOffset: MetaInfo.size, as: UInt32.self))
      )
      guard dataSize >= fixed32Size, journal.count >= Self.journalHeaderSize + dataSize else {
        return
      }
      let records = journal[Self.journalHeaderSize..<(Self.journalHeaderSize + dataSize)]
        .dropFirst(fixed32Size)
      isWhole =
        CRC32.checksum(0, UnsafeRawBufferPointer(rebasing: records)) == journalMeta.crcDigest
    }
    // A journal that was not written whole was not followed by a rewrite, and one with another
    // sequence number is left over from a rewrite that ended.
    guard isWhole, journalMeta.sequence == self.metaInfo.sequence else { return false }

    // The rewrite's last writes are the size, the checksum, and then the sequence number. If the
    // size and checksum match the data, everything but the sequence number was written.
    let size = self.readActualSize()
    if size + fixed32Size <= self.file.size, let data = self.file.memory,
      CRC32.checksum(0, UnsafeRawBufferPointer(start: data + fixed32Size, count: size))
        == self.metaInfo.crcDigest
    {
      self.metaInfo.sequence &+= 1
      self.metaInfo.writeSequence(to: meta)
      return true
    }

    Log.warning("[\(self.id)] a rewrite was interrupted, restoring \(dataSize) bytes")
    if self.file.size < dataSize {
      guard self.file.truncate(to: dataSize) else { return false }
    }
    guard let data = self.file.memory else { return false }
    journal.withUnsafeBytes {
      data.copyMemory(from: $0.baseAddress! + Self.journalHeaderSize, byteCount: dataSize)
    }
    // The sequence number is written last here too, so stopping part way leaves the journal in
    // force, and it moves on so that other processes load again.
    var restored = journalMeta
    restored.sequence = self.metaInfo.sequence &+ 1
    restored.write(to: meta)
    self.metaInfo = restored
    return true
  }

  private func readJournal() -> [UInt8]? {
    let descriptor = self.fileSystem.open(self.journalPath, O_RDONLY | O_CLOEXEC, 0)
    guard descriptor >= 0 else { return nil }
    defer { _ = self.fileSystem.close(descriptor) }
    guard let size = self.fileSystem.fileSize(descriptor) else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    var count = 0
    while count < size {
      let read = bytes.withUnsafeMutableBytes {
        self.fileSystem.read(descriptor, $0.baseAddress! + count, size - count)
      }
      if read < 0 && errno == EINTR {
        continue
      }
      guard read > 0 else { break }
      count += read
    }
    bytes.removeLast(size - count)
    return bytes
  }
}
