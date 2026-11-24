import Foundation
@_spi(Engines) import SwiftMMKV
import Testing

// Helpers for the ports of MMKV's own tests. They reach a store only through the public API and
// its files on disk, so the ports run unchanged against any core.

/// One memory page: the size MMKV creates a store's file with, and the unit it grows it by
/// (`DEFAULT_MMAP_SIZE`).
let pageSize = Int(getpagesize())

/// The key upstream reads when it wants one with no value.
let keyNotExist = "KeyNotExist"

/// How long to wait for a value written to expire in one second.
///
/// MMKV stores an expiry date in whole seconds, `time(nullptr) + duration`, and treats a value as
/// expired once the current second reaches it. A one-second value therefore expires somewhere
/// between an instant and one second after it is written, and a little over a second is always
/// enough.
let oneSecondExpiry = Duration.milliseconds(1100)

/// Enables expiration on `store` the only way the package can: with an expiring write.
func enableExpiration(on store: MMKVStore) throws {
  #expect(store.set(true, forKey: "enable-expiration", expiry: .after(.seconds(3600))))
  #expect(store.removeValue(forKey: "enable-expiration"))
}

// MARK: - Files

/// A store's pair of files: the data file `<root>/<id>` and the metadata file `<root>/<id>.crc`.
struct StoreFiles {
  let id: MMKVStore.ID
  let rootDirectory: String

  var dataPath: String { "\(self.rootDirectory)/\(self.id)" }
  var metadataPath: String { "\(self.dataPath).crc" }

  func data() throws -> [UInt8] {
    try readFile(atPath: self.dataPath)
  }

  func metadata() throws -> StoreMetadata {
    try StoreMetadata(bytes: readFile(atPath: self.metadataPath))
  }

  func dataFileSize() throws -> Int {
    try sizeOfFile(atPath: self.dataPath)
  }

  /// The data file's first four bytes, where versions of MMKV before `MMKVVersionActualSize`
  /// kept the size of the data. Current versions keep it in the metadata and leave these zero.
  func dataHeader() throws -> UInt32 {
    try littleEndianUInt32(self.data(), at: 0)
  }

  /// Whether the files pass the integrity check MMKV makes before loading them, as upstream's
  /// `MMKV::isFileValid` does it: the metadata is complete, the data file holds the size the
  /// metadata records, and the CRC32 of that much data matches the metadata's digest.
  func isValid() -> Bool {
    guard
      let metadataBytes = try? readFile(atPath: self.metadataPath),
      metadataBytes.count >= StoreMetadata.size,
      let data = try? self.data(),
      data.count >= 4
    else {
      return false
    }
    let metadata = StoreMetadata(bytes: metadataBytes)
    let actualSize =
      metadata.version >= StoreMetadata.versionWithActualSize
      ? Int(metadata.actualSize) : Int(littleEndianUInt32(data, at: 0))
    guard actualSize <= data.count - 4 else { return false }
    return crc32(data[4..<(4 + actualSize)]) == metadata.crcDigest
  }
}

/// Flushes `store` and copies its files to `newID` in the same directory, returning the copy.
///
/// The package keeps every instance open for the rest of the process, and opening the same
/// identifier again returns the instance already open. Opening the copy instead gives a fresh
/// instance over the store's contents as they are now, which is how these ports stand in for
/// upstream closing a store and opening it again.
@discardableResult
func copyFiles(of store: MMKVStore, in rootDirectory: String, to newID: MMKVStore.ID) throws
  -> StoreFiles
{
  store.sync()
  try copyStoreFiles(id: store.id, to: newID, in: rootDirectory)
  return StoreFiles(id: newID, rootDirectory: rootDirectory)
}

/// Overwrites four bytes of a file, little-endian, without changing anything else.
func overwrite(_ value: UInt32, atOffset offset: Int, ofFileAt path: String) throws {
  let handle = try #require(FileHandle(forUpdatingAtPath: path))
  defer { try? handle.close() }
  try handle.seek(toOffset: UInt64(offset))
  try handle.write(contentsOf: withUnsafeBytes(of: value.littleEndian) { Data($0) })
}

func truncateFile(atPath path: String, toSize size: Int) throws {
  #expect(truncate(path, off_t(size)) == 0)
}

/// Whether `bytes` contains `needle` anywhere.
func containsBytes(_ bytes: [UInt8], _ needle: [UInt8]) -> Bool {
  guard !needle.isEmpty, needle.count <= bytes.count else { return needle.isEmpty }
  return (0...(bytes.count - needle.count))
    .contains { start in
      bytes[start..<(start + needle.count)].elementsEqual(needle)
    }
}

// MARK: - Metadata

/// The fields of MMKV's metadata file, `MMKVMetaInfo` in `MMKVMetaInfo.hpp`, which is stored as
/// the little-endian, naturally aligned C struct.
struct StoreMetadata: Equatable {
  /// `sizeof(MMKVMetaInfo)`.
  static let size = 112
  /// `MMKVVersionActualSize`: from this version on, the metadata holds the size of the data.
  static let versionWithActualSize: UInt32 = 3

  static let crcDigestOffset = 0
  static let versionOffset = 4
  static let sequenceOffset = 8
  static let ivOffset = 12
  static let actualSizeOffset = 28
  static let lastConfirmedActualSizeOffset = 32
  static let lastConfirmedCRCDigestOffset = 36
  static let flagsOffset = 104

  /// The CRC32 of the data file's contents after its four-byte header.
  var crcDigest: UInt32
  var version: UInt32
  /// How many times the file has been rewritten in full.
  var sequence: UInt32
  /// The AES initialization vector of an encrypted store.
  var iv: [UInt8]
  /// How many bytes of key-value pairs follow the data file's header.
  var actualSize: UInt32
  var lastConfirmedActualSize: UInt32
  var lastConfirmedCRCDigest: UInt32
  var flags: UInt64

  /// Whether the store's values carry an expiry date (`EnableKeyExipre`).
  var hasExpiration: Bool { self.flags & 1 != 0 }

  init(bytes: [UInt8]) {
    precondition(bytes.count >= Self.size, "Truncated metadata: \(bytes.count) bytes")
    self.crcDigest = littleEndianUInt32(bytes, at: Self.crcDigestOffset)
    self.version = littleEndianUInt32(bytes, at: Self.versionOffset)
    self.sequence = littleEndianUInt32(bytes, at: Self.sequenceOffset)
    self.iv = Array(bytes[Self.ivOffset..<(Self.ivOffset + 16)])
    self.actualSize = littleEndianUInt32(bytes, at: Self.actualSizeOffset)
    self.lastConfirmedActualSize = littleEndianUInt32(
      bytes,
      at: Self.lastConfirmedActualSizeOffset
    )
    self.lastConfirmedCRCDigest = littleEndianUInt32(bytes, at: Self.lastConfirmedCRCDigestOffset)
    self.flags =
      UInt64(littleEndianUInt32(bytes, at: Self.flagsOffset))
      | UInt64(littleEndianUInt32(bytes, at: Self.flagsOffset + 4)) << 32
  }
}

func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
  (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
}

// MARK: - CRC32

/// zlib's CRC32, which MMKV uses for its integrity check.
func crc32(_ bytes: some Sequence<UInt8>) -> UInt32 {
  var crc: UInt32 = 0xFFFF_FFFF
  for byte in bytes {
    crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
  }
  return crc ^ 0xFFFF_FFFF
}

private let crc32Table: [UInt32] = (0..<256)
  .map { index in
    (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
  }
