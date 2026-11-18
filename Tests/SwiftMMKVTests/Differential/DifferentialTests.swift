import Foundation
@_spi(Engines) import SwiftMMKV
import Testing

// Differential tests of the Swift core against the C++ core. See "0b. Upstream tests" in
// Docs/swift-core-migration.md.
//
// Every test here uses both cores explicitly, whatever `SWIFTMMKV_TEST_ENGINE` says.

@Suite struct DifferentialTests {
  // MARK: - Same operations, same bytes

  /// Applies the same random operations to a store of each core, and after every operation
  /// checks that both returned the same, hold what a model says they should, and wrote the same
  /// bytes, apart from the random placeholder MMKV writes at the start of the data and the
  /// checksums that cover it.
  @Test(arguments: Array(0..<24))
  func `Both Cores Write The Same Files`(seed: Int) throws {
    var generator = SplitMix64(seed: UInt64(seed))
    let configuration = RandomConfiguration(using: &generator)
    let pair = try StorePair(configuration: configuration)
    var model = [String: TestValue]()

    for step in 0..<250 {
      let operation = Operation.random(using: &generator, configuration: configuration)
      let cxx = operation.apply(to: pair.cxx)
      let swift = operation.apply(to: pair.swift)
      let context = "seed \(seed), step \(step), \(configuration), \(operation)"
      #expect(cxx == swift, "results differ: \(context)")
      operation.apply(to: &model, result: cxx, configuration: configuration)

      try expectContents(of: pair.cxx, match: model, context + " (C++)")
      try expectContents(of: pair.swift, match: model, context + " (Swift)")
      let cxxFiles = try NormalizedStoreFiles(directory: pair.cxxDirectory)
      let swiftFiles = try NormalizedStoreFiles(directory: pair.swiftDirectory)
      try #require(cxxFiles == swiftFiles, "files differ: \(context)\n\(cxxFiles.difference(from: swiftFiles))")
    }
  }

  // MARK: - Reading each other's files

  @Test(arguments: [MMKVConfiguration.Engine.cxx, .swift], [nil] + encryptions)
  func `Each Core Reads What The Other Wrote`(
    writer: MMKVConfiguration.Engine,
    encryption: MMKVConfiguration.Encryption?
  ) throws {
    let reader: MMKVConfiguration.Engine = writer == .cxx ? .swift : .cxx
    var generator = SplitMix64(seed: writer == .cxx ? 100 : 200)
    let configuration = RandomConfiguration(withoutLimits: ())
    let directory = temporaryRootDirectory()
    let store = try makeStore(
      id: "store",
      rootDirectory: directory,
      encryption: encryption,
      engine: writer
    )
    var model = [String: TestValue]()
    for _ in 0..<400 {
      let operation = Operation.random(using: &generator, configuration: configuration)
      let result = operation.apply(to: store)
      operation.apply(to: &model, result: result, configuration: configuration)
    }
    store.sync()

    // A copy under another identifier gets an instance of its own.
    for suffix in ["", ".crc"] {
      try FileManager.default.copyItem(
        atPath: "\(directory)/store\(suffix)",
        toPath: "\(directory)/copy\(suffix)"
      )
    }
    let copy = try makeStore(
      id: "copy",
      rootDirectory: directory,
      encryption: encryption,
      engine: reader
    )
    try expectContents(of: copy, match: model, "\(reader) reading what \(writer) wrote")

    // And it can go on writing to them, which the writer can read in turn.
    copy.set("after", forKey: "k0")
    copy.set(String(repeating: "large", count: 100), forKey: "k1")
    model["k0"] = .string("after")
    model["k1"] = .string(String(repeating: "large", count: 100))
    try expectContents(of: copy, match: model, "\(reader) writing after \(writer)")
    copy.sync()
    for suffix in ["", ".crc"] {
      try FileManager.default.copyItem(
        atPath: "\(directory)/copy\(suffix)",
        toPath: "\(directory)/back\(suffix)"
      )
    }
    let back = try makeStore(
      id: "back",
      rootDirectory: directory,
      encryption: encryption,
      engine: writer
    )
    try expectContents(of: back, match: model, "\(writer) reading what \(reader) appended")
  }

