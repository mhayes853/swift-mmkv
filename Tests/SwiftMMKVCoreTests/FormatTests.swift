import Foundation
@_spi(Engines) import SwiftMMKV
import Testing

@testable import _SwiftMMKVCore

// The format primitives of the Swift core, checked against their definitions in MMKV and against
// files the C++ core writes.

@Suite struct VarintTests {
  @Test func `Varint Sizes Change At Each Seven Bits`() {
    let boundaries: [(UInt32, Int)] = [
      (0, 1), (0x7f, 1), (0x80, 2), (0x3fff, 2), (0x4000, 3), (0x1f_ffff, 3), (0x20_0000, 4),
      (0x0fff_ffff, 4), (0x1000_0000, 5), (.max, 5)
    ]
    for (value, size) in boundaries {
      #expect(pbRawVarint32Size(value) == size, "\(value)")
    }
    #expect(pbUInt64Size(0) == 1)
    #expect(pbUInt64Size(1 << 63 - 1) == 9)
    #expect(pbUInt64Size(1 << 63) == 10)
    #expect(pbUInt64Size(.max) == 10)
    #expect(pbInt32Size(-1) == 10)
    #expect(pbInt32Size(.min) == 10)
    #expect(pbInt32Size(.max) == 5)
  }

  @Test func `Every Field Round Trips`() throws {
    var buffer = [UInt8](repeating: 0, count: 256)
    let values: [(Int32, UInt32, Int64, UInt64, Float, Double, Bool)] = [
      (0, 0, 0, 0, 0, 0, false),
      (.max, .max, .max, .max, .greatestFiniteMagnitude, .pi, true),
      (.min, 1, .min, 1 << 63, -.infinity, -0.0, true),
      (-1, 0x80, -1, 0x80, .leastNonzeroMagnitude, .nan, false)
    ]
    for (int32, uint32, int64, uint64, float, double, bool) in values {
      let written = try buffer.withUnsafeMutableBytes { buffer throws in
        var output = CodedOutput(buffer)
        try output.writeInt32(int32)
        try output.writeUInt32(uint32)
        try output.writeInt64(int64)
        try output.writeUInt64(uint64)
        try output.writeFloat(float)
        try output.writeDouble(double)
        try output.writeBool(bool)
        return output.position
      }
      try buffer.withUnsafeBytes { buffer throws in
        var input = CodedInput(UnsafeRawBufferPointer(rebasing: buffer[..<written]))
        #expect(try input.readInt32() == int32)
        #expect(try input.readUInt32() == uint32)
        #expect(try input.readInt64() == int64)
        #expect(try input.readUInt64() == uint64)
        #expect(try input.readFloat().bitPattern == float.bitPattern)
        #expect(try input.readDouble().bitPattern == double.bitPattern)
        #expect(try input.readBool() == bool)
        #expect(input.isAtEnd)
      }
    }
  }

  @Test func `A Negative Int32 Takes Ten Bytes`() throws {
    let encoded = try EncodedValue.int32(-2).encode(expiry: nil)
    #expect(encoded == [0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01])
  }

  @Test func `A Varint Longer Than Ten Bytes Is Malformed`() {
    let bytes = [UInt8](repeating: 0x80, count: 11) + [0]
    bytes.withUnsafeBytes { buffer in
      var input = CodedInput(buffer)
      #expect(throws: CodingError.malformedVarint) { try input.readRawVarint32() }
      var input64 = CodedInput(buffer)
      #expect(throws: CodingError.malformedVarint) { try input64.readInt64() }
    }
  }

  @Test func `Reads Past The End Are Truncated`() {
    [UInt8]([0x80, 0x80]).withUnsafeBytes { buffer in
      var input = CodedInput(buffer)
      #expect(throws: CodingError.truncated) { try input.readRawVarint32() }
    }
    [UInt8]([1, 2, 3]).withUnsafeBytes { buffer in
      var input = CodedInput(buffer)
      #expect(throws: CodingError.truncated) { try input.readDouble() }
    }
    [UInt8]([5, 1, 2]).withUnsafeBytes { buffer in
      var input = CodedInput(buffer)
      #expect(throws: CodingError.invalidLength) { try input.readLengthDelimited() }
    }
    [UInt8]([1, 1, 2]).withUnsafeBytes { buffer in
      var input = CodedInput(buffer)
      #expect(throws: CodingError.invalidLength) { try input.readLengthDelimited(exactly: true) }
    }
  }

