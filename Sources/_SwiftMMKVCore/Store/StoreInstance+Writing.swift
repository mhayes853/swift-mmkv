// Writing records, growing and compacting the file, and keeping the metadata in step, from
// MMKV_IO.cpp.

/// The size of the placeholder at the start of the data, a varint that readers skip.
let itemSizeHolderSize = 4

/// A full rewrite's data: either the records already in the file, to be moved into place, or an
/// encoded container of records (`std::pair<MMBuffer, size_t>` from `prepareEncode`).
struct PreparedData {
  /// An encoded container, or `nil` to move the records already in the file.
  var encoded: [UInt8]?
  /// The size of the rewritten data, including the placeholder.
  var totalSize: Int
  /// An encrypted store's slots in record order, sorted once for both preparing and rewriting,
  /// and the index's version when they were.
  var cryptOrder: (slots: LazyMapSequence<[UInt64], Int>, version: Int)? = nil
}

extension StoreState {
  // MARK: - Reading values

  /// The bytes of `key`'s value, including any expiry time, or no bytes (`getRawDataForKey`).
  func getRawDataForKey(_ key: UnsafeRawBufferPointer) -> RawValue {
    if self.crypter != nil {
      guard let entry = self.dicCrypt.entry(of: key) else { return .empty }
      return self.value(of: entry)
    }
    guard let base = self.dataBase, let location = self.dic.location(of: key, base: base) else {
      return .empty
    }
    return .mapped(
      UnsafeRawBufferPointer(start: base + location.valueOffset, count: Int(location.valueSize))
    )
  }

  /// The bytes of `key`'s value without its expiry time, after loading any changes
  /// (`getDataForKey`).
  mutating func getDataForKey(_ key: UnsafeRawBufferPointer) -> RawValue {
    self.checkLoadData()
    if self.enableKeyExpire {
      return self.getDataWithoutMTimeForKey(key)
    }
    return self.getRawDataForKey(key)
  }

  // MARK: - Writing values

  /// Writes `data` as `key`'s value (`setDataForKey(data, key, isDataHolder)`). A data holder is a
  /// string or raw bytes, whose length is written before them inside the value.
  mutating func setDataForKey(
    _ data: UnsafeRawBufferPointer,
    _ key: UnsafeRawBufferPointer,
    isDataHolder: Bool
  ) -> Bool {
    if (!isDataHolder && data.isEmpty) || key.isEmpty {
      return false
    }
    guard Self.encodedValueLength(data.count, isDataHolder: isDataHolder) != nil else {
      Log.error("[\(self.id)] reject value too large to encode: \(data.count)")
      return false
    }
    if self.crypter != nil {
      guard self.setCryptDataForKey(data, key, isDataHolder: isDataHolder) else {
        return false
      }
      self.hasFullWriteback = false
      return true
    }
    // One lookup serves the whole write: the slot found is updated afterwards, unless keys were
    // added or removed in between.
    let hash = self.dic.hash(key)
    let probe = self.dic.probe(key, hash: hash, base: self.dataBase)
    let version = self.dic.version
    let location: RecordLocation?
    if case .found(let slot) = probe {
      let existing = self.dic.location(at: slot)
      if self.isCompareBeforeSetEnabled, let base = self.dataBase {
        let old = UnsafeRawBufferPointer(
          start: base + existing.valueOffset,
          count: Int(existing.valueSize)
        )
        if isDataHolder {
          var input = CodedInput(old)
          if let range = try? input.readLengthDelimited(exactly: true),
            data.elementsEqual(input.bytes(in: range))
          {
            return true
          }
        } else if data.elementsEqual(old) {
          return true
        }
      }
      // A single-process store whose only key this is rewrites the file from the start.
      let onlyOneKey = !self.isMultiProcess && self.dic.count == 1
      if !self.enableKeyExpire {
        location =
          onlyOneKey
          ? self.overrideDataWithKey(data, holderOf: key, isDataHolder: isDataHolder)
          : self.appendDataWithKey(data, holderOf: key, isDataHolder: isDataHolder)
      } else {
        location =
          onlyOneKey
          ? self.overrideDataWithKey(data, key: key, isDataHolder: isDataHolder)
          : self.appendDataWithKey(data, key: key, isDataHolder: isDataHolder)
      }
    } else {
      let needOverride = !self.isMultiProcess && self.dic.isEmpty && self.actualSize > 0
      location =
        needOverride
        ? self.overrideDataWithKey(data, key: key, isDataHolder: isDataHolder)
        : self.appendDataWithKey(data, key: key, isDataHolder: isDataHolder)
    }
    guard let location else { return false }
    self.setLocation(location, for: key, hash: hash, probe: probe, version: version)
    self.hasFullWriteback = false
    return true
  }