  /// An encrypted store much larger than the window the Swift core decrypts at a time, with
  /// values both kept in memory and left in the file, overwritten and removed, reads back in
  /// both cores.
  @Test(arguments: [MMKVConfiguration.Engine.cxx, .swift])
  func `Each Core Reads A Large Encrypted Store The Other Wrote`(
    writer: MMKVConfiguration.Engine
  ) throws {
    let encryption = MMKVConfiguration.Encryption.aes128(key: "large-store")
    var generator = SplitMix64(seed: writer == .cxx ? 300 : 400)
    let directory = temporaryRootDirectory()
    let store = try makeStore(
      id: "store",
      rootDirectory: directory,
      encryption: encryption,
      engine: writer
    )
    var model = [String: TestValue]()
    for index in 0..<6_000 {
      let key = "key-\(Int.random(in: 0..<1_500, using: &generator))"
      if index % 11 == 0 {
        store.removeValue(forKey: key)
        model[key] = nil
        continue
      }
      // Values on both sides of the 256 bytes an encrypted store keeps in memory.
      let length = [1, 40, 250, 300, 2_000][Int.random(in: 0..<5, using: &generator)]
      let value = String(repeating: "\(index % 10)", count: length)
      store.set(value, forKey: key)
      model[key] = .string(value)
    }
    store.sync()
    #expect(store.usedByteSize > 4 << 17, "the data should span several windows")

    for reader in [MMKVConfiguration.Engine.cxx, .swift] {
      let id = "copy-\(reader)"
      for suffix in ["", ".crc"] {
        try FileManager.default.copyItem(
          atPath: "\(directory)/store\(suffix)",
          toPath: "\(directory)/\(id)\(suffix)"
        )
      }
      let copy = try makeStore(
        id: id,
        rootDirectory: directory,
        encryption: encryption,
        engine: reader
      )
      try expectContents(of: copy, match: model, "\(reader) reading a large store \(writer) wrote")
    }
  }

  /// Re-encrypting with one core, through every transition, leaves files the other core reads.
  @Test(arguments: [MMKVConfiguration.Engine.cxx, .swift])
  func `Each Core Reads What The Other Re-Encrypted`(writer: MMKVConfiguration.Engine) throws {
    let reader: MMKVConfiguration.Engine = writer == .cxx ? .swift : .cxx
    var generator = SplitMix64(seed: writer == .cxx ? 300 : 400)
    let configuration = RandomConfiguration(withoutLimits: ())
    let directory = temporaryRootDirectory()
    let store = try makeStore(id: "store", rootDirectory: directory, engine: writer)
    var model = [String: TestValue]()
    for _ in 0..<200 {
      let operation = Operation.random(using: &generator, configuration: configuration)
      operation.apply(to: &model, result: operation.apply(to: store), configuration: configuration)
    }
    let transitions: [MMKVConfiguration.Encryption?] = [
      .aes128(key: "first"), .aes256(key: "second key, longer"), .aes256(key: "third"), nil,
      .aes128(key: "fourth"),
    ]
    for (index, encryption) in transitions.enumerated() {
      try store.rekey(encryption)
      // Some writes under the new key, so the file has appended records too.
      store.set("written after rekey \(index)", forKey: "k2")
      model["k2"] = .string("written after rekey \(index)")
      store.sync()
      let id = "reader-\(index)"
      for suffix in ["", ".crc"] {
        try FileManager.default.copyItem(
          atPath: "\(directory)/store\(suffix)",
          toPath: "\(directory)/\(id)\(suffix)"
        )
      }
      let copy = try makeStore(
        id: id,
        rootDirectory: directory,
        encryption: encryption,
        engine: reader
      )
      try expectContents(of: copy, match: model, "\(reader) after \(writer) rekeyed to \(String(describing: encryption))")
    }
  }