  @Test func `Writes Past The End Throw Without Writing`() {
    var buffer = [UInt8](repeating: 0xaa, count: 3)
    buffer.withUnsafeMutableBytes { buffer in
      var output = CodedOutput(buffer)
      #expect(throws: CodingError.outOfSpace) { try output.writeRawLittleEndian32(1) }
      #expect(throws: CodingError.outOfSpace) { try output.writeInt64(-1) }
      #expect(throws: CodingError.outOfSpace) {
        try [UInt8](repeating: 1, count: 3).withUnsafeBytes { try output.writeData($0) }
      }
      #expect(output.position == 0)
    }
    #expect(buffer == [0xaa, 0xaa, 0xaa])
  }
}

@Suite struct CRC32Tests {
  @Test func `Matches The Standard Check Value`() {
    let digest = Array("123456789".utf8).withUnsafeBytes { CRC32.checksum(0, $0) }
    #expect(digest == 0xCBF4_3926)
    #expect([UInt8]().withUnsafeBytes { CRC32.checksum(0, $0) } == 0)
  }

  @Test func `Continuing A Checksum Equals Checksumming Everything At Once`() {
    var generator = SplitMix64(seed: 7)
    let bytes = (0..<1_000).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    let whole = bytes.withUnsafeBytes { CRC32.checksum(0, $0) }
    for cut in [0, 1, 7, 8, 9, 500, 999, 1_000] {
      let first = bytes[..<cut].withUnsafeBytes { CRC32.checksum(0, $0) }
      let continued = bytes[cut...].withUnsafeBytes { CRC32.checksum(first, $0) }
      #expect(continued == whole, "cut at \(cut)")
    }
  }
}

@Suite struct StoreFileTests {
  private static let values: [(key: String, value: TestValue)] = [
    ("bool-true", .bool(true)),
    ("bool-false", .bool(false)),
    ("int32-min", .int32(.min)),
    ("int32-negative", .int32(-1)),
    ("int32-max", .int32(.max)),
    ("uint32-max", .uint32(.max)),
    ("int64-min", .int64(.min)),
    ("int64-max", .int64(.max)),
    ("uint64-max", .uint64(.max)),
    ("float", .float(-1.5)),
    ("double", .double(.pi)),
    ("string", .string("a string with ✨ in it")),
    ("string-empty", .string("")),
    ("bytes", .bytes([0, 1, 2, 255])),
    ("bytes-empty", .bytes([])),
    ("strings", .strings(["one", "", "three ✨"])),
    ("strings-empty", .strings([])),
    ("long-string", .string(String(repeating: "x", count: 300)))
  ]

  @Test func `Values Encode As The C++ Core Writes Them`() throws {
    let file = try Self.cxxStoreFile { store in
      for (key, value) in Self.values {
        #expect(value.set(in: store, forKey: key))
      }
    }
    let records = file.records
    #expect(Set(records.keys.map(\.string)) == Set(Self.values.map(\.key)))
    for (key, value) in Self.values {
      let stored = try #require(records[StoreKey(key)])
      #expect(file.value(at: stored) == (try value.encoded()), "\(key)")
    }
  }

  @Test func `Values Decode As The C++ Core Reads Them`() throws {
    let file = try Self.cxxStoreFile { store in
      for (key, value) in Self.values {
        value.set(in: store, forKey: key)
      }
    }
    for (key, value) in Self.values {
      let stored = try #require(file.records[StoreKey(key)])
      try file.value(at: stored).withUnsafeBytes { bytes throws in
        #expect(try value.matches(bytes), "\(key)")
      }
    }
  }

