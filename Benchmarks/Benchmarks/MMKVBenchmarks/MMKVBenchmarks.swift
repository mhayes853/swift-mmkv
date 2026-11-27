import Benchmark
import Foundation
@_spi(Engines) import SwiftMMKV

// Every scenario is registered once per engine, as `<scenario>/<engine>`, so one run compares the
// C++ core with the Swift core. An engine that cannot open a store yet is left out.
//
// Stores stay open for the rest of the process, so every benchmark opens its stores once, in its
// setup, except the ones that measure opening.

let benchmarks: @Sendable () -> Void = {
  Benchmark.defaultConfiguration = .init(
    metrics: [.wallClock, .throughput, .mallocCountTotal],
    maxDuration: .seconds(2),
    maxIterations: 10_000
  )

  for engine in availableEngines {
    registerValueBenchmarks(engine)
    registerOpenBenchmarks(engine)
    registerReloadBenchmarks(engine)
  }
}

// MARK: - Reads and writes

/// Upstream's `MMKVPerformanceTest.mm` writes and reads 10,000 keys. Here each iteration is
/// 1,000 operations over the same 10,000 keys, and results are per operation.
private func registerValueBenchmarks(_ engine: MMKVConfiguration.Engine) {
  let perOperation = Benchmark.Configuration(scalingFactor: .kilo)

  let int32Writes = Fixture<MMKVStore>()
  Benchmark("write.int32/\(engine)", configuration: perOperation) { benchmark in
    for _ in benchmark.scaledIterations {
      let index = int32Writes.next()
      int32Writes.value.set(Int32(index), forKey: keys[index])
    }
  } setup: {
    int32Writes.value = try openStore(engine: engine)
  }

  // A store with one key. The C++ core rewrites it in place; the Swift core appends, and compacts
  // the file each time it fills.
  let singleKeyWrites = Fixture<MMKVStore>()
  Benchmark("write.int32.singleKey/\(engine)", configuration: perOperation) { benchmark in
    for _ in benchmark.scaledIterations {
      singleKeyWrites.value.set(Int32(singleKeyWrites.next()), forKey: keys[0])
    }
  } setup: {
    singleKeyWrites.value = try openStore(engine: engine)
  }

  let int32Reads = Fixture<MMKVStore>()
  Benchmark("read.int32/\(engine)", configuration: perOperation) { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(int32Reads.value.value(forKey: keys[int32Reads.next()], as: Int32.self))
    }
  } setup: {
    int32Reads.value = try openStore(engine: engine) { store, index in
      store.set(Int32(index), forKey: keys[index])
    }
  }

  let stringWrites = Fixture<MMKVStore>()
  Benchmark("write.string/\(engine)", configuration: perOperation) { benchmark in
    for _ in benchmark.scaledIterations {
      let index = stringWrites.next()
      stringWrites.value.set(strings[index], forKey: keys[index])
    }
  } setup: {
    stringWrites.value = try openStore(engine: engine)
  }

  let encryptedStringWrites = Fixture<MMKVStore>()
  Benchmark("write.string.encrypted/\(engine)", configuration: perOperation) { benchmark in
    for _ in benchmark.scaledIterations {
      let index = encryptedStringWrites.next()
      encryptedStringWrites.value.set(strings[index], forKey: keys[index])
    }
  } setup: {
    encryptedStringWrites.value = try openStore(
      engine: engine,
      encryption: .aes128(key: "benchmark-key")
    )
  }

  // Upstream's `testGetStringSpeed` in `demo.cpp` measures the same read.
  let stringReads = Fixture<MMKVStore>()
  Benchmark("read.string/\(engine)", configuration: perOperation) { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(stringReads.value.value(forKey: keys[stringReads.next()], as: String.self))
    }
  } setup: {
    stringReads.value = try openStore(engine: engine, fill: setString)
  }

  // Every operation on a multi-process store takes the file lock and checks the metadata file.
  let multiProcessReads = Fixture<MMKVStore>()
  Benchmark("read.string.multiProcess/\(engine)", configuration: perOperation) { benchmark in
    for _ in benchmark.scaledIterations {
      let index = multiProcessReads.next()
      blackHole(multiProcessReads.value.value(forKey: keys[index], as: String.self))
    }
  } setup: {
    multiProcessReads.value = try openStore(engine: engine, mode: .multiProcess, fill: setString)
  }

  let multiProcessWrites = Fixture<MMKVStore>()
  Benchmark("write.string.multiProcess/\(engine)", configuration: perOperation) { benchmark in
    for _ in benchmark.scaledIterations {
      let index = multiProcessWrites.next()
      multiProcessWrites.value.set(strings[index], forKey: keys[index])
    }
  } setup: {
    multiProcessWrites.value = try openStore(engine: engine, mode: .multiProcess)
  }

  // Overwriting a few keys over and over fills the file with stale values, so it is compacted
  // regularly.
  let overwrites = Fixture<MMKVStore>()
  Benchmark("write.double.overwrite/\(engine)", configuration: perOperation) { benchmark in
    for _ in benchmark.scaledIterations {
      let index = overwrites.next()
      overwrites.value.set(Double(index), forKey: keys[index % 100])
    }
  } setup: {
    overwrites.value = try openStore(engine: engine)
  }

  let enumeration = Fixture<MMKVStore>()
  Benchmark("keys/\(engine)") { benchmark in
    blackHole(enumeration.value.keys)
  } setup: {
    enumeration.value = try openStore(engine: engine, fill: setString)
  }
}

