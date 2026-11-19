import Foundation
@_spi(Engines) import SwiftMMKV

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Android)
  import Android
#endif

// Reports how much memory each core uses for an open store. package-benchmark measures time and
// counts allocations, but not how many bytes stay allocated, so this is a tool of its own.
//
// Every measurement runs in a child process of its own, so that what one case allocates, and the
// high-water mark of the heap, never carry over into another. Run with
// `swift run -c release MemoryReport` from the Benchmarks directory; see README.md.

@main
struct MemoryReport {
  static func main() throws {
    let arguments = CommandLine.arguments
    if arguments.count > 1, arguments[1] == "measure" {
      let measurement = try Case(arguments: Array(arguments.dropFirst(2))).measure()
      print(measurement.encoded)
    } else {
      try Self.report(
        keyCounts: arguments.count > 1 ? arguments.dropFirst().compactMap { Int($0) } : nil
      )
    }
  }

  private static func report(keyCounts: [Int]?) throws {
    let keyCounts = keyCounts ?? [10_000, 100_000]
    print(
      "| Case | Heap retained | Per key | Live allocations | Footprint after open "
        + "| Footprint after trim | Peak footprint |"
    )
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for keyCount in keyCounts {
      for scenario in Scenario.allCases {
        for engine in MMKVConfiguration.Engine.allCases {
          let template = try Case.makeTemplate(
            engine: engine,
            scenario: scenario,
            keyCount: keyCount
          )
          let measurement = try Self.runChild(
            Case(engine: engine, scenario: scenario, keyCount: keyCount, template: template)
          )
          try? FileManager.default.removeItem(atPath: template)
          print(
            "| \(scenario.rawValue), \(keyCount) keys/\(engine) "
              + "| \(kilobytes(measurement.heapRetained)) "
              + "| \(measurement.heapRetained / keyCount) B "
              + "| \(measurement.liveAllocations.map(String.init) ?? "–") "
              + "| \(kilobytes(measurement.footprintAfterOpen)) "
              + "| \(kilobytes(measurement.footprintAfterTrim)) "
              + "| \(measurement.peakFootprint.map(kilobytes) ?? "–") |"
          )
        }
      }
    }
    print()
    print(
      """
      Each case opens a store and loads it, then trims it, which rewrites the whole file. \
      Heap retained and live allocations are measured after loading. Footprints are relative to \
      before opening, and the peak covers both opening and trimming. Footprint is \
      \(footprintName).
      """
    )
  }

  private static func runChild(_ measuredCase: Case) throws -> Measurement {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["measure"] + measuredCase.arguments
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
      let line = String(data: data, encoding: .utf8)?.split(separator: "\n").last,
      let measurement = Measurement(encoded: String(line))
    else {
      throw ReportError.childFailed(measuredCase.arguments)
    }
    return measurement
  }
}

enum ReportError: Error {
  case childFailed([String])
  case badArguments([String])
}

enum Scenario: String, CaseIterable {
  case plain
  case encrypted

  var encryption: MMKVConfiguration.Encryption? {
    switch self {
    case .plain: nil
    case .encrypted: .aes128(key: "memory-report")
    }
  }
}

/// One store to measure: a copy of `template`, a directory holding a store of `keyCount` strings
/// written by `engine`.
struct Case {
  var engine: MMKVConfiguration.Engine
  var scenario: Scenario
  var keyCount: Int
  var template: String

  init(engine: MMKVConfiguration.Engine, scenario: Scenario, keyCount: Int, template: String) {
    self.engine = engine
    self.scenario = scenario
    self.keyCount = keyCount
    self.template = template
  }

  init(arguments: [String]) throws {
    guard arguments.count == 4,
      let engine = MMKVConfiguration.Engine(rawValue: arguments[0]),
      let scenario = Scenario(rawValue: arguments[1]),
      let keyCount = Int(arguments[2])
    else {
      throw ReportError.badArguments(arguments)
    }
    self.init(engine: engine, scenario: scenario, keyCount: keyCount, template: arguments[3])
  }

  var arguments: [String] {
    [self.engine.rawValue, self.scenario.rawValue, String(self.keyCount), self.template]
  }

  static func makeTemplate(
    engine: MMKVConfiguration.Engine,
    scenario: Scenario,
    keyCount: Int
  ) throws -> String {
    let directory = temporaryDirectory()
    let store = try openStore(
      engine: engine,
      directory: directory,
      encryption: scenario.encryption
    )
    for index in 0..<keyCount {
      store.set(value(index), forKey: key(index))
    }
    store.sync()
    return directory
  }

