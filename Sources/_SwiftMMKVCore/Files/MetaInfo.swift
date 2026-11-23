/// The contents of a store's `.crc` file, MMKV's `MMKVMetaInfo`, which the C++ core copies to and
/// from the file with `memcpy`. The layout is therefore the C struct's on a little-endian 64-bit
/// platform: 112 bytes, with the flags aligned to offset 104.
package struct MetaInfo: Equatable, Sendable {
  /// The versions of the layout. Each adds to what the file records.
  package enum Version {
    /// Records how many full write-backs there have been.
    package static let sequence: UInt32 = 1
    /// Records a random IV for encryption.
    package static let randomIV: UInt32 = 2
    /// Records the data's size here as well as with its checksum.
    package static let actualSize: UInt32 = 3
    /// Records flags.
    package static let flag: UInt32 = 4
    /// Every version from this one on means the file is in a suspicious state.
    package static let holder: UInt32 = 7
  }

  package enum Flag {
    /// The store has expiring keys, so every value ends with an expiry time.
    package static let enableKeyExpire: UInt64 = 1 << 0
  }

  package static let size = 112

  package var crcDigest: UInt32 = 0
  package var version: UInt32 = Version.sequence
  /// How many full write-backs there have been.
  package var sequence: UInt32 = 0
  /// The IV of an encrypted store.
  package var vector: [UInt8] = [UInt8](repeating: 0, count: 16)
  package var actualSize: UInt32 = 0
  /// The size and checksum as of the last full write-back, which a damaged file falls back to.
  package var lastActualSize: UInt32 = 0
  package var lastCRCDigest: UInt32 = 0
  /// Sixteen reserved words that MMKV never sets but copies back unchanged.
  package var reserved: [UInt32] = [UInt32](repeating: 0, count: 16)
  package var flags: UInt64 = 0

  package init() {}

  /// Reads the struct from the start of `memory`, which must hold at least ``size`` bytes.
  package init(reading memory: UnsafeRawPointer) {
    func word(_ offset: Int) -> UInt32 { loadWord(memory, offset) }
    self.crcDigest = word(0)
    self.version = word(4)
    self.sequence = word(8)
    self.vector = Array(UnsafeRawBufferPointer(start: memory + 12, count: 16))
    self.actualSize = word(28)
    self.lastActualSize = word(32)
    self.lastCRCDigest = word(36)
    self.reserved = (0..<16).map { word(40 + $0 * 4) }
    self.flags = UInt64(littleEndian: memory.loadUnaligned(fromByteOffset: 104, as: UInt64.self))
  }

  /// The fields that tell whether another process changed the data, read without the rest, so
  /// that checking for changes allocates nothing.
  package struct Summary {
    package var crcDigest: UInt32
    package var sequence: UInt32
    package var actualSize: UInt32

    package init(reading memory: UnsafeRawPointer) {
      self.crcDigest = loadWord(memory, 0)
      self.sequence = loadWord(memory, 8)
      self.actualSize = loadWord(memory, 28)
    }
  }

  package func hasFlag(_ flag: UInt64) -> Bool {
    self.flags & flag != 0
  }

  /// Writes the whole struct, as `MMKVMetaInfo::write` does, but in an order that suits a process
  /// stopping part way: the size and checksum after everything they depend on, such as the IV
  /// and the flags, and the sequence number last of all.
  package func write(to memory: UnsafeMutableRawPointer) {
    func store(_ value: UInt32, _ offset: Int) {
      memory.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self)
    }
    store(self.version, 4)
    self.vector.withUnsafeBytes { (memory + 12).copyMemory(from: $0.baseAddress!, byteCount: 16) }
    store(self.lastActualSize, 32)
    store(self.lastCRCDigest, 36)
    for (index, word) in self.reserved.enumerated() {
      store(word, 40 + index * 4)
    }
    memory.storeBytes(of: self.flags.littleEndian, toByteOffset: 104, as: UInt64.self)
    store(self.actualSize, 28)
    store(self.crcDigest, 0)
    store(self.sequence, 8)
  }

  /// Writes only the sequence number.
  package func writeSequence(to memory: UnsafeMutableRawPointer) {
    memory.storeBytes(of: self.sequence.littleEndian, toByteOffset: 8, as: UInt32.self)
  }

  /// Writes only the last confirmed size and checksum.
  package func writeLastConfirmed(to memory: UnsafeMutableRawPointer) {
    memory.storeBytes(of: self.lastActualSize.littleEndian, toByteOffset: 32, as: UInt32.self)
    memory.storeBytes(of: self.lastCRCDigest.littleEndian, toByteOffset: 36, as: UInt32.self)
  }

  /// Writes only the checksum and the size, as `writeCRCAndActualSizeOnly` does.
  package func writeCRCAndActualSize(to memory: UnsafeMutableRawPointer) {
    memory.storeBytes(of: self.crcDigest.littleEndian, toByteOffset: 0, as: UInt32.self)
    memory.storeBytes(of: self.actualSize.littleEndian, toByteOffset: 28, as: UInt32.self)
  }
}

/// The little-endian 32-bit word at `offset` bytes into `memory`.
private func loadWord(_ memory: UnsafeRawPointer, _ offset: Int) -> UInt32 {
  UInt32(littleEndian: memory.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
}
