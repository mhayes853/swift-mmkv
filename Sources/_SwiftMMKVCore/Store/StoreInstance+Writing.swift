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
}

extension StoreInstance {
  // MARK: - Reading values

  /// The bytes of `key`'s value, including any expiry time, or no bytes (`getRawDataForKey`).
  func getRawDataForKey(_ key: StoreKey) -> RawValue {
    if self.crypter != nil {
      guard let entry = self.dicCrypt[key] else { return .empty }
      return self.value(of: entry)
    }
    guard let location = self.dic[key], let memory = self.file.memory else {
      return .empty
    }
    return .mapped(
      UnsafeRawBufferPointer(
        start: memory + fixed32Size + location.valueOffset,
        count: Int(location.valueSize)
      )
    )
  }

  /// The bytes of `key`'s value without its expiry time, after loading any changes
  /// (`getDataForKey`).
  func getDataForKey(_ key: StoreKey) -> RawValue {
    self.checkLoadData()
    if self.enableKeyExpire {
      return self.getDataWithoutMTimeForKey(key)
    }
    return self.getRawDataForKey(key)
  }

  // MARK: - Writing values

  /// Writes `data` as `key`'s value (`setDataForKey(data, key, isDataHolder)`). A data holder is a
  /// string or raw bytes, whose length is written before them inside the value.
  func setDataForKey(_ data: UnsafeRawBufferPointer, _ key: StoreKey, isDataHolder: Bool) -> Bool {
    if (!isDataHolder && data.isEmpty) || key.bytes.isEmpty {
      return false
    }
    guard Self.encodedValueLength(data.count, isDataHolder: isDataHolder) != nil else {
      Log.error("[\(self.id)] reject value too large to encode: \(data.count)")
      return false
    }
    if self.crypter != nil {
      guard self.setCryptDataForKey(data, key, isDataHolder: isDataHolder) else { return false }
      self.hasFullWriteback = false
      return true
    }
    if let existing = self.dic[key] {
      if self.isCompareBeforeSetEnabled, let memory = self.file.memory {
        let old = UnsafeRawBufferPointer(
          start: memory + fixed32Size + existing.valueOffset,
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
      let location: RecordLocation?
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
      guard let location else { return false }
      self.dic[key] = location
    } else {
      let needOverride = !self.isMultiProcess && self.dic.isEmpty && self.actualSize > 0
      let location =
        needOverride
        ? self.overrideDataWithKey(data, key: key, isDataHolder: isDataHolder)
        : self.appendDataWithKey(data, key: key, isDataHolder: isDataHolder)
      guard let location else { return false }
      self.dic[key] = location
    }
    self.hasFullWriteback = false
    return true
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

  /// Appends a record for `key` (`appendDataWithKey(data, key)`).
  func appendDataWithKey(
    _ data: UnsafeRawBufferPointer,
    key: StoreKey,
    isDataHolder: Bool
  ) -> RecordLocation? {
    self.doAppendDataWithKey(
      data,
      keyData: key.bytes,
      isDataHolder: isDataHolder,
      originKeyLength: key.bytes.count
    )
  }

  /// Appends a record for `key`, copying its length-delimited key from its current record
  /// (`appendDataWithKey(data, kvHolder)`).
  func appendDataWithKey(
    _ data: UnsafeRawBufferPointer,
    holderOf key: StoreKey,
    isDataHolder: Bool
  ) -> RecordLocation? {
    self.exclusiveProcessLock.withLock {
      guard let holder = self.dic[key] else { return nil }
      let keyLength = Int(holder.keySize)
      let rawKeySize = keyLength + pbRawVarint32Size(UInt32(keyLength))
      // Making space may move the record, so it is looked up again afterwards.
      guard
        let entry = Self.encodedEntrySize(
          keyDataLength: rawKeySize,
          originKeyLength: keyLength,
          dataLength: data.count,
          isDataHolder: isDataHolder,
          needsPlainHolder: true
        ),
        self.ensureMemorySize(entry.totalSize),
        let moved = self.dic[key], let memory = self.file.memory
      else {
        return nil
      }
      let keyData = Array(
        UnsafeRawBufferPointer(start: memory + fixed32Size + Int(moved.offset), count: rawKeySize)
      )
      return self.doAppendDataWithKey(
        data,
        keyData: keyData,
        isDataHolder: isDataHolder,
        originKeyLength: keyLength
      )
    }
  }

  func doAppendDataWithKey(
    _ data: UnsafeRawBufferPointer,
    keyData: [UInt8],
    isDataHolder: Bool,
    originKeyLength: Int
  ) -> RecordLocation? {
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
        "[\(self.id)] reject unrepresentable key/value lengths, key=\(originKeyLength), value=\(data.count)"
      )
      return nil
    }
    return self.exclusiveProcessLock.withLock {
      guard self.checkSizeLimit(entry.totalSize, keyData: keyData, originKeyLength: originKeyLength)
      else { return nil }
      guard self.ensureMemorySize(entry.totalSize), self.isFileValid else { return nil }
      if let crypter = self.crypter, CryptEntry.isValueStoredAsOffset(entry.valueLength) {
        self.appendState = crypter.state
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
      if self.crypter != nil {
        self.crypter!.encrypt(pointer, pointer, count: entry.totalSize)
      }
      self.actualSize += entry.totalSize
      self.updateCRCDigest(UnsafeRawBufferPointer(start: pointer, count: entry.totalSize))
      return RecordLocation(keySize: originKeyLength, valueSize: entry.valueLength, offset: offset)
    }
  }

  /// Rewrites the data from the start as a single record for `key` (`overrideDataWithKey(data, key)`).
  func overrideDataWithKey(
    _ data: UnsafeRawBufferPointer,
    key: StoreKey,
    isDataHolder: Bool
  ) -> RecordLocation? {
    self.doOverrideDataWithKey(
      data,
      keyData: key.bytes,
      isDataHolder: isDataHolder,
      originKeyLength: key.bytes.count
    )
  }

  /// Rewrites the data from the start as a single record for `key`, copying its length-delimited
  /// key from its current record (`overrideDataWithKey(data, kvHolder)`).
  func overrideDataWithKey(
    _ data: UnsafeRawBufferPointer,
    holderOf key: StoreKey,
    isDataHolder: Bool
  ) -> RecordLocation? {
    guard let holder = self.dic[key] else { return nil }
    let keyLength = Int(holder.keySize)
    let rawKeySize = keyLength + pbRawVarint32Size(UInt32(keyLength))
    guard
      let entry = Self.encodedEntrySize(
        keyDataLength: rawKeySize,
        originKeyLength: keyLength,
        dataLength: data.count,
        isDataHolder: isDataHolder,
        needsPlainHolder: true
      )
    else { return nil }
    if !self.checkSizeForOverride(entry.totalSize) {
      return self.appendDataWithKey(data, holderOf: key, isDataHolder: isDataHolder)
    }
    let keyData = Array(
      UnsafeRawBufferPointer(
        start: self.file.memory! + fixed32Size + Int(holder.offset),
        count: rawKeySize
      )
    )
    return self.doOverrideDataWithKey(
      data,
      keyData: keyData,
      isDataHolder: isDataHolder,
      originKeyLength: keyLength
    )
  }

  func doOverrideDataWithKey(
    _ data: UnsafeRawBufferPointer,
    keyData: [UInt8],
    isDataHolder: Bool,
    originKeyLength: Int
  ) -> RecordLocation? {
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
        "[\(self.id)] reject unrepresentable key/value lengths, key=\(originKeyLength), value=\(data.count)"
      )
      return nil
    }
    guard self.checkSizeLimit(entry.totalSize, keyData: keyData, originKeyLength: originKeyLength)
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
    keyData: [UInt8],
    keyAlreadyEncoded: Bool,
    data: UnsafeRawBufferPointer,
    isDataHolder: Bool,
    valueLength: Int
  ) throws(CodingError) {
    var failure: CodingError?
    keyData.withUnsafeBytes { keyData in
      do throws(CodingError) {
        if keyAlreadyEncoded {
          try output.writeRawData(keyData)
        } else {
          try output.writeData(keyData)
        }
        if isDataHolder {
          try output.writeRawVarint32(UInt32(valueLength))
        }
        try output.writeData(data)
      } catch {
        failure = error
      }
    }
    if let failure { throw failure }
  }