  /// Opens a copy of the template and loads it, measuring what that leaves allocated, then trims
  /// it, which rewrites the whole file, measuring the heap's high-water mark.
  func measure() throws -> Measurement {
    let directory = temporaryDirectory()
    for file in ["store", "store.crc"] {
      try FileManager.default.copyItem(
        atPath: "\(self.template)/\(file)",
        toPath: "\(directory)/\(file)"
      )
      // Written back, so that the copy's pages are clean. Linux counts the dirty pages of a file
      // that only this process maps as its private dirty memory.
      let handle = FileHandle(forUpdatingAtPath: "\(directory)/\(file)")
      try handle?.synchronize()
      try handle?.close()
    }
    // Opening another store first leaves out what the first open of any store allocates once,
    // such as the core's global state and the runtime's type metadata.
    let warmUp = try openStore(
      engine: self.engine,
      id: "warm-up",
      directory: temporaryDirectory(),
      encryption: self.scenario.encryption
    )
    warmUp.set(value(0), forKey: key(0))
    _ = warmUp.count

    let before = Snapshot()
    let store = try openStore(
      engine: self.engine,
      directory: directory,
      encryption: self.scenario.encryption
    )
    guard store.count == self.keyCount else { throw ReportError.childFailed(self.arguments) }
    let afterOpen = Snapshot()
    store.trim()
    let afterTrim = Snapshot()

    try? FileManager.default.removeItem(atPath: directory)
    return Measurement(
      heapRetained: afterOpen.heapInUse - before.heapInUse,
      liveAllocations: afterOpen.allocations.flatMap { a in before.allocations.map { a - $0 } },
      footprintAfterOpen: afterOpen.footprint - before.footprint,
      footprintAfterTrim: afterTrim.footprint - before.footprint,
      peakFootprint: afterTrim.peakFootprint.map { $0 - before.footprint }
    )
  }
}

struct Measurement {
  var heapRetained: Int
  var liveAllocations: Int?
  var footprintAfterOpen: Int
  var footprintAfterTrim: Int
  var peakFootprint: Int?

  var encoded: String {
    [
      self.heapRetained, self.liveAllocations, self.footprintAfterOpen, self.footprintAfterTrim,
      self.peakFootprint
    ]
    .map { $0.map(String.init) ?? "-" }
    .joined(separator: " ")
  }

  init(
    heapRetained: Int,
    liveAllocations: Int?,
    footprintAfterOpen: Int,
    footprintAfterTrim: Int,
    peakFootprint: Int?
  ) {
    self.heapRetained = heapRetained
    self.liveAllocations = liveAllocations
    self.footprintAfterOpen = footprintAfterOpen
    self.footprintAfterTrim = footprintAfterTrim
    self.peakFootprint = peakFootprint
  }

  init?(encoded: String) {
    let fields = encoded.split(separator: " ").map { Int($0) }
    guard fields.count == 5, let heap = fields[0], let open = fields[2], let trim = fields[3]
    else { return nil }
    self.init(
      heapRetained: heap,
      liveAllocations: fields[1],
      footprintAfterOpen: open,
      footprintAfterTrim: trim,
      peakFootprint: fields[4]
    )
  }
}

// MARK: - Measuring the process

/// The heap and the process's memory at one moment.
struct Snapshot {
  var heapInUse: Int
  var footprint: Int
  /// The most the footprint has ever been, which only Darwin records.
  var peakFootprint: Int?
  var allocations: Int?

  init() {
    #if canImport(Darwin)
      var statistics = malloc_statistics_t()
      malloc_zone_statistics(nil, &statistics)
      self.heapInUse = Int(statistics.size_in_use)
      self.allocations = Int(statistics.blocks_in_use)
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
      )
      let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
      }
      self.footprint = result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
      self.peakFootprint = result == KERN_SUCCESS ? Int(info.ledger_phys_footprint_peak) : nil
    #else
      #if canImport(Glibc)
        // glibc counts blocks it maps on their own separately from the rest of the heap.
        let info = mallinfo2()
        self.heapInUse = Int(info.uordblks) + Int(info.hblkhd)
      #else
        // Android's allocators count every allocated byte in `uordblks`, and every mapped one in
        // `hblkhd`.
        let info = mallinfo()
        self.heapInUse = Int(info.uordblks)
      #endif
      self.peakFootprint = nil
      self.allocations = nil
      self.footprint = Self.privateDirtyAndAnonymous()
    #endif
  }

  #if !canImport(Darwin)
    /// The process's private dirty memory, from `/proc/self/smaps_rollup`, which is what the
    /// kernel cannot reclaim without swapping. Android's `dumpsys meminfo` reports the same.
    private static func privateDirtyAndAnonymous() -> Int {
      guard let contents = try? String(contentsOfFile: "/proc/self/smaps_rollup", encoding: .utf8)
      else { return 0 }
      for line in contents.split(separator: "\n") where line.hasPrefix("Private_Dirty:") {
        let kilobytes = line.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        return kilobytes * 1024
      }
      return 0
    }
  #endif
}

#if canImport(Darwin)
  private let footprintName =
    "the change in `phys_footprint`, what iOS counts against an app's memory limit"
#else
  private let footprintName =
    "the change in private dirty memory, from `/proc/self/smaps_rollup`"
#endif

// MARK: - Support

private func key(_ index: Int) -> String {
  "key-\(index)"
}

private func value(_ index: Int) -> String {
  "a string value that is not very long, number \(index)"
}

private func kilobytes(_ bytes: Int) -> String {
  "\((bytes + 512) / 1024) KB"
}

private func temporaryDirectory() -> String {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("swift-mmkv-memory-report")
    .appendingPathComponent(UUID().uuidString)
  try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory.path
}

private func openStore(
  engine: MMKVConfiguration.Engine,
  id: MMKVStore.ID = "store",
  directory: String,
  encryption: MMKVConfiguration.Encryption?
) throws -> MMKVStore {
  var configuration = MMKVConfiguration(
    id: id,
    directory: MMKVDirectory(path: directory),
    mode: .singleProcess,
    encryption: encryption
  )
  configuration.engine = engine
  return try MMKVStore(configuration)
}