  // MARK: - Sharing one file

  /// The situation of an app that links react-native-mmkv: both cores have the same files open
  /// in multi-process mode, and each must see the other's writes.
  @Test(arguments: Array(0..<8), [nil] + encryptions)
  func `Both Cores Share One File In Multi Process Mode`(
    seed: Int,
    encryption: MMKVConfiguration.Encryption?
  ) throws {
    var generator = SplitMix64(seed: UInt64(1_000 + seed))
    let configuration = RandomConfiguration(withoutLimits: ())
    let directory = temporaryRootDirectory()
    let id = "shared-\(seed)"
    let cxx = try makeStore(
      id: id,
      rootDirectory: directory,
      mode: .multiProcess,
      encryption: encryption,
      engine: .cxx
    )
    let swift = try makeStore(
      id: id,
      rootDirectory: directory,
      mode: .multiProcess,
      encryption: encryption,
      engine: .swift
    )
    var model = [String: TestValue]()

    for step in 0..<300 {
      let operation = Operation.random(using: &generator, configuration: configuration)
      let writer = Bool.random(using: &generator) ? cxx : swift
      let result = operation.apply(to: writer)
      operation.apply(to: &model, result: result, configuration: configuration)
      let context = "seed \(seed), step \(step), \(operation) through \(writer === cxx ? "C++" : "Swift")"
      try expectContents(of: cxx, match: model, context + ", read by C++")
      try expectContents(of: swift, match: model, context + ", read by Swift")
    }
  }

  @Test func `Each Core Reports The Other's Writes As External`() throws {
    let directory = temporaryRootDirectory()
    let cxx = try makeStore(id: "shared", rootDirectory: directory, mode: .multiProcess, engine: .cxx)
    let swift = try makeStore(id: "shared", rootDirectory: directory, mode: .multiProcess, engine: .swift)
    let cxxChanges = ChangeRecorder()
    let swiftChanges = ChangeRecorder()
    let subscriptions = [cxx.subscribe(cxxChanges.record), swift.subscribe(swiftChanges.record)]
    defer { subscriptions.forEach { $0.cancel() } }
    _ = cxx.count
    _ = swift.count

    cxx.set(1.0, forKey: "from-cxx")
    swift.checkForExternalChanges()
    #expect(swiftChanges.all == [.external])
    #expect(swift.value(forKey: "from-cxx", as: Double.self) == 1)

    swift.set(2.0, forKey: "from-swift")
    cxx.checkForExternalChanges()
    #expect(cxxChanges.all.contains(.external))
    #expect(cxx.value(forKey: "from-swift", as: Double.self) == 2)
  }

  /// Threads writing through both cores at once, which must exclude each other through the file
  /// lock, lose nothing.
  @Test func `Concurrent Writers Through Both Cores Lose Nothing`() async throws {
    let directory = temporaryRootDirectory()
    let cxx = try makeStore(id: "busy", rootDirectory: directory, mode: .multiProcess, engine: .cxx)
    let swift = try makeStore(id: "busy", rootDirectory: directory, mode: .multiProcess, engine: .swift)
    let perWriter = 400
    await withTaskGroup(of: Void.self) { group in
      for (name, store) in [("cxx", cxx), ("swift", swift)] {
        for writer in 0..<2 {
          group.addTask {
            for index in 0..<perWriter {
              // Long enough values that the file grows and is compacted along the way.
              store.set(String(repeating: "\(index)", count: 20), forKey: "\(name)-\(writer)-\(index)")
              if index % 7 == 0 {
                store.removeValue(forKey: "\(name)-\(writer)-\(index)")
              }
            }
          }
        }
        group.addTask {
          // A read-modify-write under the exclusive lock, which must not interleave.
          for _ in 0..<100 {
            store.withExclusiveLock { store in
              let count = store.value(forKey: "counter", as: Int64.self) ?? 0
              store.set(count + 1, forKey: "counter")
            }
          }
        }
      }
    }
    for store in [cxx, swift] {
      store.checkForExternalChanges()
      #expect(store.value(forKey: "counter", as: Int64.self) == 200)
      for name in ["cxx", "swift"] {
        for writer in 0..<2 {
          for index in 0..<perWriter {
            let value = store.value(forKey: "\(name)-\(writer)-\(index)", as: String.self)
            let expected = index % 7 == 0 ? nil : String(repeating: "\(index)", count: 20)
            #expect(value == expected, "\(name)-\(writer)-\(index)")
          }
        }
      }
    }
  }
}