  /// Records `location` as `key`'s, in the slot `probe` found when the index was at `version`.
  private mutating func setLocation(
    _ location: RecordLocation,
    for key: UnsafeRawBufferPointer,
    hash: UInt32,
    probe: RecordIndex.Probe,
    version: Int
  ) {
    guard self.dic.version == version else {
      // Making space removed expired keys, which moves others between slots.
      self.dic.set(location, for: key, base: self.dataBase)
      return
    }
    switch probe {
    case .found(let slot): self.dic.setLocation(location, at: slot)
    case .vacant(let slot): self.dic.insert(location, hash: hash, at: slot)
    }
  }

  /// The length of a value as written, or `nil` if it cannot be represented (`encodedValueLength`).
  static func encodedValueLength(_ dataLength: Int, isDataHolder: Bool) -> Int? {
    guard dataLength <= Int(UInt32.max) else { return nil }
    var length = dataLength
    if isDataHolder {
      length += pbRawVarint32Size(UInt32(dataLength))
    }
    return length <= Int(UInt32.max) ? length : nil
  }

  struct EncodedEntrySize {
    var keyAlreadyEncoded: Bool
    var valueLength: Int
    var totalSize: Int
  }

  /// The size of a record (`encodedEntrySize`). `keyDataLength` is longer than `originKeyLength`
  /// when the key is already length-delimited.
  static func encodedEntrySize(
    keyDataLength: Int,
    originKeyLength: Int,
    dataLength: Int,
    isDataHolder: Bool,
    needsPlainHolder: Bool
  ) -> EncodedEntrySize? {
    let maxEncodedLength = Int(UInt32.max)
    if originKeyLength > keySizeLimit || keyDataLength < originKeyLength
      || keyDataLength > maxEncodedLength
    {
      return nil
    }
    let keyAlreadyEncoded = originKeyLength < keyDataLength
    guard let valueLength = Self.encodedValueLength(dataLength, isDataHolder: isDataHolder) else {
      return nil
    }
    var keyValueSize = keyDataLength + pbRawVarint32Size(UInt32(valueLength))
    if !keyAlreadyEncoded {
      keyValueSize += pbRawVarint32Size(UInt32(keyDataLength))
    }
    if needsPlainHolder && keyValueSize > Int(UInt16.max) {
      return nil
    }
    let totalSize = keyValueSize + valueLength
    guard totalSize <= maxEncodedLength else { return nil }
    return EncodedEntrySize(
      keyAlreadyEncoded: keyAlreadyEncoded,
      valueLength: valueLength,
      totalSize: totalSize
    )
  }

  /// The size of a record for `key`, which the index holds, whose current record has the key's
  /// length before it (the `encodedEntrySize` of the `kvHolder` overloads).
  private static func encodedEntrySize(
    holderOf key: UnsafeRawBufferPointer,
    dataLength: Int,
    isDataHolder: Bool
  ) -> EncodedEntrySize? {
    Self.encodedEntrySize(
      keyDataLength: key.count + pbRawVarint32Size(UInt32(key.count)),
      originKeyLength: key.count,
      dataLength: dataLength,
      isDataHolder: isDataHolder,
      needsPlainHolder: true
    )
  }

  /// The size of a record of `data` for `keyData`, or `nil`, with an error logged, if it cannot be
  /// written: the checks that `doAppendDataWithKey` and `doOverrideDataWithKey` start with.
  @inline(__always)
  private func checkedEntrySize(
    _ data: UnsafeRawBufferPointer,
    keyData: UnsafeRawBufferPointer,
    isDataHolder: Bool,
    originKeyLength: Int,
    function: StaticString = #function
  ) -> EncodedEntrySize? {
    guard
      let entry = Self.encodedEntrySize(
        keyDataLength: keyData.count,
        originKeyLength: originKeyLength,
        dataLength: data.count,
        isDataHolder: isDataHolder,
        needsPlainHolder: self.crypter == nil
      )
    else {
      Log.error(
        "[\(self.id)] reject unrepresentable key/value lengths, key=\(originKeyLength), value=\(data.count)",
        function: function
      )
      return nil
    }
    return self.checkSizeLimit(entry.totalSize) ? entry : nil
  }

