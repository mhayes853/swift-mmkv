import Foundation
import SwiftMMKV
import Testing

@testable import _SwiftMMKVCore

@Suite struct MemoryFileTests {
  @Test func `A New File Is One Zeroed Page`() throws {
    let path = temporaryFile()
    let file = MemoryFile(path: path, isReadOnly: false, isMayflyFD: true)
    #expect(file.isFileValid == true)
    #expect(file.size == pageSize)
    #expect(try readFile(atPath: path).count == pageSize)
    #expect(try readFile(atPath: path).allSatisfy { $0 == 0 })
  }

  @Test func `The Expected Capacity Rounds Up To Whole Pages`() throws {
    let path = temporaryFile()
    let file = MemoryFile(
      path: path,
      expectedCapacity: pageSize * 2 + 1,
      isReadOnly: false,
      isMayflyFD: true
    )
    #expect(file.size == pageSize * 3)
    #expect(file.actualFileSize == pageSize * 3)
  }

  @Test func `An Existing File Is Rounded Up And Keeps Its Contents`() throws {
    let path = temporaryFile()
    try Data([1, 2, 3]).write(to: URL(fileURLWithPath: path))
    let file = MemoryFile(path: path, isReadOnly: false, isMayflyFD: true)
    #expect(file.size == pageSize)
    let bytes = try readFile(atPath: path)
    #expect(bytes.prefix(3) == [1, 2, 3])
    #expect(bytes.dropFirst(3).allSatisfy { $0 == 0 })

    let larger = temporaryFile()
    try Data(repeating: 7, count: pageSize * 2).write(to: URL(fileURLWithPath: larger))
    #expect(MemoryFile(path: larger, isReadOnly: false, isMayflyFD: true).size == pageSize * 2)
  }

  @Test func `A Read Only File Is Neither Created Nor Resized`() throws {
    let missing = temporaryFile()
    let file = MemoryFile(path: missing, isReadOnly: true, isMayflyFD: true)
    #expect(file.isFileValid == false)
    #expect(!FileManager.default.fileExists(atPath: missing))

    let odd = temporaryFile()
    try Data([1, 2, 3]).write(to: URL(fileURLWithPath: odd))
    var readOnly = MemoryFile(path: odd, isReadOnly: true, isMayflyFD: true)
    #expect(readOnly.isFileValid == true)
    #expect(readOnly.size == 3)
    #expect(readOnly.truncate(to: pageSize) == false)
    #expect(try readFile(atPath: odd) == [1, 2, 3])
  }

  @Test func `Truncating Grows With Zeros And Shrinks To Whole Pages`() throws {
    let path = temporaryFile()
    var file = MemoryFile(path: path, isReadOnly: false, isMayflyFD: true)
    file.memory!.storeBytes(of: 0xab, as: UInt8.self)
    #expect(file.truncate(to: pageSize * 2 + 10) == true)
    #expect(file.size == pageSize * 3)
    #expect(file.memory!.load(as: UInt8.self) == 0xab)
    #expect(
      UnsafeRawBufferPointer(start: file.memory! + 1, count: file.size - 1).allSatisfy { $0 == 0 }
    )

    #expect(file.truncate(to: pageSize) == true)
    #expect(file.size == pageSize)
    #expect(file.actualFileSize == pageSize)
    #expect(file.memory!.load(as: UInt8.self) == 0xab)
  }

  @Test func `Writes Through The Mapping Reach The File`() throws {
    let path = temporaryFile()
    let file = MemoryFile(path: path, isReadOnly: false, isMayflyFD: true)
    for (index, byte) in [UInt8](arrayLiteral: 4, 5, 6).enumerated() {
      file.memory!.storeBytes(of: byte, toByteOffset: index, as: UInt8.self)
    }
    #expect(file.msync(synchronously: true) == true)
    #expect(try readFile(atPath: path).prefix(3) == [4, 5, 6])
  }

  @Test func `A Mayfly File Closes Its Descriptor Once Mapped`() throws {
    let spy = FileSystemSpy()
    let mayfly = MemoryFile(
      path: temporaryFile(),
      isReadOnly: false,
      isMayflyFD: true,
      fileSystem: spy.fileSystem
    )
    #expect(mayfly.isFileValid == true)
    #expect(spy.openDescriptors == 0)

    var kept = MemoryFile(
      path: temporaryFile(),
      isReadOnly: false,
      isMayflyFD: false,
      fileSystem: spy.fileSystem
    )
    #expect(kept.isFileValid == true)
    #expect(spy.openDescriptors == 1)
    kept.clearMemoryCache()
    #expect(spy.openDescriptors == 0)
    #expect(kept.isFileValid == false)
  }

  @Test func `A Failed Resize Keeps The Old Size And Mapping`() throws {
    let spy = FileSystemSpy()
    let path = temporaryFile()
    var file = MemoryFile(
      path: path,
      isReadOnly: false,
      isMayflyFD: true,
      fileSystem: spy.fileSystem
    )
    file.memory!.storeBytes(of: 0xcd, as: UInt8.self)

    spy.failFtruncate = true
    #expect(file.truncate(to: pageSize * 4) == false)
    #expect(file.size == pageSize)
    #expect(file.isFileValid == true)
    #expect(file.memory!.load(as: UInt8.self) == 0xcd)
    spy.failFtruncate = false

    // Zero-filling fails once the file has grown, so it is shrunk back.
    spy.failWrite = true
    #expect(file.truncate(to: pageSize * 4) == false)
    #expect(file.size == pageSize)
    #expect(file.actualFileSize == pageSize)
    spy.failWrite = false

    #expect(file.truncate(to: pageSize * 4) == true)
    #expect(file.size == pageSize * 4)
  }
}

