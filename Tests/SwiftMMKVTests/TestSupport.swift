import Foundation
import SwiftMMKV
import Testing

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
  id: MMKVStore.ID = .default,
  rootDirectory: String = temporaryRootDirectory(),
  mode: MMKVConfiguration.Mode = .singleProcess,
  isReadOnly: Bool = false,
  encryption: MMKVConfiguration.Encryption? = nil,
  itemSizeLimit: Int? = nil
) throws -> MMKVStore {
  try MMKVStore(
    MMKVConfiguration(
      id: id,
      directory: MMKVDirectory(path: rootDirectory),
      mode: mode,
      isReadOnly: isReadOnly,
      encryption: encryption,
      itemSizeLimit: itemSizeLimit
    )
  )
}

/// Opens one pair of files under two identifiers, the second being hard links to the first.
/// MMKV keeps one instance per identifier, so each gets an instance of its own over the same
/// files, and the two behave towards each other the way two processes, or two copies of MMKV,
/// would.
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
  for suffix in ["", ".crc"] {
    try FileManager.default.linkItem(
      atPath: "\(rootDirectory)/\(real)\(suffix)",
      toPath: "\(rootDirectory)/\(link)\(suffix)"
    )
  }
  return (
    first, try makeStore(id: MMKVStore.ID(rawValue: link), rootDirectory: rootDirectory, mode: mode)
  )
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

extension Result {
  /// The success, or `nil` for a failure, to compare what a subscription delivered.
  var success: Success? {
    try? self.get()
  }
}

/// Encodes a value as its description and decodes it back, to stand in for a coder that is a
/// class, as coded keys need, and that this package knows nothing about.
final class TextCoder: MMKVTopLevelEncoder, MMKVTopLevelDecoder, Sendable {
  struct Failure: Error {}

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

/// Runs `body`, which is expected to throw an ``MMKVError`` with this code.
///
/// - Returns: The error, to look at its message.
@discardableResult
func expectError<R>(
  _ code: MMKVError.Code,
  sourceLocation: SourceLocation = #_sourceLocation,
  _ body: () throws -> R
) -> MMKVError? {
  do {
    _ = try body()
    Issue.record("Nothing was thrown.", sourceLocation: sourceLocation)
    return nil
  } catch let error as MMKVError {
    #expect(error.code == code, sourceLocation: sourceLocation)
    return error
  } catch {
    Issue.record(
      "Something other than an MMKVError was thrown: \(error)",
      sourceLocation: sourceLocation
    )
    return nil
  }
}