  @Test func `Expiring Values End With Their Expiry Time`() throws {
    let before = UInt32(Date().timeIntervalSince1970)
    let file = try Self.cxxStoreFile { store in
      store.set(42.0, forKey: "expiring", expiringIn: .seconds(100))
      store.set("forever", forKey: "forever")
    }
    let after = UInt32(Date().timeIntervalSince1970)
    let meta = file.meta
    #expect(meta.hasFlag(MetaInfo.Flag.enableKeyExpire))

    let expiring = file.value(at: try #require(file.records[StoreKey("expiring")]))
    #expect(Array(expiring.prefix(8)) == (try EncodedValue.double(42).encode(expiry: nil)))
    let time = expiring.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    #expect((before + 100)...(after + 100) ~= UInt32(littleEndian: time))

    let forever = file.value(at: try #require(file.records[StoreKey("forever")]))
    #expect(forever == (try "forever".withEncodedBytes { try $0.encode(expiry: 0) }))
  }

  @Test func `The Metadata Checksum Covers The Data`() throws {
    let file = try Self.cxxStoreFile { store in
      for (key, value) in Self.values {
        value.set(in: store, forKey: key)
      }
    }
    let meta = file.meta
    #expect(meta.version == MetaInfo.Version.flag)
    #expect(Int(meta.actualSize) == file.dataSize)
    #expect(meta.crcDigest == file.data.withUnsafeBytes { CRC32.checksum(0, $0) })
  }

  @Test func `Metadata Reads And Writes Back The Same Bytes`() throws {
    let file = try Self.cxxStoreFile { store in
      // Enough overwrites to force full write-backs, which set the sequence and the last
      // confirmed size and checksum.
      for index in 0..<2_000 {
        store.set(Double(index), forKey: "key-\(index % 10)")
      }
    }
    let meta = file.meta
    #expect(meta.sequence > 0)
    #expect(meta.lastActualSize > 0)
    #expect(meta.lastCRCDigest != 0)

    var written = [UInt8](repeating: 0xaa, count: MetaInfo.size)
    written.withUnsafeMutableBytes { meta.write(to: $0.baseAddress!) }
    #expect(written == Array(file.metaBytes.prefix(MetaInfo.size)))
  }

  @Test func `Decoding Applies Overwrites And Removals In Order`() throws {
    let file = try Self.cxxStoreFile { store in
      store.set("first", forKey: "a")
      store.set("second", forKey: "b")
      store.set("third", forKey: "a")
      store.removeValue(forKey: "b")
      store.set("fourth", forKey: "c")
    }
    let records = file.records
    #expect(Set(records.keys) == [StoreKey("a"), StoreKey("c")])
    #expect(
      file.value(at: records[StoreKey("a")]!) == (try "third".withEncodedBytes { try $0.encode(expiry: nil) })
    )
  }

  @Test func `A Damaged Tail Keeps Everything Before It Only When Greedy`() throws {
    let file = try Self.cxxStoreFile { store in
      store.set("first", forKey: "a")
      store.set("second", forKey: "b")
    }
    // Cut the last record in half.
    let damaged = Array(file.data.dropLast(3))
    var index = [StoreKey("unrelated"): RecordLocation(keySize: 1, valueSize: 1, offset: 0)]
    let original = index
    #expect(!damaged.withUnsafeBytes { RecordDecoding.decode($0, into: &index, greedy: false) })
    #expect(index == original)
    #expect(!damaged.withUnsafeBytes { RecordDecoding.decode($0, into: &index, greedy: true) })
    #expect(Set(index.keys) == [StoreKey("unrelated"), StoreKey("a")])
  }

  // MARK: Support

  /// Writes a store with the C++ core and reads its files back.
  private static func cxxStoreFile(_ write: (MMKVStore) -> Void) throws -> StoreFile {
    let root = temporaryDirectory()
    var configuration = MMKVConfiguration(
      id: "store",
      directory: MMKVDirectory(path: root),
      mode: .singleProcess
    )
    configuration.engine = .cxx
    let store = try MMKVStore(configuration)
    write(store)
    store.sync()
    return StoreFile(
      bytes: Array(try Data(contentsOf: URL(fileURLWithPath: "\(root)/store"))),
      metaBytes: Array(try Data(contentsOf: URL(fileURLWithPath: "\(root)/store.crc")))
    )
  }
}

@Suite struct StorePathTests {
  @Test func `Identifiers With Special Characters Are Named By Their MD5`() throws {
    for id in ["with/slash", "with:colon", "a*b", "q?", "\"", "<>", "pipe|", "back\\slash", "nul\0"] {
      let relative = StorePaths.relativeDataPath(id: id)
      #expect(relative.isSpecial, "\(id)")
      #expect(relative.path == "specialCharacter/\(StorePaths.md5Hex(id))")
    }
    #expect(StorePaths.relativeDataPath(id: "plain.id-1_2 ✨") == ("plain.id-1_2 ✨", false))
    #expect(StorePaths.md5Hex("") == "d41d8cd98f00b204e9800998ecf8427e")
  }

  @Test func `The C++ Core Writes Its Files Where The Paths Say`() throws {
    let root = temporaryDirectory()
    for id in ["plain", "with/slash"] {
      var configuration = MMKVConfiguration(
        id: id,
        directory: MMKVDirectory(path: root),
        mode: .singleProcess
      )
      configuration.engine = .cxx
      try MMKVStore(configuration).set(true, forKey: "key")
      let dataPath = StorePaths.dataPath(id: id, root: StorePaths.normalizedRoot(root))
      #expect(FileManager.default.fileExists(atPath: dataPath), "\(id)")
      #expect(FileManager.default.fileExists(atPath: StorePaths.metaPath(dataPath: dataPath)))
    }
    // The C++ core creates the special character directory for every writable root.
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: "\(root)/specialCharacter", isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
  }

  @Test func `Roots Are Absolute With Symbolic Links Resolved`() throws {
    let root = temporaryDirectory()
    let resolved = try #require(realpath(root, nil))
    defer { free(resolved) }
    let canonical = String(cString: resolved)

    #expect(StorePaths.normalizedRoot(root) == canonical)
    #expect(StorePaths.normalizedRoot(root + "/") == canonical)
    #expect(StorePaths.normalizedRoot(root + "/./missing/../other") == canonical + "/other")
    #expect(StorePaths.normalizedRoot(root + "/missing/deeper") == canonical + "/missing/deeper")

    let link = temporaryDirectory() + "/link"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root)
    #expect(StorePaths.normalizedRoot(link + "/inside") == canonical + "/inside")