@Suite struct FileLockTests {
  @Test func `Nested Locks Upgrade And Downgrade`() throws {
    let path = temporaryFile()
    let ours = try openFile(path)
    let theirs = try openFile(path)
    defer {
      close(ours)
      close(theirs)
    }
    let lock = FileLock(descriptor: ours)
    let other = FileLock(descriptor: theirs)

    #expect(lock.lock(.shared))
    #expect(lock.lock(.shared))
    #expect(other.tryLock(.shared).locked)
    other.unlock(.shared)
    #expect(other.tryLock(.exclusive) == (false, true))

    // Upgrading excludes even shared holders, and releasing it goes back to shared.
    #expect(lock.lock(.exclusive))
    #expect(other.tryLock(.shared) == (false, true))
    #expect(lock.unlock(.exclusive))
    #expect(other.tryLock(.shared).locked)
    other.unlock(.shared)

    #expect(lock.unlock(.shared))
    #expect(other.tryLock(.exclusive) == (false, true))
    #expect(lock.unlock(.shared))
    #expect(!lock.unlock(.shared))
    #expect(other.tryLock(.exclusive).locked)
    other.unlock(.exclusive)
  }

  @Test func `Destroying Releases Everything`() throws {
    let path = temporaryFile()
    let ours = try openFile(path)
    let theirs = try openFile(path)
    defer {
      close(ours)
      close(theirs)
    }
    let lock = FileLock(descriptor: ours)
    lock.lock(.exclusive)
    lock.lock(.exclusive)
    lock.destroyAndUnlock()
    #expect(!lock.lock(.shared))
    let other = FileLock(descriptor: theirs)
    #expect(other.tryLock(.exclusive).locked)
    other.unlock(.exclusive)
  }

  // The lock must be the same one the C++ core takes on the metadata file, or a store shared
  // with react-native-mmkv would not be protected.
  @Test func `Excludes The C++ Core's Lock On The Metadata File`() throws {
    let root = temporaryDirectory()
    let store = try makeCxxStore(id: "shared", rootDirectory: root, mode: .multiProcess)
    store.set(true, forKey: "key")

    let descriptor = try openFile("\(root)/shared.crc")
    defer { close(descriptor) }
    let lock = FileLock(descriptor: descriptor)
    store.withExclusiveLock { _ in
      #expect(lock.tryLock(.shared) == (false, true))
    }
    #expect(lock.tryLock(.exclusive).locked)
    lock.unlock(.exclusive)
  }
}

@Suite struct ThreadLockTests {
  // Synchronous, so that the test stays on one thread: the lock belongs to the thread that took
  // it, and an async test can resume on another.
  @Test func `Is Recursive On One Thread And Excludes Others`() {
    let lock = ThreadLock()
    lock.lock()
    lock.lock()
    #expect(!onAnotherThread { lock.tryLock() })
    lock.unlock()
    #expect(!onAnotherThread { lock.tryLock() })
    lock.unlock()
    #expect(
      onAnotherThread {
        guard lock.tryLock() else { return false }
        lock.unlock()
        return true
      }
    )
  }
}

@Suite struct StoreLockTests {
  @Test func `Hands Out The State While This Thread Holds The Lock`() {
    let lock = StoreLock(0)
    lock.lock()
    lock.withLock { $0 += 1 }
    lock.withLock { $0 += 1 }
    lock.unlock()
    #expect(lock.withLock { $0 } == 2)
  }

  @Test func `Stops The Process When Reached Again While In Use`() async {
    await #expect(processExitsWith: .failure) {
      let lock = StoreLock(0)
      lock.withLock { _ in
        lock.withLock { $0 += 1 }
      }
    }
  }
}

// MARK: - Support

/// Counts descriptors and fails chosen calls.
private final class FileSystemSpy: @unchecked Sendable {
  private let state = NSLock()
  private var descriptors = Set<Int32>()
  private var shouldFailFtruncate = false
  private var shouldFailWrite = false

  var openDescriptors: Int {
    self.state.withLock { self.descriptors.count }
  }

  var failFtruncate: Bool {
    get { self.state.withLock { self.shouldFailFtruncate } }
    set { self.state.withLock { self.shouldFailFtruncate = newValue } }
  }

  var failWrite: Bool {
    get { self.state.withLock { self.shouldFailWrite } }
    set { self.state.withLock { self.shouldFailWrite = newValue } }
  }

  var fileSystem: FileSystem {
    var fileSystem = FileSystem.live
    let live = FileSystem.live
    fileSystem.open = { path, flags, mode in
      let descriptor = live.open(path, flags, mode)
      if descriptor >= 0 {
        _ = self.state.withLock { self.descriptors.insert(descriptor) }
      }
      return descriptor
    }
    fileSystem.close = { descriptor in
      _ = self.state.withLock { self.descriptors.remove(descriptor) }
      return live.close(descriptor)
    }
    fileSystem.ftruncate = { descriptor, size in
      if self.failFtruncate {
        errno = EIO
        return -1
      }
      return live.ftruncate(descriptor, size)
    }
    fileSystem.write = { descriptor, buffer, count in
      if self.failWrite {
        errno = ENOSPC
        return -1
      }
      return live.write(descriptor, buffer, count)
    }
    return fileSystem
  }
}

private func temporaryFile() -> String {
  temporaryDirectory() + "/file"
}

private struct OpenError: Error {}

private func openFile(_ path: String) throws -> Int32 {
  let descriptor = open(path, O_RDWR | O_CREAT, S_IRWXU)
  guard descriptor >= 0 else { throw OpenError() }
  return descriptor
}
