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
      rootDirectory: rootDirectory,
      mode: mode,
      isReadOnly: isReadOnly,
      encryption: encryption,
      itemSizeLimit: itemSizeLimit
    )
  )
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