private let encryptions: [MMKVConfiguration.Encryption?] = [
  .aes128(key: "a key"), .aes256(key: "an AES-256 key, 32 bytes long!!"),
]

// MARK: - Operations

/// The settings a sequence of operations runs under.
private struct RandomConfiguration: CustomStringConvertible {
  var compareBeforeSet: Bool
  var itemSizeLimit: Int?
  var expectedCapacity: Int

  init(using generator: inout SplitMix64) {
    self.compareBeforeSet = Bool.random(using: &generator)
    self.itemSizeLimit = Int.random(in: 0..<4, using: &generator) == 0 ? 2_000 : nil
    self.expectedCapacity = [0, 0, 50_000][Int.random(in: 0..<3, using: &generator)]
  }

  init(withoutLimits: Void) {
    self.compareBeforeSet = false
    self.itemSizeLimit = nil
    self.expectedCapacity = 0
  }

  var description: String {
    "compareBeforeSet \(self.compareBeforeSet), itemSizeLimit \(self.itemSizeLimit.map(String.init) ?? "none"), expectedCapacity \(self.expectedCapacity)"
  }
}

private enum TestValue: Equatable, CustomStringConvertible {
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

  static func random(using generator: inout SplitMix64) -> TestValue {
    func string() -> String {
      let length = [0, 1, 10, 100, 300, 3_000][Int.random(in: 0..<6, using: &generator)]
      let scalars = ["a", "é", "✨", "\u{0}", "z"]
      return String((0..<length).map { _ in Character(scalars.randomElement(using: &generator)!) })
    }
    switch Int.random(in: 0..<10, using: &generator) {
    case 0: return .bool(.random(using: &generator))
    case 1: return .int32(.random(in: .min ... .max, using: &generator))
    case 2: return .uint32(.random(in: .min ... .max, using: &generator))
    case 3: return .int64(.random(in: .min ... .max, using: &generator))
    case 4: return .uint64(.random(in: .min ... .max, using: &generator))
    case 5: return .float(Float(Int.random(in: -1_000...1_000, using: &generator)) / 7)
    case 6: return .double(Double(Int.random(in: -1_000_000...1_000_000, using: &generator)) / 3)
    case 7: return .string(string())
    case 8:
      let count = [0, 5, 200, 5_000][Int.random(in: 0..<4, using: &generator)]
      return .bytes((0..<count).map { _ in .random(in: .min ... .max, using: &generator) })
    default:
      return .strings((0..<Int.random(in: 0..<4, using: &generator)).map { _ in string() })
    }
  }

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

  func read(from store: MMKVStore, forKey key: String) -> TestValue? {
    switch self {
    case .bool: store.value(forKey: key, as: Bool.self).map(TestValue.bool)
    case .int32: store.value(forKey: key, as: Int32.self).map(TestValue.int32)
    case .uint32: store.value(forKey: key, as: UInt32.self).map(TestValue.uint32)
    case .int64: store.value(forKey: key, as: Int64.self).map(TestValue.int64)
    case .uint64: store.value(forKey: key, as: UInt64.self).map(TestValue.uint64)
    case .float: store.value(forKey: key, as: Float.self).map(TestValue.float)
    case .double: store.value(forKey: key, as: Double.self).map(TestValue.double)
    case .string: store.value(forKey: key, as: String.self).map(TestValue.string)
    case .bytes: store.value(forKey: key, as: [UInt8].self).map(TestValue.bytes)
    case .strings: store.value(forKey: key, as: [String].self).map(TestValue.strings)
    }
  }