  /// Appends a record for `key` (`appendDataWithKey(data, key)`).
  mutating func appendDataWithKey(
    _ data: UnsafeRawBufferPointer,
    key: UnsafeRawBufferPointer,
    isDataHolder: Bool
  ) -> RecordLocation? {
    self.doAppendDataWithKey(
      data,
      keyData: key,
      isDataHolder: isDataHolder,
      originKeyLength: key.count
    )
  }

  /// Appends a record for `key`, which the index holds (`appendDataWithKey(data, kvHolder)`).
  ///
  /// The C++ core copies the length-delimited key from the key's current record. The record holds
  /// the same bytes as `key`, so this writes `key` instead, but makes space before checking the
  /// size limit, as the C++ core does.
  mutating func appendDataWithKey(
    _ data: UnsafeRawBufferPointer,
    holderOf key: UnsafeRawBufferPointer,
    isDataHolder: Bool
  ) -> RecordLocation? {
    self.exclusiveProcessLock.lock()
    defer { self.exclusiveProcessLock.unlock() }
    guard
      let entry = Self.encodedEntrySize(
        holderOf: key,
        dataLength: data.count,
        isDataHolder: isDataHolder
      ),
      self.ensureMemorySize(entry.totalSize)
    else {
      return nil
    }
    return self.doAppendDataWithKey(
      data,
      keyData: key,
      isDataHolder: isDataHolder,
      originKeyLength: key.count
    )
  }

  mutating func doAppendDataWithKey(
    _ data: UnsafeRawBufferPointer,
    keyData: UnsafeRawBufferPointer,
    isDataHolder: Bool,
    originKeyLength: Int
  ) -> RecordLocation? {
    guard
      let entry = self.checkedEntrySize(
        data,
        keyData: keyData,
        isDataHolder: isDataHolder,
        originKeyLength: originKeyLength
      )
    else { return nil }
    self.exclusiveProcessLock.lock()
    defer { self.exclusiveProcessLock.unlock() }
    guard self.ensureMemorySize(entry.totalSize), self.isFileValid else { return nil }
    if CryptEntry.isValueStoredAsOffset(entry.valueLength), let state = self.crypter?.state {
      self.appendState = state
    }
    do throws(CodingError) {
      try self.withOutput { (output) throws(CodingError) in
        try Self.writeRecord(
          to: &output,
          keyData: keyData,
          keyAlreadyEncoded: entry.keyAlreadyEncoded,
          data: data,
          isDataHolder: isDataHolder,
          valueLength: entry.valueLength
        )
      }
    } catch {
      Log.error("\(error)")
      return nil
    }
    let offset = self.actualSize
    let pointer = self.file.memory! + fixed32Size + self.actualSize
    self.crypter?.encrypt(pointer, pointer, count: entry.totalSize)
    self.actualSize += entry.totalSize
    self.updateCRCDigest(UnsafeRawBufferPointer(start: pointer, count: entry.totalSize))
    return RecordLocation(keySize: originKeyLength, valueSize: entry.valueLength, offset: offset)
  }

  /// Rewrites the data from the start as a single record for `key` (`overrideDataWithKey(data, key)`).
  mutating func overrideDataWithKey(
    _ data: UnsafeRawBufferPointer,
    key: UnsafeRawBufferPointer,
    isDataHolder: Bool
  ) -> RecordLocation? {
    self.doOverrideDataWithKey(
      data,
      keyData: key,
      isDataHolder: isDataHolder,
      originKeyLength: key.count
    )
  }

