import Foundation
@_spi(Engines) import SwiftMMKV
import Testing

// MARK: - Engines

/// The core the tests run against, from the `SWIFTMMKV_TEST_ENGINE` environment variable: `cxx`
/// (the default) or `swift`.
let engineUnderTest: MMKVConfiguration.Engine = {
  guard let name = ProcessInfo.processInfo.environment["SWIFTMMKV_TEST_ENGINE"] else {
    return .cxx
  }
  guard let engine = MMKVConfiguration.Engine(rawValue: name) else {
    fatalError("Unknown SWIFTMMKV_TEST_ENGINE \(name). Expected one of: cxx, swift.")
  }
  return engine
}()

/// A part of MMKV's core that the Swift core may not have yet.
enum EngineFeature: String, CaseIterable, CustomStringConvertible {
  /// Opening, reading, and writing a single-process store.
  case store
  case readOnly
  case expiry
  case multiProcess
  case encryption
  /// Copying one store's keys and values into another.
  case importing
  /// Checking for, listing, and removing a directory's stores without opening them.
  case directory
  /// Sending the core's log messages to ``MMKVLog``'s handler and logger.
  case logging
  /// Reporting files that fail their integrity check as they load.
  case integrityFailures
  /// Refusing to open, or to write over, a store whose encryption key is wrong.
  case encryptionKeyCheck

  var description: String { self.rawValue }
}

extension MMKVConfiguration.Engine {
  /// The features this engine has so far.
  var features: Set<EngineFeature> {
    switch self {
    case .cxx: Set(EngineFeature.allCases).subtracting([.encryptionKeyCheck])
    case .swift:
      [
        .store, .readOnly, .expiry, .importing, .multiProcess, .encryption, .encryptionKeyCheck,
        .integrityFailures
      ]
    }
  }
}

extension Trait where Self == ConditionTrait {
  /// Runs a test or suite only when the engine under test has every one of `features`. Every
  /// test that opens a store needs at least ``EngineFeature/store``.
  static func requires(_ features: EngineFeature...) -> Self {
    let missing = Set(features).subtracting(engineUnderTest.features)
    return .enabled(
      if: missing.isEmpty,
      "The \(engineUnderTest) engine does not have: \(missing.map(\.rawValue).sorted())"
    )
  }
}

// MARK: - Stores

/// A directory that is unique to one test, so that tests never share a store.
///
/// MMKV keeps every store open for the rest of the process, so the directory is left behind
/// for the system to clean up rather than removed from under a live memory map.
func temporaryRootDirectory() -> String {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("swift-mmkv-tests")
    .appendingPathComponent(UUID().uuidString)
  try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory.path
}

func makeStore(
  id: MMKVStore.ID = .default,
  rootDirectory: String = temporaryRootDirectory(),
  mode: MMKVConfiguration.Mode = .singleProcess,
  isReadOnly: Bool = false,
  encryption: MMKVConfiguration.Encryption? = nil,
  expectedCapacity: Int = 0,
  recovery: MMKVConfiguration.Recovery = .discard,
  compareBeforeSet: Bool = false,
  itemSizeLimit: Int? = nil,
  engine: MMKVConfiguration.Engine = engineUnderTest
) throws -> MMKVStore {
  var configuration = MMKVConfiguration(
    id: id,
    directory: MMKVDirectory(path: rootDirectory),
    mode: mode,
    isReadOnly: isReadOnly,
    encryption: encryption,
    expectedCapacity: expectedCapacity,
    recovery: recovery,
    compareBeforeSet: compareBeforeSet,
    itemSizeLimit: itemSizeLimit
  )
  configuration.engine = engine
  return try MMKVStore(configuration)
}

