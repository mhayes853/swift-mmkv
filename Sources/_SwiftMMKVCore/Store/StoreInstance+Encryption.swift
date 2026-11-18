// Encrypted stores, from MMKV's KeyValueHolderCrypt, CodedInputDataCrypt, the encrypted branches
// of MMKV_IO.cpp, and reKey.
//
// An encrypted store's data is one AES-CFB-128 stream that starts at the start of the data, from
// the IV in the metadata. Values of up to 256 bytes are kept decrypted in memory. Larger ones stay
// in the file, and the index remembers the stream's state where their record starts so they can be
// decrypted when read.

/// A large encrypted value left in the file.
struct CryptRecord: Equatable {
  var offset: UInt32
  var keySize: UInt16
  var valueSize: UInt32
  /// The size of the key's and the value's length prefixes.
  var pbKeyValueSize: UInt8
  /// The stream's state where the record starts.
  var state: CipherState

  init(
    offset: UInt32,
    keySize: UInt16,
    valueSize: UInt32,
    pbKeyValueSize: UInt8,
    state: CipherState
  ) {
    self.offset = offset
    self.keySize = keySize
    self.valueSize = valueSize
    self.pbKeyValueSize = pbKeyValueSize
    self.state = state
  }

  init(keySize: Int, valueSize: Int, offset: Int, state: CipherState) {
    self.keySize = UInt16(truncatingIfNeeded: keySize)
    self.valueSize = UInt32(truncatingIfNeeded: valueSize)
    self.offset = UInt32(truncatingIfNeeded: offset)
    self.pbKeyValueSize = UInt8(
      truncatingIfNeeded: pbRawVarint32Size(UInt32(self.valueSize))
        + pbRawVarint32Size(UInt32(self.keySize))
    )
    self.state = state
  }

  var size: Int {
    Int(self.pbKeyValueSize) + Int(self.keySize) + Int(self.valueSize)
  }
}

/// A value's bytes: either in the mapped file, valid until it is next written, or decrypted.
enum RawValue {
  case mapped(UnsafeRawBufferPointer)
  case owned([UInt8])

  static var empty: RawValue {
    .mapped(UnsafeRawBufferPointer(start: nil, count: 0))
  }

  var count: Int {
    switch self {
    case .mapped(let buffer): buffer.count
    case .owned(let bytes): bytes.count
    }
  }

  var array: [UInt8] {
    switch self {
    case .mapped(let buffer): Array(buffer)
    case .owned(let bytes): bytes
    }
  }

  func prefix(_ length: Int) -> RawValue {
    switch self {
    case .mapped(let buffer): .mapped(UnsafeRawBufferPointer(rebasing: buffer[..<length]))
    case .owned(let bytes): .owned(Array(bytes[..<length]))
    }
  }

  func withBytes<R, E: Error>(_ body: (UnsafeRawBufferPointer) throws(E) -> R) throws(E) -> R {
    switch self {
    case .mapped(let buffer):
      return try body(buffer)
    case .owned(let bytes):
      return
        try bytes.withUnsafeBytes { buffer in
          Result { () throws(E) -> R in try body(buffer) }
        }
        .get()
    }
  }
}

/// Which cryptor a full write-back encrypts with.
enum WriteBackEncryption {
  /// The store's own, with a new random IV.
  case current
  /// None: the data is written in plain text.
  case plain
  /// A new key's, with a new random IV.
  case new(AESCryptor)
}

extension StoreInstance {
  // MARK: - Reading

  /// The decrypted bytes of an entry (`KeyValueHolderCrypt::toMMBuffer`). A value kept in memory
  /// is read where the index keeps it, so it is valid until the index next changes.
  func value(of entry: CryptEntry) -> RawValue {
    switch entry {
    case .memory(let value, _):
      return .mapped(value)
    case .offset(let record):
      guard let memory = self.file.memory, let crypter = self.crypter else { return .empty }
      var decrypter = crypter.cloned(at: record.state)
      let start = memory + fixed32Size + Int(record.offset)
      let position = Int(record.pbKeyValueSize) + Int(record.keySize)
      // The key and the lengths come first in the stream, and are decrypted only to reach the value.
      withUnsafeTemporaryAllocation(byteCount: position, alignment: 1) { skipped in
        decrypter.decrypt(start, skipped.baseAddress!, count: position)
      }
      var value = [UInt8](repeating: 0, count: Int(record.valueSize))
      value.withUnsafeMutableBytes {
        decrypter.decrypt(start + position, $0.baseAddress!, count: Int(record.valueSize))
      }
      return .owned(value)
    }
  }