// MARK: - Opening

/// Opening a store reads its whole file. Each iteration opens a fresh copy of a store holding
/// 10,000 strings, because a store that is already open is not loaded again.
private func registerOpenBenchmarks(_ engine: MMKVConfiguration.Engine) {
  let configuration = Benchmark.Configuration(maxIterations: 200)
  let cases: [(name: String, encryption: MMKVConfiguration.Encryption?)] = [
    ("open.plain", nil),
    ("open.encrypted", .aes128(key: "benchmark-key"))
  ]
  for (name, encryption) in cases {
    let template = Fixture<String>()
    Benchmark("\(name)/\(engine)", configuration: configuration) { benchmark in
      let copy = temporaryDirectory()
      for file in ["store", "store.crc"] {
        try FileManager.default.copyItem(
          atPath: "\(template.value!)/\(file)",
          toPath: "\(copy)/\(file)"
        )
      }
      benchmark.startMeasurement()
      let store = try openStore(engine: engine, rootDirectory: copy, encryption: encryption)
      blackHole(store.count)
      benchmark.stopMeasurement()
    } setup: {
      let directory = temporaryDirectory()
      let store = try openStore(
        engine: engine,
        rootDirectory: directory,
        encryption: encryption,
        fill: setString
      )
      store.sync()
      template.value = directory
    }
  }
}

// MARK: - Reloading

/// Two instances over the same files stand in for two processes. The writer changes the file,
/// and the measurement is the reader's next operation, which notices the change and reloads.
private func registerReloadBenchmarks(_ engine: MMKVConfiguration.Engine) {
  // The writer appends one value, so the reader only reads what was appended.
  let append = Fixture<(reader: MMKVStore, writer: MMKVStore)>()
  Benchmark("reload.append/\(engine)") { benchmark in
    let index = append.next()
    append.value.writer.set(Double(index), forKey: keys[index % 10])
    benchmark.startMeasurement()
    blackHole(append.value.reader.value(forKey: keys[index % 10], as: Double.self))
    benchmark.stopMeasurement()
  } setup: {
    append.value = try openLinkedStores(engine: engine)
  }

  // The writer clears the file and writes 1,000 values, so the reader reloads all of them.
  let full = Fixture<(reader: MMKVStore, writer: MMKVStore)>()
  Benchmark("reload.full/\(engine)", configuration: .init(maxIterations: 1_000)) { benchmark in
    full.value.writer.removeAll(keepingCapacity: true)
    for index in 0..<1_000 {
      full.value.writer.set(strings[index], forKey: keys[index])
    }
    benchmark.startMeasurement()
    blackHole(full.value.reader.count)
    benchmark.stopMeasurement()
  } setup: {
    full.value = try openLinkedStores(engine: engine)
  }
}

// MARK: - Support

private let keyCount = 10_000
private let keys = (0..<keyCount).map { "key-\($0)" }
private let strings = (0..<keyCount).map { "a string value that is not very long, number \($0)" }

/// Writes the string for one key, to fill a store with every key.
private func setString(in store: MMKVStore, at index: Int) {
  store.set(strings[index], forKey: keys[index])
}

/// Holds what a benchmark's setup prepares for its closure, and a counter that cycles through
/// the keys.
private final class Fixture<Value>: @unchecked Sendable {
  var value: Value!
  private var counter = 0

  func next() -> Int {
    defer { self.counter = (self.counter + 1) % keyCount }
    return self.counter
  }
}

private let availableEngines = MMKVConfiguration.Engine.allCases.filter { engine in
  (try? openStore(engine: engine)) != nil
}

private func temporaryDirectory() -> String {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("swift-mmkv-benchmarks")
    .appendingPathComponent(UUID().uuidString)
  try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory.path
}

/// Opens a store, and writes every key with `fill` when one is given.
private func openStore(
  engine: MMKVConfiguration.Engine,
  id: MMKVStore.ID = "store",
  rootDirectory: String = temporaryDirectory(),
  mode: MMKVConfiguration.Mode = .singleProcess,
  encryption: MMKVConfiguration.Encryption? = nil,
  fill: ((MMKVStore, Int) -> Void)? = nil
) throws -> MMKVStore {
  var configuration = MMKVConfiguration(
    id: id,
    directory: MMKVDirectory(path: rootDirectory),
    mode: mode,
    encryption: encryption
  )
  configuration.engine = engine
  let store = try MMKVStore(configuration)
  if let fill {
    for index in 0..<keyCount {
      fill(store, index)
    }
  }
  return store
}

/// Opens one pair of files under two identifiers, the second being hard links to the first, so
/// that each gets an instance of its own, as two processes would.
private func openLinkedStores(
  engine: MMKVConfiguration.Engine
) throws -> (reader: MMKVStore, writer: MMKVStore) {
  let directory = temporaryDirectory()
  let writer = try openStore(
    engine: engine,
    id: "writer",
    rootDirectory: directory,
    mode: .multiProcess
  )
  _ = writer.count
  for suffix in ["", ".crc"] {
    try FileManager.default.linkItem(
      atPath: "\(directory)/writer\(suffix)",
      toPath: "\(directory)/reader\(suffix)"
    )
  }
  let reader = try openStore(
    engine: engine,
    id: "reader",
    rootDirectory: directory,
    mode: .multiProcess
  )
  return (reader, writer)
}