  /// The size of the record MMKV writes, for the item size limit.
  func recordSize(forKey key: String) -> Int {
    let keySize = varintSize(key.utf8.count) + key.utf8.count
    let valueSize: Int
    switch self {
    case .bool: valueSize = 1
    case .int32(let value): valueSize = value < 0 ? 10 : varintSize(Int(value))
    case .uint32(let value): valueSize = varintSize(Int(value))
    case .int64(let value): valueSize = varintSize(UInt64(bitPattern: value))
    case .uint64(let value): valueSize = varintSize(value)
    case .float: valueSize = 4
    case .double: valueSize = 8
    case .string(let value): valueSize = varintSize(value.utf8.count) + value.utf8.count
    case .bytes(let value): valueSize = varintSize(value.count) + value.count
    case .strings(let value):
      let items = value.reduce(0) { $0 + varintSize($1.utf8.count) + $1.utf8.count }
      valueSize = varintSize(items) + items
    }
    return keySize + varintSize(valueSize) + valueSize
  }

  var description: String {
    switch self {
    case .bool(let value): "bool(\(value))"
    case .int32(let value): "int32(\(value))"
    case .uint32(let value): "uint32(\(value))"
    case .int64(let value): "int64(\(value))"
    case .uint64(let value): "uint64(\(value))"
    case .float(let value): "float(\(value))"
    case .double(let value): "double(\(value))"
    case .string(let value): "string(\(value.utf8.count) bytes)"
    case .bytes(let value): "bytes(\(value.count))"
    case .strings(let value): "strings(\(value.count))"
    }
  }
}

private func varintSize(_ value: Int) -> Int {
  varintSize(UInt64(value))
}

private func varintSize(_ value: UInt64) -> Int {
  var size = 1
  var remaining = value >> 7
  while remaining != 0 {
    size += 1
    remaining >>= 7
  }
  return size
}

private enum Operation: CustomStringConvertible {
  case set(String, TestValue)
  case remove(String)
  case removeMany([String])
  case removeAll(keepingCapacity: Bool)
  case trim

  static let keys = (0..<16).map { "k\($0)" } + [String(repeating: "long-key-", count: 40)]

  static func random(
    using generator: inout SplitMix64,
    configuration: RandomConfiguration
  ) -> Operation {
    func key() -> String { Self.keys.randomElement(using: &generator)! }
    switch Int.random(in: 0..<100, using: &generator) {
    case 0..<70: return .set(key(), .random(using: &generator))
    case 70..<84: return .remove(key())
    case 84..<92: return .removeMany((0..<Int.random(in: 0..<5, using: &generator)).map { _ in key() })
    case 92..<95: return .removeAll(keepingCapacity: .random(using: &generator))
    default: return .trim
    }
  }

  /// Applies the operation, returning what the store reported.
  func apply(to store: MMKVStore) -> Bool? {
    switch self {
    case .set(let key, let value): value.set(in: store, forKey: key)
    case .remove(let key): store.removeValue(forKey: key)
    case .removeMany(let keys):
      { store.removeValues(forKeys: keys); return nil }()
    case .removeAll(let keepingCapacity):
      { store.removeAll(keepingCapacity: keepingCapacity); return nil }()
    case .trim:
      { store.trim(); return nil }()
    }
  }

