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

  var description: String { self.rawValue }
}

extension MMKVConfiguration.Engine {
  /// The features this engine has so far.
  var features: Set<EngineFeature> {
    switch self {
    case .cxx: Set(EngineFeature.allCases)
    case .swift: []
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
func temporaryRootDirectory(function: String = #function) -> String {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("swift-mmkv-tests")
    .appendingPathComponent(UUID().uuidString)
  try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory.path
}

func makeStore(
  id: String = MMKVConfiguration.defaultID,
  rootDirectory: String = temporaryRootDirectory(),
  mode: MMKVConfiguration.Mode = .singleProcess,
  isReadOnly: Bool = false,
  encryption: MMKVConfiguration.Encryption? = nil,
  itemSizeLimit: Int? = nil,
  engine: MMKVConfiguration.Engine = engineUnderTest
) throws -> MMKVStore {
  var configuration = MMKVConfiguration(
    id: id,
    directory: MMKVDirectory(path: rootDirectory),
    mode: mode,
    isReadOnly: isReadOnly,
    encryption: encryption,
    itemSizeLimit: itemSizeLimit
  )
  configuration.engine = engine
  return try MMKVStore(configuration)
}

/// Opens one pair of files under two identifiers, the second being hard links to the first.
/// MMKV keeps one instance per identifier, so each gets an instance of its own over the same
/// files, and the two behave towards each other the way two processes, or two copies of MMKV,
/// would.
func makeLinkedStores(
  mode: MMKVConfiguration.Mode
) throws -> (first: MMKVStore, second: MMKVStore) {
  let rootDirectory = temporaryRootDirectory()
  let first = try makeStore(id: "real", rootDirectory: rootDirectory, mode: mode)
  // The files are created when the store is first used.
  _ = first.count
  for suffix in ["", ".crc"] {
    try FileManager.default.linkItem(
      atPath: "\(rootDirectory)/real\(suffix)",
      toPath: "\(rootDirectory)/link\(suffix)"
    )
  }
  return (first, try makeStore(id: "link", rootDirectory: rootDirectory, mode: mode))
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
final class ChangeRecorder: Sendable {
  private let changes = NSLock()
  nonisolated(unsafe) private var recorded = [MMKVStore.Change]()

  var all: [MMKVStore.Change] {
    self.changes.withLock { self.recorded }
  }

  func record(_ change: MMKVStore.Change) {
    self.changes.withLock { self.recorded.append(change) }
  }
}

/// Collects the values a per-key subscription delivers.
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