  /// Rewrites the data from the start as a single record for `key`, which the index holds
  /// (`overrideDataWithKey(data, kvHolder)`). Writes `key` rather than copying it from its
  /// record, as ``appendDataWithKey(_:holderOf:isDataHolder:)`` does.
  mutating func overrideDataWithKey(
    _ data: UnsafeRawBufferPointer,
    holderOf key: UnsafeRawBufferPointer,
    isDataHolder: Bool
  ) -> RecordLocation? {
    guard
      let entry = Self.encodedEntrySize(
        holderOf: key,
        dataLength: data.count,
        isDataHolder: isDataHolder
      )
    else { return nil }
    if !self.checkSizeForOverride(entry.totalSize) {
      return self.appendDataWithKey(data, holderOf: key, isDataHolder: isDataHolder)
    }
    return self.doOverrideDataWithKey(
      data,
      keyData: key,
      isDataHolder: isDataHolder,
      originKeyLength: key.count
    )
  }

  mutating func doOverrideDataWithKey(
    _ data: UnsafeRawBufferPointer,
    keyData: UnsafeRawBufferPointer,
    isDataHolder: Bool,
    originKeyLength: Int
  ) -> RecordLocation? {
    guard
      let entry = self.checkedEntrySize(
        data,
        keyData: keyData,
        isDataHolder: isDataHolder,
        originKeyLength: originKeyLength
      )
    else { return nil }
    // Rewriting encrypted data in place would reuse the IV, so an encrypted store appends.
    if self.crypter != nil || !self.checkSizeForOverride(entry.totalSize) {
      return self.doAppendDataWithKey(
        data,
        keyData: keyData,
        isDataHolder: isDataHolder,
        originKeyLength: originKeyLength
      )
    }
    do throws(CodingError) {
      try self.withOutput { (output) throws(CodingError) in
        try output.setPosition(0)
        try output.writeUInt32(Self.randomItemSizeHolder())
      }
      self.actualSize = itemSizeHolderSize
      try self.withOutput { (output) throws(CodingError) in
        try Self.writeRecord(
          to: &output,
          keyData: keyData,
          keyAlreadyEncoded: entry.keyAlreadyEncoded,
          data: data,
          isDataHolder: isDataHolder,
          valueLength: entry.valueLength
        )
      }
    } catch {
      Log.error("\(error)")
      return nil
    }
    let offset = self.actualSize
    self.actualSize += entry.totalSize
    self.recalculateCRCDigestOnly()
    return RecordLocation(keySize: originKeyLength, valueSize: entry.valueLength, offset: offset)
  }

  private static func writeRecord(
    to output: inout CodedOutput,
    keyData: UnsafeRawBufferPointer,
    keyAlreadyEncoded: Bool,
    data: UnsafeRawBufferPointer,
    isDataHolder: Bool,
    valueLength: Int
  ) throws(CodingError) {
    if keyAlreadyEncoded {
      try output.writeRawData(keyData)
    } else {
      try output.writeData(keyData)
    }
    if isDataHolder {
      try output.writeRawVarint32(UInt32(valueLength))
    }
    try output.writeData(data)
  }

  /// Whether a record of `size` fits in the file without growing it (`checkSizeForOverride`).
  func checkSizeForOverride(_ size: Int) -> Bool {
    guard self.checkFileValid() else { return false }
    let spaceNeededForOverride = size + fixed32Size + itemSizeHolderSize
    return spaceNeededForOverride <= self.file.size
  }

  /// Whether a record of `size` is within the item size limit (`checkSizeLimit`).
  func checkSizeLimit(_ size: Int) -> Bool {
    if self.itemSizeLimit != 0 && size > Int(self.itemSizeLimit) {
      Log.error(
        "[\(self.id)] itemSizeLimit \(self.itemSizeLimit): ignore value size \(size) too large"
      )
      return false
    }
    return true
  }

  /// Runs `body` with the output over the current mapping, keeping the position it ends at even
  /// if it throws part way, as the C++ core's `m_output` does.
  mutating func withOutput<R>(_ body: (inout CodedOutput) throws(CodingError) -> R)
    throws(CodingError) -> R
  {
    guard let state = self.output, let memory = self.file.memory else { throw .outOfSpace }
    // `body` writes to a copy, which is stored back once it returns or throws.
    var output = CodedOutput(base: memory + fixed32Size, size: state.size, position: state.position)
    defer { self.output = OutputState(position: output.position, size: state.size) }
    return try body(&output)
  }

