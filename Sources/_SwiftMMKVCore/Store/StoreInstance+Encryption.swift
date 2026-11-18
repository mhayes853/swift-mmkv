// Encrypted stores, from MMKV's KeyValueHolderCrypt, CodedInputDataCrypt, the encrypted branches
// of MMKV_IO.cpp, and reKey.
//
// An encrypted store's data is one AES-CFB-128 stream that starts at the start of the data, from
// the IV in the metadata. Values of up to 256 bytes are kept decrypted in memory. Larger ones stay
// in the file, and the index remembers the stream's state where their record starts so they can be
// decrypted when read.

/// An encrypted store's index entry (`KeyValueHolderCrypt`).
enum CryptEntry {
  /// A value of up to 256 bytes, decrypted. `order` is where its record was, which the C++ core
  /// does not keep; the Swift core uses it to write these values back in a stable order.
  case memory(value: [UInt8], order: UInt32)
  /// A larger value, left in the file.
  case offset(CryptRecord)

  var realValueSize: Int {
    switch self {
    case .memory(let value, _): value.count
    case .offset(let record): Int(record.valueSize)
    }
  }

  var order: UInt32 {
    switch self {
    case .memory(_, let order): order
    case .offset(let record): record.offset
    }
  }

  /// Whether a value of `size` bytes stays in the file (`isValueStoredAsOffset`).
  static func isValueStoredAsOffset(_ size: Int) -> Bool {
    size > 256
  }
}

/// A large encrypted value left in the file.
struct CryptRecord {
  var offset: UInt32
  var keySize: UInt16
  var valueSize: UInt32
  /// The size of the key's and the value's length prefixes.
  var pbKeyValueSize: UInt8
  /// The stream's state where the record starts.
  var state: CipherState

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

