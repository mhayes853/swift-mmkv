import Foundation
import SwiftMMKV
import Testing

/// Failures are reported to every listener in the process, so each test only looks at those of
/// a store it made.
@Suite(.requires(.integrityFailures)) struct MMKVStoreIntegrityFailureTests {
  // A store loads its file when it is first read or written, not when it is opened.

  @Test func `Reports A File That Does Not Match Its Checksum`() throws {
    let recorder = ValueRecorder<MMKVStore.IntegrityFailure>()
    let subscription = MMKVStore.subscribeToIntegrityFailures(recorder.record)
    let (id, rootDirectory) = try makeUnopenedStore()
    try overwriteChecksum(ofStoreAt: "\(rootDirectory)/\(id)")

    let store = try makeStore(id: id, rootDirectory: rootDirectory)
    #expect(recorder.all.filter { $0.id == id }.isEmpty)
    _ = store.count

    #expect(
      recorder.all.filter { $0.id == id } == [MMKVStore.IntegrityFailure(id: id, kind: .checksum)]
    )
    subscription.cancel()
  }

  @Test func `Reports A File That Is Shorter Than Its Recorded Size`() throws {
    let recorder = ValueRecorder<MMKVStore.IntegrityFailure>()
    let subscription = MMKVStore.subscribeToIntegrityFailures(recorder.record)
    let (id, rootDirectory) = try makeUnopenedStore()
    try overwriteRecordedSize(ofStoreAt: "\(rootDirectory)/\(id)")

    let store = try makeStore(id: id, rootDirectory: rootDirectory)
    #expect(recorder.all.filter { $0.id == id }.isEmpty)
    _ = store.count

    #expect(
      recorder.all.filter { $0.id == id }
        == [MMKVStore.IntegrityFailure(id: id, kind: .fileLength)]
    )
    subscription.cancel()
  }

  @Test func `Reports Nothing For An Intact File`() throws {
    let recorder = ValueRecorder<MMKVStore.IntegrityFailure>()
    let subscription = MMKVStore.subscribeToIntegrityFailures(recorder.record)
    let (id, rootDirectory) = try makeUnopenedStore()

    let store = try makeStore(id: id, rootDirectory: rootDirectory)

    #expect(store.value(forKey: "key", as: String.self) == "value")
    #expect(!recorder.all.contains { $0.id == id })
    subscription.cancel()
  }

  @Test func `Stops Reporting Once Cancelled`() throws {
    let recorder = ValueRecorder<MMKVStore.IntegrityFailure>()
    let subscription = MMKVStore.subscribeToIntegrityFailures(recorder.record)
    let (id, rootDirectory) = try makeUnopenedStore()
    try overwriteChecksum(ofStoreAt: "\(rootDirectory)/\(id)")
    subscription.cancel()

    _ = try makeStore(id: id, rootDirectory: rootDirectory).count

    #expect(!recorder.all.contains { $0.id == id })
  }
}

private func makeUnopenedStore() throws -> (id: MMKVStore.ID, rootDirectory: String) {
  let id = MMKVStore.ID(rawValue: "integrity-\(UUID().uuidString)")
  let rootDirectory = temporaryRootDirectory()
  try makeUnopenedStoreFiles(at: "\(rootDirectory)/\(id)")
  return (id, rootDirectory)
}

// A store's `.crc` file starts with the checksum of its contents, and holds their size at byte
// 28, followed by the size and checksum that were last synced to disk, which MMKV falls back on.

private func overwriteChecksum(ofStoreAt path: String) throws {
  try overwriteMetadata(ofStoreAt: path, at: [0..<4, 32..<40])
}

private func overwriteRecordedSize(ofStoreAt path: String) throws {
  try overwriteMetadata(ofStoreAt: path, at: [28..<36])
}

private func overwriteMetadata(ofStoreAt path: String, at ranges: [Range<Int>]) throws {
  let url = URL(fileURLWithPath: path + ".crc")
  var bytes = [UInt8](try Data(contentsOf: url))
  for index in ranges.joined() {
    bytes[index] = 0xFF
  }
  try Data(bytes).write(to: url)
}