/// Opens one pair of files under two identifiers, the second being hard links to the first.
/// MMKV keeps one instance per identifier, so each gets an instance of its own over the same
/// files, and the two behave towards each other the way two processes, or two copies of MMKV,
/// would.
///
/// The identifiers are unique to the call. The C++ core reports an external change by
/// identifier alone, so pairs with the same identifiers in tests running in parallel would
/// report each other's changes.
func makeLinkedStores(
  mode: MMKVConfiguration.Mode
) throws -> (first: MMKVStore, second: MMKVStore) {
  let rootDirectory = temporaryRootDirectory()
  // The core reports an outside change by identifier alone, so identifiers shared between
  // tests running in parallel would report each other's changes.
  let unique = UUID().uuidString
  let (real, link) = ("real-\(unique)", "link-\(unique)")
  let first = try makeStore(
    id: MMKVStore.ID(rawValue: real),
    rootDirectory: rootDirectory,
    mode: mode
  )
  // The files are created when the store is first used.
  _ = first.count
  for extensionSuffix in ["", ".crc"] {
    try FileManager.default.linkItem(
      atPath: "\(rootDirectory)/\(real)\(extensionSuffix)",
      toPath: "\(rootDirectory)/\(link)\(extensionSuffix)"
    )
  }
  return (
    first, try makeStore(id: MMKVStore.ID(rawValue: link), rootDirectory: rootDirectory, mode: mode)
  )
}

/// Copies the two files of the store `id` in `rootDirectory` to `newID`. MMKV keeps one instance
/// per identifier, so opening the copy gives an instance of its own over the store's contents as
/// they are now.
func copyStoreFiles(id: MMKVStore.ID, to newID: MMKVStore.ID, in rootDirectory: String) throws {
  for suffix in ["", ".crc"] {
    try FileManager.default.copyItem(
      atPath: "\(rootDirectory)/\(id)\(suffix)",
      toPath: "\(rootDirectory)/\(newID)\(suffix)"
    )
  }
}

/// Creates the two files of a store at `path` without opening that store in this process, by
/// copying those of a store that is opened elsewhere.
func makeUnopenedStoreFiles(at path: String) throws {
  let sourceDirectory = temporaryRootDirectory()
  let source = try makeStore(id: "source", rootDirectory: sourceDirectory)
  source.set("value", forKey: "key")
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent,
    withIntermediateDirectories: true
  )
  for suffix in ["", ".crc"] {
    try FileManager.default.copyItem(
      atPath: "\(sourceDirectory)/source\(suffix)",
      toPath: path + suffix
    )
  }
}

/// Collects the changes a store reports.
typealias ChangeRecorder = ValueRecorder<MMKVStore.Change>

/// Collects the values a subscription delivers.
final class ValueRecorder<Value: Sendable>: Sendable {
  private let values = NSLock()
  nonisolated(unsafe) private var recorded = [Value]()

  var all: [Value] {
    self.values.withLock { self.recorded }
  }

  func record(_ value: Value) {
    self.values.withLock { self.recorded.append(value) }
  }
}

// MARK: - Files

func readFile(atPath path: String) throws -> [UInt8] {
  try Array(Data(contentsOf: URL(fileURLWithPath: path)))
}

func sizeOfFile(atPath path: String) throws -> Int {
  try #require(FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
}

// MARK: - Coding and randomness

extension Result {
  /// The success, or `nil` for a failure, to compare what a subscription delivered.
  var success: Success? {
    try? self.get()
  }
}

/// Encodes a value as its description and decodes it back, to stand in for a coder that is a
/// class, as coded keys need, and that this package knows nothing about.
final class TextCoder: MMKVTopLevelEncoder, MMKVTopLevelDecoder, Sendable {
  struct Failure: Error, Equatable {}

  static let shared = TextCoder()

  func encode<T: Encodable>(_ value: T) throws -> String {
    guard let value = value as? any LosslessStringConvertible else { throw Failure() }
    return value.description
  }

  func decode<T: Decodable>(_ type: T.Type, from input: String) throws -> T {
    guard
      let type = type as? any LosslessStringConvertible.Type,
      let value = type.init(input) as? T
    else {
      throw Failure()
    }
    return value
  }
}

/// A small seeded generator, so that failures reproduce.
struct SplitMix64: RandomNumberGenerator {
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
