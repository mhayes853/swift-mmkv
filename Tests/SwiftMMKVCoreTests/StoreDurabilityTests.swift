import Foundation
import Testing

@testable import _SwiftMMKVCore

// What a store keeps when another process writes at the worst moment.
@Suite struct StoreDurabilityTests {
  @Test func `Loading An Empty Store Keeps What Another Process Wrote While It Waited`() {
    let root = temporaryDirectory()
    let other = makeStore(root: root, isMultiProcess: true)
    let interruption = LockInterruption()
    let store = makeStore(root: root, isMultiProcess: true, fileSystem: interruption.fileSystem)

    // The first load finds the store empty and upgrades its lock to say so.
    interruption.whenUpgradeGivesUpTheLock {
      _ = other.set(.int32(42), forKey: "key", expiresInSeconds: 0)
    }
    #expect(store.int32(forKey: "key") == 42)
    #expect(other.int32(forKey: "key") == 42)
    #expect(makeStore(root: root, isMultiProcess: true).int32(forKey: "key") == 42)
  }

  @Test func `Reading An Expired Key Keeps A Value Another Process Wrote While It Waited`()
    async throws
  {
    let root = temporaryDirectory()
    let other = makeStore(root: root, isMultiProcess: true)
    _ = other.set(.int32(1), forKey: "other", expiresInSeconds: 0)
    _ = other.set(.int32(1), forKey: "key", expiresInSeconds: 1)
    let interruption = LockInterruption()
    let store = makeStore(root: root, isMultiProcess: true, fileSystem: interruption.fileSystem)
    #expect(store.count == 2)
    try await Task.sleep(for: .seconds(2))

    // Reading the expired key upgrades the lock to remove it.
    interruption.whenUpgradeGivesUpTheLock {
      _ = other.set(.int32(99), forKey: "key", expiresInSeconds: 0)
    }
    #expect(store.int32(forKey: "key") == 99)
    #expect(other.int32(forKey: "key") == 99)
  }

  @Test func `Counting Keys Keeps What Another Process Wrote Before Expired Keys Are Dropped`()
    async throws
  {
    let root = temporaryDirectory()
    let other = makeStore(root: root, isMultiProcess: true)
    _ = other.set(.int32(1), forKey: "expiring", expiresInSeconds: 1)
    let interruption = LockInterruption()
    let store = makeStore(root: root, isMultiProcess: true, fileSystem: interruption.fileSystem)
    #expect(store.count == 1)
    try await Task.sleep(for: .seconds(2))

    interruption.whenTheLockIsNextReleased {
      _ = other.set(.int32(7), forKey: "fresh", expiresInSeconds: 0)
    }
    #expect(store.count == 1)
    #expect(store.int32(forKey: "fresh") == 7)
    #expect(other.int32(forKey: "fresh") == 7)
  }

  @Test func `Listing Keys Reads Them While Another Process Cannot Move Them`() {
    let root = temporaryDirectory()
    let other = makeStore(root: root, isMultiProcess: true)
    let names = (0..<2_000).map { "key-\($0)" }
    for name in names {
      _ = other.set(.int32(1), forKey: name, expiresInSeconds: 0)
    }
    let interruption = LockInterruption()
    let store = makeStore(root: root, isMultiProcess: true, fileSystem: interruption.fileSystem)
    #expect(store.count == names.count)

    let removed = stride(from: 0, to: names.count, by: 2).map { names[$0] }
    interruption.whenTheLockIsNextReleased { _ = other.removeValues(forKeys: removed) }
    let keys = store.keys
    #expect(Set(keys).isSubset(of: Set(names)))
    #expect(Set(store.keys) == Set(names).subtracting(removed))
    #expect(removed.allSatisfy { !store.contains($0) })
  }

  @Test func `Overwriting A Store's Only Key Keeps Its Old Value Until The Metadata Changes`()
    throws
  {
    let root = temporaryDirectory()
    let store = makeStore(root: root, isMultiProcess: false)
    _ = store.set(.int32(1), forKey: "key", expiresInSeconds: 0)
    store.sync()
    let metadataBefore = try readFile(atPath: "\(root)/store.crc")

    _ = store.set(.int32(2), forKey: "key", expiresInSeconds: 0)
    store.sync()
    #expect(store.int32(forKey: "key") == 2)

    // A process that stops after writing the record and before updating the metadata leaves the
    // new data with the old metadata.
    let stopped = temporaryDirectory()
    try writeFile(try readFile(atPath: "\(root)/store"), atPath: "\(stopped)/store")
    try writeFile(metadataBefore, atPath: "\(stopped)/store.crc")
    #expect(makeStore(root: stopped, isMultiProcess: false).int32(forKey: "key") == 1)
  }

  @Test func `What Was Synced Survives Losing What Was Written Afterwards`() throws {
    let root = temporaryDirectory()
    let store = makeStore(root: root, isMultiProcess: false)
    _ = store.set(.int32(1), forKey: "first", expiresInSeconds: 0)
    _ = store.set(.int32(2), forKey: "second", expiresInSeconds: 0)
    store.sync()
    let syncedData = try readFile(atPath: "\(root)/store")

    _ = store.set(.int32(3), forKey: "third", expiresInSeconds: 0)

    // Power is lost with the metadata on the drive ahead of the data it describes.
    let lost = temporaryDirectory()
    try writeFile(syncedData, atPath: "\(lost)/store")
    try writeFile(try readFile(atPath: "\(root)/store.crc"), atPath: "\(lost)/store.crc")
    let reopened = makeStore(root: lost, isMultiProcess: false)
    #expect(reopened.int32(forKey: "first") == 1)
    #expect(reopened.int32(forKey: "second") == 2)
    #expect(reopened.int32(forKey: "third") == nil)
  }