    let previous = FileManager.default.currentDirectoryPath
    defer { FileManager.default.changeCurrentDirectoryPath(previous) }
    FileManager.default.changeCurrentDirectoryPath(root)
    #expect(StorePaths.normalizedRoot("relative") == canonical + "/relative")
  }
}

// MARK: - Support

/// A store's files as read from disk.
private struct StoreFile {
  var bytes: [UInt8]
  var metaBytes: [UInt8]

  var meta: MetaInfo {
    self.metaBytes.withUnsafeBytes { MetaInfo(reading: $0.baseAddress!) }
  }

  var dataSize: Int {
    Int(self.meta.actualSize)
  }

  /// The data after the four-byte header, up to the size the metadata records.
  var data: ArraySlice<UInt8> {
    self.bytes[4..<(4 + self.dataSize)]
  }

  var records: [StoreKey: RecordLocation] {
    var index = [StoreKey: RecordLocation]()
    let decoded = Array(self.data).withUnsafeBytes {
      RecordDecoding.decode($0, into: &index, greedy: false)
    }
    precondition(decoded)
    return index
  }

  func value(at location: RecordLocation) -> [UInt8] {
    Array(self.data.dropFirst(location.valueOffset).prefix(Int(location.valueSize)))
  }
}

private enum TestValue {
  case bool(Bool)
  case int32(Int32)
  case uint32(UInt32)
  case int64(Int64)
  case uint64(UInt64)
  case float(Float)
  case double(Double)
  case string(String)
  case bytes([UInt8])
  case strings([String])

  @discardableResult
  func set(in store: MMKVStore, forKey key: String) -> Bool {
    switch self {
    case .bool(let value): store.set(value, forKey: key)
    case .int32(let value): store.set(value, forKey: key)
    case .uint32(let value): store.set(value, forKey: key)
    case .int64(let value): store.set(value, forKey: key)
    case .uint64(let value): store.set(value, forKey: key)
    case .float(let value): store.set(value, forKey: key)
    case .double(let value): store.set(value, forKey: key)
    case .string(let value): store.set(value, forKey: key)
    case .bytes(let value): store.set(value, forKey: key)
    case .strings(let value): store.set(value, forKey: key)
    }
  }

  func encoded() throws -> [UInt8] {
    switch self {
    case .bool(let value): try EncodedValue.bool(value).encode(expiry: nil)
    case .int32(let value): try EncodedValue.int32(value).encode(expiry: nil)
    case .uint32(let value): try EncodedValue.uint32(value).encode(expiry: nil)
    case .int64(let value): try EncodedValue.int64(value).encode(expiry: nil)
    case .uint64(let value): try EncodedValue.uint64(value).encode(expiry: nil)
    case .float(let value): try EncodedValue.float(value).encode(expiry: nil)
    case .double(let value): try EncodedValue.double(value).encode(expiry: nil)
    case .string(let value): try value.withEncodedBytes { try $0.encode(expiry: nil) }
    case .bytes(let value): try value.withUnsafeBytes { try EncodedValue.bytes($0).encode(expiry: nil) }
    case .strings(let value): try EncodedValue.strings(value).encode(expiry: nil)
    }
  }

  func matches(_ bytes: UnsafeRawBufferPointer) throws -> Bool {
    switch self {
    case .bool(let value): try ValueDecoding.bool(bytes) == value
    case .int32(let value): try ValueDecoding.int32(bytes) == value
    case .uint32(let value): try ValueDecoding.uint32(bytes) == value
    case .int64(let value): try ValueDecoding.int64(bytes) == value
    case .uint64(let value): try ValueDecoding.uint64(bytes) == value
    case .float(let value): try ValueDecoding.float(bytes) == value
    case .double(let value): try ValueDecoding.double(bytes) == value
    case .string(let value): String(decoding: try ValueDecoding.bytes(bytes), as: UTF8.self) == value
    case .bytes(let value): Array(try ValueDecoding.bytes(bytes)) == value
    case .strings(let value): try ValueDecoding.strings(bytes) == value
    }
  }
}

extension String {
  fileprivate func withEncodedBytes<R>(_ body: (EncodedValue) throws -> R) rethrows -> R {
    try Array(self.utf8).withUnsafeBytes { try body(.bytes($0)) }
  }
}

private func temporaryDirectory() -> String {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("swift-mmkv-core-tests")
    .appendingPathComponent(UUID().uuidString)
  try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory.path
}
