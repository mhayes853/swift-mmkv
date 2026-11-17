import Foundation
import SwiftMMKV

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