  // MARK: - Decoding

  /// Decrypts the data from `position` to `size`, advancing the store's cryptor to the end, and
  /// decodes its records into ``dicCrypt`` (`decodeOneMap(MMKVMapCrypt&)`).
  ///
  /// The data is decrypted a window at a time as its records are read, as the C++ core's
  /// `CodedInputDataCrypt` does, rather than all at once into memory of its own.
  ///
  /// - Parameter greedy: Whether to keep what was decoded before an error.
  /// - Returns: Whether everything decoded.
  @discardableResult
  func decodeCrypt(from position: Int, size: Int, greedy: Bool) -> Bool {
    guard let memory = self.file.memory, let crypter = self.crypter else { return false }
    let ciphertext = UnsafeRawBufferPointer(start: memory + fixed32Size, count: size)
    var reader = DecryptingReader(ciphertext: ciphertext, position: position, decrypter: crypter)
    let succeeded: Bool
    if greedy {
      succeeded = Self.decodeCryptRecords(&reader, into: &self.dicCrypt)
    } else {
      var decoded = CryptIndex()
      succeeded = Self.decodeCryptRecords(&reader, into: &decoded)
      if succeeded {
        self.dicCrypt = decoded
      }
    }
    self.dicCrypt.shrinkArenaToFit()
    // The store goes on appending where the data ends, whether or not all of it decoded.
    self.crypter = reader.decrypterAtEnd()
    return succeeded
  }

  private static func decodeCryptRecords(
    _ reader: inout DecryptingReader,
    into index: inout CryptIndex
  ) -> Bool {
    if index.isEmpty {
      // No key or value takes more of the arena than of the data, so the arena never grows, and
      // leaves behind the memory of every smaller one, while decoding.
      index.reserveArena(reader.remaining)
    }
    do throws(CodingError) {
      if reader.position == 0 {
        _ = try reader.readUInt32()
      }
      while !reader.isAtEnd {
        let offset = reader.position
        let keyRange = try reader.readLengthDelimited()
        guard keyRange.count <= keySizeLimit else { throw .entryTooLarge }
        guard !keyRange.isEmpty else { continue }
        // Decrypting the key decrypts enough after it for the value's length and a value kept in
        // memory, so that the key stays in the window while they are read.
        reader.decrypt(keyRange, reservingAfter: 10 + 256)
        let valueRange = try reader.readLengthDelimited()
        let key = reader.bytes(in: keyRange)
        if CryptEntry.isValueStoredAsOffset(valueRange.count) {
          let record = CryptRecord(
            keySize: keyRange.count,
            valueSize: valueRange.count,
            offset: offset,
            state: reader.state(atOffset: offset)
          )
          index.setRecord(record, for: key)
        } else if valueRange.isEmpty {
          index.remove(key)
        } else {
          reader.decrypt(valueRange, reservingAfter: 0)
          index.setValue(reader.bytes(in: valueRange), order: UInt32(offset), for: key)
        }
      }
      return true
    } catch {
      Log.error("\(error)")
      return false
    }
  }

  // MARK: - Writing

  /// Writes `data` as `key`'s value in an encrypted store (the encrypted branch of
  /// `setDataForKey`).
  func setCryptDataForKey(
    _ data: UnsafeRawBufferPointer,
    _ key: UnsafeRawBufferPointer,
    isDataHolder: Bool
  ) -> Bool {
    if isDataHolder {
      // A small string or byte value is kept with its length, as it is stored.
      let sizeNeededForData = pbRawVarint32Size(UInt32(data.count)) + data.count
      if !CryptEntry.isValueStoredAsOffset(sizeNeededForData) {
        return withUnsafeTemporaryAllocation(byteCount: sizeNeededForData, alignment: 1) { buffer in
          var output = CodedOutput(buffer)
          try? output.writeData(data)
          return self.appendCryptData(UnsafeRawBufferPointer(buffer), key, isDataHolder: false)
        }
      }
    }
    return self.appendCryptData(data, key, isDataHolder: isDataHolder)
  }