  /// Whether a record of `size` fits in the file without growing it (`checkSizeForOverride`).
  func checkSizeForOverride(_ size: Int) -> Bool {
    guard self.isFileValid else {
      Log.warning("[\(self.id)] file not valid")
      return false
    }
    let fileSize = self.file.size
    let spaceNeededForOverride = size + fixed32Size + itemSizeHolderSize
    return !(size > fileSize || spaceNeededForOverride > fileSize)
  }

  func checkSizeLimit(_ size: Int, keyData: [UInt8], originKeyLength: Int) -> Bool {
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
  func withOutput<R>(_ body: (inout CodedOutput) throws(CodingError) -> R) throws(CodingError) -> R
  {
    guard let state = self.output, let memory = self.file.memory else { throw .outOfSpace }
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
  func ensureMemorySize(_ newSize: Int) -> Bool {
    guard self.isFileValid else {
      Log.warning("[\(self.id)] file not valid")
      return false
    }
    if self.isReadOnly {
      Log.warning("[\(self.id)] file readonly")
      return false
    }
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
    for location in self.dic.values {
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
  func expandAndWriteBack(_ newSize: Int, _ prepared: PreparedData, needSync: Bool = true) -> Bool {
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
      guard self.file.truncate(to: fileSize) else { return false }
      guard self.isFileValid else {
        Log.warning("[\(self.id)] file not valid")
        return false
      }
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
  func fullWriteback(
    encryption: WriteBackEncryption = .current,
    onlyWhileExpire: Bool = false
  ) -> Bool {
    if self.hasFullWriteback || self.needLoadFromFile {
      return true
    }
    guard self.isFileValid else {
      Log.warning("[\(self.id)] file not valid")
      return false
    }
    if self.isReadOnly {
      Log.warning("[\(self.id)] file readonly")
      return false
    }
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
    return self.exclusiveProcessLock.withLock {
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
  }

  func doFullWriteBack(
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
    var newIV: [UInt8]?
    if encrypter != nil {
      newIV = AESCryptor.randomIV()
      encrypter!.resetIV(newIV)
    }
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
  private func memmoveDictionary(totalSize: Int, encrypter: inout AESCryptor?) {
    let base = self.file.memory! + fixed32Size
    let originPosition = self.output!.position
    var writePosition = originPosition + itemSizeHolderSize
    if !self.dic.isEmpty {
      let sorted = self.dic.sorted { $0.value.offset < $1.value.offset }
      // Merge neighbouring records so they move together.
      var sections = [(offset: Int, size: Int)]()
      sections.append((Int(sorted[0].value.offset), sorted[0].value.size))
      for (_, location) in sorted.dropFirst() {
        let last = sections[sections.count - 1]
        if Int(location.offset) == last.offset + last.size {
          sections[sections.count - 1].size += location.size
        } else {
          sections.append((Int(location.offset), location.size))
        }
      }
      for section in sections {
        // The ranges can overlap, as they do in place.
        memmove(base + writePosition, base + section.offset, section.size)
        writePosition += section.size
      }
      // Encrypting plain text invalidates the index, which is loaded again afterwards.
      if encrypter == nil {
        var offset = itemSizeHolderSize
        for (key, location) in sorted {
          self.dic[key]!.offset = UInt32(offset)
          offset += location.size
        }
      }
    }
    // The placeholder where a container's size would be.
    try? self.withOutput { (output) throws(CodingError) in
      try output.writeUInt32(Self.randomItemSizeHolder())
    }
    let writtenSize = writePosition - originPosition
    if encrypter != nil {
      encrypter!.encrypt(base + originPosition, base + originPosition, count: writtenSize)
    }
    self.output!.position += writtenSize - itemSizeHolderSize
  }

  /// Rewrites the data from an encoded container (`fullWriteBackWholeData`).
  private func fullWriteBackWholeData(_ allData: [UInt8], totalSize: Int) {
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
  func doFullWriteBack(_ records: [(key: StoreKey, value: [UInt8])]) -> Bool {
    let prepared = self.prepareEncode(records)
    // The index must be emptied before the rewrite and after encoding.
    self.dic.removeAll()
    self.dicCrypt.removeAll()
    let didWriteBack: Bool
    if prepared.totalSize + fixed32Size <= self.file.size {
      didWriteBack = self.doFullWriteBack(prepared)
    } else {
      didWriteBack = self.expandAndWriteBack(0, prepared)
    }
    self.clearMemoryCache()
    return didWriteBack
  }

  // MARK: - Metadata

  /// Records the data's size and checksum, increasing the sequence after a full rewrite so other
  /// processes load everything again (`writeActualSize`).
  @discardableResult
  func writeActualSize(
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
  func oldStyleWriteActualSize(_ size: Int) {
    self.actualSize = size
    self.file.memory!.storeBytes(of: UInt32(truncatingIfNeeded: size).littleEndian, as: UInt32.self)
  }

  func recalculateCRCDigestWithIV(_ iv: [UInt8]?) {
    guard let memory = self.file.memory else { return }
    self.crcDigest = CRC32.checksum(
      0,
      UnsafeRawBufferPointer(start: memory + fixed32Size, count: self.actualSize)
    )
    self.writeActualSize(self.actualSize, crcDigest: self.crcDigest, iv: iv, increaseSequence: true)
  }

  func recalculateCRCDigestOnly() {
    guard let memory = self.file.memory else { return }
    self.crcDigest = CRC32.checksum(
      0,
      UnsafeRawBufferPointer(start: memory + fixed32Size, count: self.actualSize)
    )
    self.writeActualSize(
      self.actualSize,
      crcDigest: self.crcDigest,
      iv: nil,
      increaseSequence: false
    )
  }

  func updateCRCDigest(_ bytes: UnsafeRawBufferPointer) {
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
  package func trim() {
    if self.isReadOnly {
      Log.warning("[\(self.id)] file readonly")
      return
    }
    self.withLocks(.exclusive) {
      self.checkLoadData()
      guard self.isFileValid else {
        Log.warning("[\(self.id)] file not valid")
        return
      }
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
    }
  }

  /// Removes every key, shrinking the file back to the expected capacity unless `keepSpace`
  /// (`clearAll`).
  package func clearAll(keepSpace: Bool = false) {
    if self.isReadOnly {
      Log.warning("[\(self.id)] file readonly")
      return
    }
    self.withLocks(.exclusive) {
      self.checkLoadData()
      guard self.isFileValid else {
        Log.warning("[\(self.id)] file not valid")
        return
      }
      if self.file.size == self.expectedCapacity && self.actualSize == 0 {
        return
      }
      // An encrypted store starts a new stream.
      let newIV = self.crypter != nil ? AESCryptor.randomIV() : nil
      if !keepSpace {
        self.file.truncate(to: self.expectedCapacity)
      }
      if self.crypter != nil {
        self.crypter!.resetIV(newIV)
      }
      self.writeActualSize(0, crcDigest: 0, iv: newIV, increaseSequence: true)
      self.metaFile.msync(synchronously: true)
      self.clearMemoryCache(keepSpace: keepSpace)
      self.loadFromFile()
    }
  }
}