  @Test(arguments: [false, true])
  func `Syncing Gives The Drive The Data Before The Metadata That Confirms It`(
    isMultiProcess: Bool
  ) throws {
    let root = temporaryDirectory()
    // The size the metadata file recorded as confirmed each time a file was given to the drive.
    let confirmedSizes = LockedValue([UInt32]())
    var fileSystem = FileSystem.live
    fileSystem.flushToDrive = { descriptor in
      if let meta = try? readFile(atPath: "\(root)/store.crc"), meta.count >= MetaInfo.size {
        let info = meta.withUnsafeBytes { MetaInfo(reading: $0.baseAddress!) }
        confirmedSizes.set(confirmedSizes.get() + [info.lastActualSize])
      }
      return FileSystem.live.flushToDrive(descriptor)
    }
    let store = makeStore(root: root, isMultiProcess: isMultiProcess, fileSystem: fileSystem)
    _ = store.set(.int32(1), forKey: "first", expiresInSeconds: 0)
    _ = store.set(.int32(2), forKey: "second", expiresInSeconds: 0)
    #expect(confirmedSizes.get().isEmpty)

    store.sync()
    let sizes = confirmedSizes.get()
    try #require(sizes.count == 2)
    #expect(sizes[0] < sizes[1])
    #expect(sizes[1] == UInt32(store.dataSize))

    // Another process's appends are confirmed too.
    if isMultiProcess {
      let other = makeStore(root: root, isMultiProcess: true)
      _ = other.set(.int32(3), forKey: "third", expiresInSeconds: 0)
      store.sync()
      #expect(confirmedSizes.get().last == UInt32(other.dataSize))
      #expect(confirmedSizes.get().last! > sizes[1])
    }
  }

  @Test func `Clearing Records The Empty Store Before The File Shrinks`() throws {
    let root = temporaryDirectory()
    // The size of the data that the metadata recorded each time the data file was resized.
    let recordedSizes = LockedValue([UInt32]())
    var fileSystem = FileSystem.live
    fileSystem.ftruncate = { descriptor, size in
      if let meta = try? readFile(atPath: "\(root)/store.crc"), meta.count >= MetaInfo.size {
        let info = meta.withUnsafeBytes { MetaInfo(reading: $0.baseAddress!) }
        recordedSizes.set(recordedSizes.get() + [info.actualSize])
      }
      return FileSystem.live.ftruncate(descriptor, size)
    }
    let store = makeStore(root: root, isMultiProcess: false, fileSystem: fileSystem)
    let value = [UInt8](repeating: 1, count: 1_000)
    for index in 0..<100 {
      _ = value.withUnsafeBytes {
        store.set(.bytes($0), forKey: "key-\(index)", expiresInSeconds: 0)
      }
    }
    #expect(store.totalSize > pageSize)

    recordedSizes.set([])
    store.clearAll()
    #expect(store.totalSize == pageSize)
    #expect(recordedSizes.get() == [0])
  }
}

private func makeStore(
  root: String,
  isMultiProcess: Bool,
  fileSystem: FileSystem = .live
) -> StoreInstance {
  StoreInstance(
    StoreConfiguration(
      id: "store",
      rootDirectory: root,
      isMultiProcess: isMultiProcess,
      fileSystem: fileSystem
    ),
    root: root
  )
}

/// A file system whose `flock` lets a test act as another process at the moments a store's file
/// lock is not held.
private final class LockInterruption: Sendable {
  private struct State {
    var failsNextUpgrade = false
    var onUnlock: (@Sendable () -> Void)?
  }

  private let state = LockedValue(State())

  var fileSystem: FileSystem {
    var fileSystem = FileSystem.live
    fileSystem.flock = { descriptor, operation in
      if operation == LOCK_EX | LOCK_NB, self.takeUpgradeFailure() {
        // Another process holds the lock, so the upgrade gives up the shared lock and waits.
        errno = EWOULDBLOCK
        return -1
      }
      let result = FileSystem.live.flock(descriptor, operation)
      if operation == LOCK_UN, !self.state.get().failsNextUpgrade {
        self.takeOnUnlock()?()
      }
      return result
    }
    return fileSystem
  }

  /// Runs `body` once the store next gives up a shared lock to take the exclusive one.
  func whenUpgradeGivesUpTheLock(_ body: @escaping @Sendable () -> Void) {
    self.state.set(State(failsNextUpgrade: true, onUnlock: body))
  }

  /// Runs `body` once the store next releases its file lock.
  func whenTheLockIsNextReleased(_ body: @escaping @Sendable () -> Void) {
    self.state.set(State(onUnlock: body))
  }

  private func takeUpgradeFailure() -> Bool {
    var state = self.state.get()
    defer { self.state.set(state) }
    let fails = state.failsNextUpgrade
    state.failsNextUpgrade = false
    return fails
  }

  private func takeOnUnlock() -> (@Sendable () -> Void)? {
    var state = self.state.get()
    defer { self.state.set(state) }
    let body = state.onUnlock
    state.onUnlock = nil
    return body
  }
}
