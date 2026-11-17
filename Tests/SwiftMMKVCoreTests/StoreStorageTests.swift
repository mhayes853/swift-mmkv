import CSwiftMMKVCore
import Foundation
import Testing

@testable import _SwiftMMKVCore

// The Swift core's operations on a store's files, compared with the C++ core's on the same files.
@Suite(.serialized) struct StoreStorageTests {
  private enum Files: CaseIterable {
    case none, dataOnly, metaOnly, both
  }

  @Test(arguments: Files.allCases, ["plain", "with/slash"])
  private func `Existence Matches The C++ Core`(files: Files, id: String) throws {
    let root = try makeFiles(files, id: id)
    #expect(StoreStorage.exists(id: id, rootDirectory: root) == cxxExists(id: id, root: root))
    #expect(StoreStorage.exists(id: id, rootDirectory: root) == (files == .both))
  }

  @Test(arguments: Files.allCases, ["plain", "with/slash"])
  private func `Removal Matches The C++ Core`(files: Files, id: String) throws {
    let swiftRoot = try makeFiles(files, id: id)
    let cxxRoot = try makeFiles(files, id: id)
    #expect(StoreStorage.remove(id: id, rootDirectory: swiftRoot) == cxxRemove(id: id, root: cxxRoot))
    for root in [swiftRoot, cxxRoot] {
      let dataPath = StorePaths.dataPath(id: id, root: StorePaths.normalizedRoot(root))
      #expect(!FileManager.default.fileExists(atPath: dataPath))
      #expect(!FileManager.default.fileExists(atPath: dataPath + ".crc"))
    }
  }

  // Synchronous, with the removal on a thread of its own: removing holds the registry's lock
  // while it waits for the file lock, as the C++ core does, which would starve Swift
  // concurrency's threads.
  @Test func `Removal Waits For Another Holder Of The File Lock`() throws {
    let root = try makeFiles(.both, id: "locked")
    let metaPath = StorePaths.dataPath(id: "locked", root: StorePaths.normalizedRoot(root)) + ".crc"
    let descriptor = open(metaPath, O_RDONLY)
    defer { close(descriptor) }
    let otherLock = FileLock(descriptor: descriptor)
    otherLock.lock(.shared)
    let done = DispatchSemaphore(value: 0)
    let removed = RemovalResult()
    Thread {
      removed.value = StoreStorage.remove(id: "locked", rootDirectory: root)
      done.signal()
    }
    .start()
    #expect(done.wait(timeout: .now() + .milliseconds(300)) == .timedOut)
    #expect(FileManager.default.fileExists(atPath: metaPath))
    otherLock.unlock(.shared)
    done.wait()
    #expect(removed.value)
    #expect(!FileManager.default.fileExists(atPath: metaPath))
  }

  private func makeFiles(_ files: Files, id: String) throws -> String {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("swift-mmkv-core-tests")
      .appendingPathComponent(UUID().uuidString).path
    let dataPath = StorePaths.dataPath(id: id, root: root)
    try FileManager.default.createDirectory(
      atPath: (dataPath as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true
    )
    if files == .dataOnly || files == .both {
      try Data(repeating: 0, count: 4_096).write(to: URL(fileURLWithPath: dataPath))
    }
    if files == .metaOnly || files == .both {
      try Data(repeating: 0, count: 4_096).write(to: URL(fileURLWithPath: dataPath + ".crc"))
    }
    return root
  }

  private func cxxExists(id: String, root: String) -> Bool {
    withBytes(id) { id in withBytes(root) { mmkv_storage_exists(id, $0) } }
  }

  private func cxxRemove(id: String, root: String) -> Bool {
    withBytes(id) { id in withBytes(root) { mmkv_remove_storage(id, $0) } }
  }

  private func withBytes<R>(_ string: String, _ body: (mmkv_bytes) -> R) -> R {
    var string = string
    return string.withUTF8 { body(mmkv_bytes(bytes: $0.baseAddress, count: $0.count)) }
  }
}

private final class RemovalResult: @unchecked Sendable {
  var value = false
}