  /// A random varint value that takes exactly four bytes, for the placeholder at the start of the
  /// data (`AESCrypt::randomItemSizeHolder(4)`).
  static func randomItemSizeHolder() -> UInt32 {
    UInt32.random(in: 0x20_0000...0x0fff_ffff)
  }

  // MARK: - Making space

  /// Makes room for `newSize` more bytes, compacting the file, and growing it if that is not
  /// enough (`ensureMemorySize`).
  mutating func ensureMemorySize(_ newSize: Int) -> Bool {
    if self.isMultiProcess, let output = self.output, newSize > 0 {
      // The page holding the end of the data is part of the file however another process has
      // resized it, so only a write that reaches a later page needs the file's size.
      let start = fixed32Size + output.position
      if (start + newSize - 1) / pageSize != (start - 1) / pageSize {
        self.remapIfFileShrunk()
      }
    }
    guard self.checkFileValid(), self.checkWritable() else { return false }
    let maximumActualSize = Int(UInt32.max)
    if newSize > maximumActualSize {
      return false
    }
    let exceedsActualSize = self.actualSize > maximumActualSize - newSize
    let spaceLeft = self.output?.spaceLeft ?? 0
    if newSize >= spaceLeft || self.indexCount == 0 || exceedsActualSize {
      if self.enableKeyExpire {
        self.filterExpiredKeys()
      }
      let prepared = self.prepareEncode()
      if prepared.totalSize > maximumActualSize - newSize {
        Log.error(
          "[\(self.id)] reject write exceeding maximum actual size, compacted=\(prepared.totalSize), incoming=\(newSize)"
        )
        return false
      }
      // An empty index means this is the first write, so there is nothing to sync.
      return self.expandAndWriteBack(newSize, prepared, needSync: self.indexCount != 0)
    }
    return true
  }

  /// The records to rewrite: those already in the file (`prepareEncode(m_dic)`).
  func prepareEncode() -> PreparedData {
    if self.crypter != nil {
      return self.prepareEncodeCrypt()
    }
    var totalSize = itemSizeHolderSize
    self.dic.forEachRecord { _, location in
      totalSize += location.size
    }
    return PreparedData(encoded: nil, totalSize: totalSize)
  }

  /// The records to rewrite from an encoded list of keys and values (`prepareEncode(MMKVVector)`).
  func prepareEncode(_ records: [(key: StoreKey, value: [UInt8])]) -> PreparedData {
    var containerSize = 0
    for record in records where !record.key.bytes.isEmpty {
      containerSize += pbRawVarint32Size(UInt32(record.key.bytes.count)) + record.key.bytes.count
      containerSize += pbRawVarint32Size(UInt32(record.value.count)) + record.value.count
    }
    var encoded = [UInt8](
      repeating: 0,
      count: pbRawVarint32Size(UInt32(containerSize)) + containerSize
    )
    encoded.withUnsafeMutableBytes { buffer in
      var output = CodedOutput(buffer)
      try? output.writeUInt32(UInt32(containerSize))
      for record in records where !record.key.bytes.isEmpty {
        record.key.bytes.withUnsafeBytes { try? output.writeData($0) }
        record.value.withUnsafeBytes { try? output.writeData($0) }
      }
    }
    return PreparedData(encoded: encoded, totalSize: itemSizeHolderSize + containerSize)
  }

  /// Grows the file if the rewritten data, `newSize` more bytes, and room for future writes would
  /// not fit, then rewrites it (`expandAndWriteBack`).
  mutating func expandAndWriteBack(_ newSize: Int, _ prepared: PreparedData, needSync: Bool = true)
    -> Bool
  {
    var fileSize = self.file.size
    let sizeOfDic = prepared.totalSize
    let maxSize = Int.max
    if sizeOfDic > maxSize - fixed32Size || newSize > maxSize - fixed32Size - sizeOfDic {
      return false
    }
    let lenNeeded = sizeOfDic + fixed32Size + newSize
    let nowDicCount = self.indexCount
    let laterDicCount = max(1, nowDicCount + 1)
    let avgItemSize = lenNeeded / laterDicCount + (lenNeeded % laterDicCount != 0 ? 1 : 0)
    let futureItemCount = max(8, laterDicCount / 2)
    var futureUsage = 0
    if avgItemSize <= (maxSize - lenNeeded) / futureItemCount {
      futureUsage = avgItemSize * futureItemCount
    }
    let expectedUsage = lenNeeded + futureUsage
    // Double the file when the rewrite would not fit, or would leave too little room.
    if lenNeeded >= fileSize || (needSync && expectedUsage >= fileSize) {
      repeat {
        if fileSize > maxSize / 2 {
          fileSize = max(fileSize, lenNeeded)
          break
        }
        fileSize *= 2
      } while expectedUsage >= fileSize
      guard self.file.truncate(to: fileSize), self.checkFileValid() else { return false }
    }
    return self.doFullWriteBack(prepared, needSync: needSync)
  }