  /// The decrypted bytes of an entry (`KeyValueHolderCrypt::toMMBuffer`).
  func value(of entry: CryptEntry) -> RawValue {
    switch entry {
    case .memory(let value, _):
      return .owned(value)
    case .offset(let record):
      guard let memory = self.file.memory, let crypter = self.crypter else { return .empty }
      var decrypter = crypter.cloned(at: record.state)
      let start = memory + fixed32Size + Int(record.offset)
      let position = Int(record.pbKeyValueSize) + Int(record.keySize)
      var skipped = [UInt8](repeating: 0, count: position)
      decrypter.decrypt(start, &skipped, count: position)
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
  /// - Parameter greedy: Whether to keep what was decoded before an error.
  /// - Returns: Whether everything decoded.
  @discardableResult
  func decodeCrypt(from position: Int, size: Int, greedy: Bool) -> Bool {
    guard let memory = self.file.memory, var crypter = self.crypter else { return false }
    let ciphertext = UnsafeRawBufferPointer(start: memory + fixed32Size, count: size)
    var plaintext = [UInt8](repeating: 0, count: size)
    plaintext.withUnsafeMutableBytes { output in
      crypter.decrypt(
        ciphertext.baseAddress! + position,
        output.baseAddress! + position,
        count: size - position
      )
    }
    let streamStart = crypter
    self.crypter = crypter

    var decoded = greedy ? self.dicCrypt : [StoreKey: CryptEntry]()
    let succeeded = plaintext.withUnsafeBytes { plaintext in
      var input = CodedInput(plaintext)
      do throws(CodingError) {
        if position != 0 {
          try input.seek(position)
        } else {
          _ = try input.readInt32()
        }
        while !input.isAtEnd {
          let offset = input.position
          let keyRange = try input.readLengthDelimited()
          guard keyRange.count <= keySizeLimit else { throw .entryTooLarge }
          guard !keyRange.isEmpty else { continue }
          let key = StoreKey(Array(input.bytes(in: keyRange)))
          let valueRange = try input.readLengthDelimited()
          let entry: CryptEntry
          if CryptEntry.isValueStoredAsOffset(valueRange.count) {
            entry = .offset(
              CryptRecord(
                keySize: keyRange.count,
                valueSize: valueRange.count,
                offset: offset,
                state: streamStart.state(atOffset: offset, in: ciphertext)
              )
            )
          } else {
            entry = .memory(value: Array(input.bytes(in: valueRange)), order: UInt32(offset))
          }
          if entry.realValueSize > 0 {
            decoded[key] = entry
          } else {
            decoded.removeValue(forKey: key)
          }
        }
        return true
      } catch {
        Log.error("\(error)")
        return false
      }
    }
    if greedy || succeeded {
      self.dicCrypt = decoded
    }
    return succeeded
  }

  // MARK: - Writing

  /// Writes `data` as `key`'s value in an encrypted store (the encrypted branch of
  /// `setDataForKey`).
  func setCryptDataForKey(_ data: UnsafeRawBufferPointer, _ key: StoreKey, isDataHolder: Bool)
    -> Bool
  {
    // A small string or byte value is kept with its length, as it is stored.
    var isDataHolder = isDataHolder
    var holderData: [UInt8]?
    if isDataHolder {
      let sizeNeededForData = pbRawVarint32Size(UInt32(data.count)) + data.count
      if !CryptEntry.isValueStoredAsOffset(sizeNeededForData) {
        var encoded = [UInt8](repeating: 0, count: sizeNeededForData)
        encoded.withUnsafeMutableBytes { buffer in
          var output = CodedOutput(buffer)
          try? output.writeData(data)
        }
        holderData = encoded
        isDataHolder = false
      }
    }
    func write(_ data: UnsafeRawBufferPointer) -> Bool {
      // An encrypted store always appends, because rewriting in place would reuse the IV.
      self.appendState = nil
      let location = key.bytes.withUnsafeBytes { key in
        self.appendDataWithKey(data, key: key, isDataHolder: isDataHolder)
      }
      guard let location else { return false }
      let entry: CryptEntry
      if CryptEntry.isValueStoredAsOffset(Int(location.valueSize)), let state = self.appendState {
        entry = .offset(
          CryptRecord(
            keySize: Int(location.keySize),
            valueSize: Int(location.valueSize),
            offset: Int(location.offset),
            state: state
          )
        )
      } else {
        entry = .memory(value: Array(data), order: location.offset)
      }
      self.dicCrypt[key] = entry
      return true
    }
    if let holderData {
      return holderData.withUnsafeBytes(write)
    }
    return write(data)
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
    var inMemory = [(key: StoreKey, value: [UInt8], order: UInt32)]()
    for (key, entry) in self.dicCrypt {
      switch entry {
      case .offset(let record):
        totalSize += record.size
        smallestOffset = min(smallestOffset, Int(record.offset))
      case .memory(let value, let order):
        inMemory.append((key, value, order))
      }
    }
    if smallestOffset > 5 {
      smallestOffset = itemSizeHolderSize
    }
    totalSize += smallestOffset
    if inMemory.isEmpty {
      return PreparedData(encoded: nil, totalSize: totalSize)
    }
    inMemory.sort { $0.order < $1.order }
    let encoded = self.prepareEncode(inMemory.map { ($0.key, $0.value) })
    return PreparedData(
      encoded: encoded.encoded,
      totalSize: totalSize + encoded.totalSize - itemSizeHolderSize
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
    var records = self.dicCrypt.compactMap { key, entry -> (key: StoreKey, record: CryptRecord)? in
      guard case .offset(let record) = entry else { return nil }
      return (key, record)
    }
    records.sort { $0.record.offset < $1.record.offset }

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
        for (key, record) in records {
          var moved = record
          moved.offset = UInt32(offset)
          moved.state = encrypter!.state
          encrypter!.encrypt(base + offset, base + offset, count: record.size)
          self.dicCrypt[key] = .offset(moved)
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
          for (key, entry) in self.dicCrypt {
            guard
              Self.encodedEntrySize(
                keyDataLength: key.bytes.count,
                originKeyLength: key.bytes.count,
                dataLength: entry.realValueSize,
                isDataHolder: false,
                needsPlainHolder: true
              ) != nil
            else {
              Log.error("[\(self.id)] reject decryption: key/value cannot fit a plain holder")
              return false
            }
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
