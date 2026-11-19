import Foundation
@_spi(Engines) import SwiftMMKV

/// A directory that is unique to one test.
func temporaryDirectory() -> String {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("swift-mmkv-core-tests")
    .appendingPathComponent(UUID().uuidString)
  try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory.path
}

func readFile(atPath path: String) throws -> [UInt8] {
  Array(try Data(contentsOf: URL(fileURLWithPath: path)))
}

/// Opens a store with the C++ core, whatever the tests' engine.
func makeCxxStore(
  id: MMKVStore.ID,
  rootDirectory: String,
  mode: MMKVConfiguration.Mode = .singleProcess
) throws -> MMKVStore {
  var configuration = MMKVConfiguration(
    id: id,
    directory: MMKVDirectory(path: rootDirectory),
    mode: mode
  )
  configuration.engine = .cxx
  return try MMKVStore(configuration)
}

/// Runs `body` on a new thread and waits for its result.
func onAnotherThread<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T {
  let result = LockedValue<T?>(nil)
  let done = DispatchSemaphore(value: 0)
  Thread {
    result.set(body())
    done.signal()
  }
  .start()
  done.wait()
  return result.get()!
}

/// A value that threads share under a lock.
final class LockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func get() -> Value {
    self.lock.withLock { self.value }
  }

  func set(_ value: Value) {
    self.lock.withLock { self.value = value }
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