  // MARK: - Full write-back

  /// Rewrites the file with only each key's latest record (`fullWriteback`).
  ///
  /// - Parameters:
  ///   - encryption: The cryptor to encrypt the rewritten data with.
  ///   - onlyWhileExpire: Whether to rewrite only if some keys had expired.
  @discardableResult
  mutating func fullWriteback(
    encryption: WriteBackEncryption = .current,
    onlyWhileExpire: Bool = false
  ) -> Bool {
    if self.hasFullWriteback || self.needLoadFromFile {
      return true
    }
    guard self.checkFileValid(), self.checkWritable() else { return false }
    if self.enableKeyExpire {
      let expiredCount = self.filterExpiredKeys()
      if onlyWhileExpire && expiredCount == 0 {
        return true
      }
    }
    if self.indexCount == 0 {
      self.clearAll()
      return true
    }
    self.exclusiveProcessLock.lock()
    defer { self.exclusiveProcessLock.unlock() }
    let prepared = self.prepareEncode()
    let sizeOfDic = prepared.totalSize
    guard sizeOfDic > 0 else { return false }
    let fileSize = self.file.size
    if sizeOfDic + fixed32Size <= fileSize {
      return self.doFullWriteBack(prepared, encryption: encryption)
    }
    // expandAndWriteBack() grows the file and rewrites it in one go.
    return self.expandAndWriteBack(sizeOfDic + fixed32Size - fileSize, prepared)
  }

  mutating func doFullWriteBack(
    _ prepared: PreparedData,
    encryption: WriteBackEncryption = .current,
    needSync: Bool = true
  ) -> Bool {
    let totalSize = prepared.totalSize
    var encrypter: AESCryptor?
    switch encryption {
    case .current: encrypter = self.crypter
    case .plain: encrypter = nil
    case .new(let crypter): encrypter = crypter
    }
    let newIV = encrypter != nil ? AESCryptor.randomIV() : nil
    encrypter?.resetIV(newIV)
    self.output = OutputState(position: 0, size: self.file.size - fixed32Size)
    if let decrypter = self.crypter {
      self.memmoveCryptDictionary(decrypter: decrypter, encrypter: &encrypter, prepared: prepared)
    } else if let encoded = prepared.encoded, !encoded.isEmpty {
      self.fullWriteBackWholeData(encoded, totalSize: totalSize)
      if encrypter != nil {
        let data = self.file.memory! + fixed32Size
        encrypter!.encrypt(data, data, count: totalSize)
      }
    } else {
      self.memmoveDictionary(totalSize: totalSize, encrypter: &encrypter)
    }
    if case .current = encryption {
      // The store goes on appending to the stream the rewrite ended.
      self.crypter = encrypter
    }
    self.actualSize = totalSize
    self.recalculateCRCDigestWithIV(newIV)
    self.hasFullWriteback = true
    // Make sure the last confirmed size and checksum reach the disk.
    if needSync {
      self.sync()
    }
    return true
  }