  private func appendCryptData(
    _ data: UnsafeRawBufferPointer,
    _ key: UnsafeRawBufferPointer,
    isDataHolder: Bool
  ) -> Bool {
    // An encrypted store always appends, because rewriting in place would reuse the IV.
    self.appendState = nil
    guard let location = self.appendDataWithKey(data, key: key, isDataHolder: isDataHolder) else {
      return false
    }
    if CryptEntry.isValueStoredAsOffset(Int(location.valueSize)), let state = self.appendState {
      let record = CryptRecord(
        keySize: Int(location.keySize),
        valueSize: Int(location.valueSize),
        offset: Int(location.offset),
        state: state
      )
      self.dicCrypt.setRecord(record, for: key)
    } else {
      self.dicCrypt.setValue(data, order: location.offset, for: key)
    }
    return true
  }

  // MARK: - Full write-back

  /// The records to rewrite in an encrypted store (`prepareEncode(MMKVMapCrypt)`): the large ones
  /// move within the file, and the ones in memory are encoded after them.
  ///
  /// The C++ core encodes the ones in memory in the order of its hash table, and this in the
  /// order their records were in, so after a rewrite the two cores' files differ in order as well
  /// as in their random IV.
  func prepareEncodeCrypt() -> PreparedData {
    var totalSize = 0
    var smallestOffset = 5 + 1
    var hasValuesInMemory = false
    self.dicCrypt.forEachEntry { _, entry in
      switch entry {
      case .offset(let record):
        totalSize += record.size
        smallestOffset = min(smallestOffset, Int(record.offset))
      case .memory:
        hasValuesInMemory = true
      }
    }
    if smallestOffset > 5 {
      smallestOffset = itemSizeHolderSize
    }
    totalSize += smallestOffset
    let order = self.dicCrypt.slotsInRecordOrder()
    let cryptOrder = (slots: order, version: self.dicCrypt.version)
    guard hasValuesInMemory else {
      return PreparedData(encoded: nil, totalSize: totalSize, cryptOrder: cryptOrder)
    }
    // Encoded as a container, as `prepareEncode(MMKVVector)` encodes them.
    var containerSize = 0
    for slot in order {
      guard case .memory(let value, _) = self.dicCrypt.entry(at: slot) else { continue }
      let keySize = self.dicCrypt.key(at: slot).count
      containerSize += pbRawVarint32Size(UInt32(keySize)) + keySize
      containerSize += pbRawVarint32Size(UInt32(value.count)) + value.count
    }
    var encoded = [UInt8](
      repeating: 0,
      count: pbRawVarint32Size(UInt32(containerSize)) + containerSize
    )
    encoded.withUnsafeMutableBytes { buffer in
      var output = CodedOutput(buffer)
      try? output.writeUInt32(UInt32(containerSize))
      for slot in order {
        guard case .memory(let value, _) = self.dicCrypt.entry(at: slot) else { continue }
        try? output.writeData(self.dicCrypt.key(at: slot))
        try? output.writeData(value)
      }
    }
    return PreparedData(
      encoded: encoded,
      totalSize: totalSize + containerSize,
      cryptOrder: cryptOrder
    )
  }