  /// Applies the operation to the model of what the store holds.
  func apply(
    to model: inout [String: TestValue],
    result: Bool?,
    configuration: RandomConfiguration
  ) {
    switch self {
    case .set(let key, let value):
      if result == true {
        model[key] = value
      }
    case .remove(let key): model[key] = nil
    case .removeMany(let keys): keys.forEach { model[$0] = nil }
    case .removeAll: model.removeAll()
    case .trim: break
    }
  }

  var description: String {
    switch self {
    case .set(let key, let value): "set(\(key.prefix(12)), \(value))"
    case .remove(let key): "remove(\(key.prefix(12)))"
    case .removeMany(let keys): "removeMany(\(keys.map { $0.prefix(12) }))"
    case .removeAll(let keepingCapacity): "removeAll(keepingCapacity: \(keepingCapacity))"
    case .trim: "trim"
    }
  }
}

// MARK: - Stores and files

/// A store of each core, with the same configuration, in directories of their own.
private struct StorePair {
  let cxx: MMKVStore
  let swift: MMKVStore
  let cxxDirectory: String
  let swiftDirectory: String

  init(configuration: RandomConfiguration) throws {
    self.cxxDirectory = temporaryRootDirectory()
    self.swiftDirectory = temporaryRootDirectory()
    func open(_ engine: MMKVConfiguration.Engine, _ directory: String) throws -> MMKVStore {
      var storeConfiguration = MMKVConfiguration(
        id: "store",
        directory: MMKVDirectory(path: directory),
        mode: .singleProcess,
        expectedCapacity: configuration.expectedCapacity,
        compareBeforeSet: configuration.compareBeforeSet,
        itemSizeLimit: configuration.itemSizeLimit
      )
      storeConfiguration.engine = engine
      return try MMKVStore(storeConfiguration)
    }
    self.cxx = try open(.cxx, self.cxxDirectory)
    self.swift = try open(.swift, self.swiftDirectory)
  }
}

private func expectContents(
  of store: MMKVStore,
  match model: [String: TestValue],
  _ context: String,
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  try #require(store.keys == Set(model.keys), "keys differ: \(context)", sourceLocation: sourceLocation)
  #expect(store.count == model.count, "count differs: \(context)", sourceLocation: sourceLocation)
  for (key, value) in model {
    #expect(value.read(from: store, forKey: key) == value, "\(key): \(context)", sourceLocation: sourceLocation)
  }
}

/// A store's two files, with the bytes that may legitimately differ between the cores cleared:
/// the random placeholder at the start of the data, and the checksums that cover it.
private struct NormalizedStoreFiles: Equatable {
  var data: [UInt8]
  var metadata: [UInt8]

  init(directory: String) throws {
    self.data = Array(try Data(contentsOf: URL(fileURLWithPath: "\(directory)/store")))
    self.metadata = Array(try Data(contentsOf: URL(fileURLWithPath: "\(directory)/store.crc")))
    if self.data.count >= 8 {
      self.data.replaceSubrange(4..<8, with: [0, 0, 0, 0])
    }
    // The checksum and the last confirmed checksum.
    for offset in [0, 36] where self.metadata.count >= offset + 4 {
      self.metadata.replaceSubrange(offset..<(offset + 4), with: [0, 0, 0, 0])
    }
  }

  func difference(from other: NormalizedStoreFiles) -> String {
    func describe(_ name: String, _ left: [UInt8], _ right: [UInt8]) -> String {
      if left.count != right.count {
        return "\(name): \(left.count) bytes vs \(right.count) bytes"
      }
      guard let first = left.indices.first(where: { left[$0] != right[$0] }) else { return "" }
      let window = first..<min(first + 16, left.count)
      return "\(name): first difference at \(first): \(Array(left[window])) vs \(Array(right[window]))"
    }
    return [describe("data", self.data, other.data), describe("metadata", self.metadata, other.metadata)]
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }
}

/// A small seeded generator, so that failures reproduce.
private struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    self.state = seed
  }

  mutating func next() -> UInt64 {
    self.state &+= 0x9E37_79B9_7F4A_7C15
    var z = self.state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