  /// Rewrites the data from the records already in the file, moving them towards the start in the
  /// order they are in (`memmoveDictionary`).
  private mutating func memmoveDictionary(totalSize: Int, encrypter: inout AESCryptor?) {
    let base = self.file.memory! + fixed32Size
    let originPosition = self.output!.position
    var writePosition = originPosition + itemSizeHolderSize
    if !self.dic.isEmpty {
      let sorted = self.dic.slotsInRecordOrder()
      // Merge neighbouring records so they move together.
      var sectionStart = -1
      var sectionSize = 0
      func moveSection() {
        guard sectionSize > 0 else { return }
        // The ranges can overlap, as they do in place.
        memmove(base + writePosition, base + sectionStart, sectionSize)
        writePosition += sectionSize
      }
      for slot in sorted {
        let location = self.dic.location(at: slot)
        if Int(location.offset) == sectionStart + sectionSize {
          sectionSize += location.size
        } else {
          moveSection()
          sectionStart = Int(location.offset)
          sectionSize = location.size
        }
      }
      moveSection()
      // Encrypting plain text invalidates the index, which is loaded again afterwards.
      if encrypter == nil {
        var offset = itemSizeHolderSize
        for slot in sorted {
          var location = self.dic.location(at: slot)
          location.offset = UInt32(offset)
          offset += location.size
          self.dic.setLocation(location, at: slot)
        }
      }
    }
    // The placeholder where a container's size would be.
    try? self.withOutput { (output) throws(CodingError) in
      try output.writeUInt32(Self.randomItemSizeHolder())
    }
    let writtenSize = writePosition - originPosition
    encrypter?.encrypt(base + originPosition, base + originPosition, count: writtenSize)
    self.output!.position += writtenSize - itemSizeHolderSize
  }

  /// Rewrites the data from an encoded container (`fullWriteBackWholeData`).
  private mutating func fullWriteBackWholeData(_ allData: [UInt8], totalSize: Int) {
    try? self.withOutput { (output) throws(CodingError) in
      try output.writeUInt32(Self.randomItemSizeHolder())
      var failure: CodingError?
      allData.withUnsafeBytes { buffer in
        do throws(CodingError) {
          var input = CodedInput(buffer)
          let dataSize = Int(try input.readUInt32())
          if dataSize > 0 {
            let start = pbRawVarint32Size(UInt32(dataSize))
            try output.writeRawData(
              UnsafeRawBufferPointer(rebasing: buffer[start..<(start + dataSize)])
            )
          }
        } catch {
          failure = error
        }
      }
      if let failure { throw failure }
    }
  }

  /// Rewrites the file from an encoded list of keys and values, then forgets the index so the
  /// next operation loads the result (`doFullWriteBack(MMKVVector)`).
  mutating func doFullWriteBack(_ records: [(key: StoreKey, value: [UInt8])]) -> Bool {
    let prepared = self.prepareEncode(records)
    // The index must be emptied before the rewrite and after encoding.
    self.dic.removeAll()
    self.dicCrypt.removeAll()
    let didWriteBack =
      prepared.totalSize + fixed32Size <= self.file.size
      ? self.doFullWriteBack(prepared) : self.expandAndWriteBack(0, prepared)
    self.clearMemoryCache()
    return didWriteBack
  }

  // MARK: - Metadata

  /// Records the data's size and checksum, increasing the sequence after a full rewrite so other
  /// processes load everything again (`writeActualSize`).
  @discardableResult
  mutating func writeActualSize(
    _ size: Int,
    crcDigest: UInt32,
    iv: [UInt8]?,
    increaseSequence: Bool
  ) -> Bool {
    if self.isReadOnly {
      return false
    }
    if !increaseSequence && self.metaInfo.version < MetaInfo.Version.actualSize {
      self.oldStyleWriteActualSize(size)
    }
    guard self.metaFile.isFileValid else { return false }
    var needsFullWrite = false
    self.actualSize = size
    self.metaInfo.actualSize = UInt32(truncatingIfNeeded: size)
    self.crcDigest = crcDigest
    self.metaInfo.crcDigest = crcDigest
    if self.metaInfo.version < MetaInfo.Version.sequence {
      self.metaInfo.version = MetaInfo.Version.sequence
      needsFullWrite = true
    }
    if let iv {
      self.metaInfo.vector = iv
      if self.metaInfo.version < MetaInfo.Version.randomIV {
        self.metaInfo.version = MetaInfo.Version.randomIV
      }
      needsFullWrite = true
    }
    if increaseSequence {
      self.metaInfo.sequence &+= 1
      self.metaInfo.lastActualSize = UInt32(truncatingIfNeeded: size)
      self.metaInfo.lastCRCDigest = crcDigest
      if self.metaInfo.version < MetaInfo.Version.actualSize {
        self.metaInfo.version = MetaInfo.Version.actualSize
      }
      needsFullWrite = true
    }
    if self.metaInfo.version < MetaInfo.Version.flag {
      self.metaInfo.flags = 0
      self.metaInfo.version = MetaInfo.Version.flag
      needsFullWrite = true
    }
    if needsFullWrite {
      self.metaInfo.write(to: self.metaFile.memory!)
    } else {
      self.metaInfo.writeCRCAndActualSize(to: self.metaFile.memory!)
    }
    return true
  }