  /// Rewrites an encrypted store's data (the encrypted `memmoveDictionary`): the placeholder, then
  /// the large records moved and re-encrypted, then the encoded records from memory.
  func memmoveCryptDictionary(
    decrypter: AESCryptor,
    encrypter: inout AESCryptor?,
    prepared: PreparedData
  ) {
    let base = self.file.memory! + fixed32Size
    var records = [(slot: Int, record: CryptRecord)]()
    let order =
      prepared.cryptOrder.flatMap { $0.version == self.dicCrypt.version ? $0.slots : nil }
      ?? self.dicCrypt.slotsInRecordOrder()
    for slot in order {
      if case .offset(let record) = self.dicCrypt.entry(at: slot) {
        records.append((slot, record))
      }
    }

    var sizeHolderSize = itemSizeHolderSize
    var sizeHolder = Self.randomItemSizeHolder(size: sizeHolderSize)
    if let smallestOffset = records.first.map({ Int($0.record.offset) }),
      smallestOffset != itemSizeHolderSize && smallestOffset <= 5
    {
      sizeHolderSize = smallestOffset
      sizeHolder = Self.randomItemSizeHolder(size: sizeHolderSize)
    }
    try? self.withOutput { (output) throws(CodingError) in
      try output.writeRawVarint32(sizeHolder)
    }
    var writePosition = self.output!.position
    if encrypter != nil {
      let start = base + writePosition - sizeHolderSize
      encrypter!.encrypt(start, start, count: sizeHolderSize)
    }
    if !records.isEmpty {
      // Merge neighbouring records so they move together.
      var sections = [(offset: Int, size: Int, state: CipherState)]()
      for (_, record) in records {
        if let last = sections.last, Int(record.offset) == last.offset + last.size {
          sections[sections.count - 1].size += record.size
        } else {
          sections.append((Int(record.offset), record.size, record.state))
        }
      }
      for section in sections {
        var crypter = decrypter.cloned(at: section.state)
        crypter.decrypt(base + section.offset, base + writePosition, count: section.size)
        writePosition += section.size
      }
      if encrypter != nil {
        var offset = sizeHolderSize
        for (slot, record) in records {
          var moved = record
          moved.offset = UInt32(offset)
          moved.state = encrypter!.state
          encrypter!.encrypt(base + offset, base + offset, count: record.size)
          self.dicCrypt.setRecord(moved, at: slot)
          offset += record.size
        }
      }
    }
    if let encoded = prepared.encoded, !encoded.isEmpty {
      encoded.withUnsafeBytes { buffer in
        var input = CodedInput(buffer)
        guard let dataSize = try? Int(input.readUInt32()), dataSize > 0 else { return }
        let source = buffer.baseAddress! + pbRawVarint32Size(UInt32(dataSize))
        if encrypter != nil {
          encrypter!.encrypt(source, base + writePosition, count: dataSize)
        } else {
          (base + writePosition).copyMemory(from: source, byteCount: dataSize)
        }
        writePosition += dataSize
      }
    }
    self.output!.position = writePosition
  }

  /// A random varint value that takes exactly `size` bytes, from 1 to 5
  /// (`AESCrypt::randomItemSizeHolder`).
  static func randomItemSizeHolder(size: Int) -> UInt32 {
    let holders: [UInt64] = [0, 0x80, 0x4000, 0x20_0000, 0x1000_0000, 0x1_0000_0000]
    return UInt32(UInt64.random(in: holders[size - 1]..<holders[size]))
  }

  // MARK: - Re-encrypting

  /// Re-encrypts the store with `key`, or decrypts it when `key` is `nil` (`reKey`).
  package func rekey(key: [UInt8]?, isAES256: Bool) -> Bool {
    if self.isReadOnly {
      Log.warning("[\(self.id)] file readonly")
      return false
    }
    return self.withLocks(.exclusive) {
      self.checkLoadData()
      guard self.isFileValid else {
        Log.warning("[\(self.id)] file not valid")
        return false
      }
      let didRekey: Bool
      if let crypter = self.crypter {
        if let key, !key.isEmpty {
          if key == crypter.keyUpToFirstZero && crypter.isAES256 == isAES256 {
            return true
          }
          // A new key.
          let newCrypter = AESCryptor(key: key, isAES256: isAES256)
          self.hasFullWriteback = false
          didRekey = self.fullWriteback(encryption: .new(newCrypter))
          if didRekey {
            self.crypter = newCrypter
          }
        } else {
          // Decrypting to plain text, which needs every pair to fit the plain index.
          var fitsPlainIndex = true
          self.dicCrypt.forEachEntry { slot, entry in
            let keySize = self.dicCrypt.key(at: slot).count
            fitsPlainIndex =
              fitsPlainIndex
              && Self.encodedEntrySize(
                keyDataLength: keySize,
                originKeyLength: keySize,
                dataLength: entry.realValueSize,
                isDataHolder: false,
                needsPlainHolder: true
              ) != nil
          }
          guard fitsPlainIndex else {
            Log.error("[\(self.id)] reject decryption: key/value cannot fit a plain holder")
            return false
          }
          self.hasFullWriteback = false
          didRekey = self.fullWriteback(encryption: .plain)
          if didRekey {
            self.crypter = nil
          }
        }
      } else {
        guard let key, !key.isEmpty else { return true }
        // Encrypting plain text.
        self.hasFullWriteback = false
        let newCrypter = AESCryptor(key: key, isAES256: isAES256)
        didRekey = self.fullWriteback(encryption: .new(newCrypter))
        if didRekey {
          self.crypter = newCrypter
        }
      }
      // The index is not valid after re-encrypting.
      if didRekey {
        self.clearMemoryCache()
      }
      return didRekey
    }
  }
}