  /// Writes the size into the data file's header, where versions before 3 keep it.
  mutating func oldStyleWriteActualSize(_ size: Int) {
    self.actualSize = size
    self.file.memory!.storeBytes(of: UInt32(truncatingIfNeeded: size).littleEndian, as: UInt32.self)
  }

  mutating func recalculateCRCDigestWithIV(_ iv: [UInt8]?) {
    self.recalculateCRCDigest(iv: iv, increaseSequence: true)
  }

  mutating func recalculateCRCDigestOnly() {
    self.recalculateCRCDigest(iv: nil, increaseSequence: false)
  }

  /// Computes the checksum of the whole data, then records it with the size.
  private mutating func recalculateCRCDigest(iv: [UInt8]?, increaseSequence: Bool) {
    guard let memory = self.file.memory else { return }
    self.crcDigest = CRC32.checksum(
      0,
      UnsafeRawBufferPointer(start: memory + fixed32Size, count: self.actualSize)
    )
    self.writeActualSize(
      self.actualSize,
      crcDigest: self.crcDigest,
      iv: iv,
      increaseSequence: increaseSequence
    )
  }

  mutating func updateCRCDigest(_ bytes: UnsafeRawBufferPointer) {
    self.crcDigest = CRC32.checksum(self.crcDigest, bytes)
    self.writeActualSize(
      self.actualSize,
      crcDigest: self.crcDigest,
      iv: nil,
      increaseSequence: false
    )
  }

  // MARK: - Trimming and clearing

  /// Compacts the file and shrinks it by halves while it is more than twice its data, but not below
  /// the expected capacity (`trim`).
  mutating func trim() {
    guard self.checkWritable() else { return }
    self.lockProcess(.exclusive)
    defer { self.unlockProcess(.exclusive) }
    self.checkLoadData(checkingFileSize: true)
    guard self.checkFileValid() else { return }
    if self.actualSize == 0 {
      self.clearAll()
      return
    } else if self.file.size <= self.expectedCapacity {
      return
    }
    guard self.fullWriteback() else { return }
    let oldSize = self.file.size
    var fileSize = oldSize
    while fileSize > (self.actualSize + fixed32Size) * 2 {
      fileSize /= 2
    }
    fileSize = max(fileSize, self.expectedCapacity)
    if oldSize == fileSize {
      return
    }
    guard self.file.truncate(to: fileSize) else { return }
    self.output = OutputState(position: self.actualSize, size: self.file.size - fixed32Size)
    // Unlike the C++ core, a shared store starts a new sequence whenever it shrinks. The write-back
    // above starts one only if it ran. When the records were already written back, another
    // instance with the file open would keep its larger mapping and crash appending past the new
    // end of the file.
    if self.isMultiProcess {
      self.writeActualSize(
        self.actualSize,
        crcDigest: self.crcDigest,
        iv: nil,
        increaseSequence: true
      )
      self.metaFile.msync(synchronously: true)
    }
  }

  /// Removes every key, shrinking the file back to the expected capacity unless `keepSpace`
  /// (`clearAll`).
  mutating func clearAll(keepSpace: Bool = false) {
    guard self.checkWritable() else { return }
    self.lockProcess(.exclusive)
    defer { self.unlockProcess(.exclusive) }
    self.checkLoadData(checkingFileSize: true)
    guard self.checkFileValid() else { return }
    if self.file.size == self.expectedCapacity && self.actualSize == 0 {
      return
    }
    // An encrypted store starts a new stream.
    let newIV = self.crypter != nil ? AESCryptor.randomIV() : nil
    if !keepSpace {
      self.file.truncate(to: self.expectedCapacity)
    }
    self.crypter?.resetIV(newIV)
    self.writeActualSize(0, crcDigest: 0, iv: newIV, increaseSequence: true)
    self.metaFile.msync(synchronously: true)
    self.clearMemoryCache(keepSpace: keepSpace)
    self.loadFromFile()
  }
}