/// Decrypts an encrypted store's data a window at a time as its records are read, with the
/// semantics of a ``CodedInput`` over the whole decrypted data.
///
/// The window holds at most 128 KiB, which is enough for the longest key and a value kept in
/// memory. Ranges that are skipped, such as large values left in the file, are not decrypted:
/// the stream's state after them is computed from the ciphertext.
struct DecryptingReader: ~Copyable {
  /// The data from its start.
  let ciphertext: UnsafeRawBufferPointer
  /// The cryptor at ``windowEnd``.
  private var decrypter: AESCryptor
  private let window: UnsafeMutableRawPointer
  private let windowCapacity: Int
  /// Where in the data the window starts and where its decrypted bytes end.
  private var windowStart: Int
  private var windowEnd: Int
  private(set) var position: Int

  private static let maximumWindow = 1 << 17

  /// A reader from `position`, where `decrypter` is.
  init(ciphertext: UnsafeRawBufferPointer, position: Int, decrypter: AESCryptor) {
    self.ciphertext = ciphertext
    self.decrypter = decrypter
    self.windowCapacity = max(1, min(ciphertext.count - position, Self.maximumWindow))
    self.window = .allocate(byteCount: self.windowCapacity, alignment: 1)
    self.windowStart = position
    self.windowEnd = position
    self.position = position
  }

  deinit {
    self.window.deallocate()
  }

  var isAtEnd: Bool {
    self.position == self.ciphertext.count
  }

  var remaining: Int {
    self.ciphertext.count - self.position
  }

  /// The stream's state after `offset` bytes.
  func state(atOffset offset: Int) -> CipherState {
    self.decrypter.state(atOffset: offset, in: self.ciphertext)
  }

  /// The cryptor at the end of the data.
  consuming func decrypterAtEnd() -> AESCryptor {
    let size = self.ciphertext.count
    if self.windowEnd == size {
      return self.decrypter
    }
    return self.decrypter.cloned(at: self.state(atOffset: size))
  }

  /// Reads a varint as ``CodedInput/readUInt32()`` does.
  mutating func readUInt32() throws(CodingError) -> UInt32 {
    // A varint takes at most ten bytes.
    self.decrypt(from: self.position, to: self.position + 10)
    var input = CodedInput(
      base: self.window,
      size: self.windowEnd - self.windowStart,
      position: self.position - self.windowStart
    )
    defer { self.position = self.windowStart + input.position }
    return try input.readUInt32()
  }

  /// Reads a length and skips that many bytes, as ``CodedInput/readLengthDelimited(exactly:)``
  /// does, without decrypting them.
  mutating func readLengthDelimited() throws(CodingError) -> Range<Int> {
    let length = Int(try self.readUInt32())
    guard length <= self.ciphertext.count - self.position else { throw .invalidLength }
    let start = self.position
    self.position += length
    return start..<self.position
  }

  /// Decrypts `range` into the window, and up to `reservingAfter` bytes after it.
  mutating func decrypt(_ range: Range<Int>, reservingAfter: Int) {
    self.decrypt(from: range.lowerBound, to: range.upperBound + reservingAfter)
  }

  /// The decrypted bytes in `range`, which ``decrypt(_:reservingAfter:)`` put in the window.
  func bytes(in range: Range<Int>) -> UnsafeRawBufferPointer {
    precondition(range.lowerBound >= self.windowStart && range.upperBound <= self.windowEnd)
    return UnsafeRawBufferPointer(
      start: self.window + (range.lowerBound - self.windowStart),
      count: range.count
    )
  }

  /// Makes sure the window holds the decrypted bytes from `start` to `end`, or to the end of the
  /// data.
  private mutating func decrypt(from start: Int, to end: Int) {
    let end = min(end, self.ciphertext.count)
    guard end > self.windowEnd else { return }
    if self.windowEnd < start {
      // Skip what was not read, computing the state after it from the ciphertext.
      self.decrypter = self.decrypter.cloned(at: self.state(atOffset: start))
      self.windowStart = start
      self.windowEnd = start
    }
    if end - self.windowStart > self.windowCapacity {
      // Keep what is still to be read, and make room after it.
      let kept = self.windowEnd - start
      memmove(self.window, self.window + (start - self.windowStart), kept)
      self.windowStart = start
    }
    let target = min(self.ciphertext.count, self.windowStart + self.windowCapacity)
    self.decrypter.decrypt(
      self.ciphertext.baseAddress! + self.windowEnd,
      self.window + (self.windowEnd - self.windowStart),
      count: target - self.windowEnd
    )
    self.windowEnd = target
  }
}
