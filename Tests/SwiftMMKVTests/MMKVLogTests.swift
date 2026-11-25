import CSwiftMMKV
import Foundation
import SwiftMMKV
import Testing

#if Logging
  import Logging
#endif

/// Logging is shared by the whole process, so every test that changes it lives in this suite
/// and runs one at a time. Other suites log while these run, so each test only looks at the
/// messages about a store it made.
@Suite(.serialized) struct MMKVLogTests {
  @Test func `Starts At The Warning Level And Remembers A New One`() {
    defer { MMKVLog.minimumLevel = .warning }
    #expect(MMKVLog.minimumLevel == .warning)

    MMKVLog.minimumLevel = .info
    #expect(MMKVLog.minimumLevel == .info)

    MMKVLog.minimumLevel = nil
    #expect(MMKVLog.minimumLevel == nil)

    MMKVLog.minimumLevel = .error
    #expect(MMKVLog.minimumLevel == .error)
  }

  @Test func `Levels Are Ordered By Severity`() {
    #expect(MMKVLog.Level.info < .warning)
    #expect(MMKVLog.Level.warning < .error)
    #expect(MMKVLog.Level.allCases.map(\.description) == ["info", "warning", "error"])
  }

  @Test(.requires(.logging)) func `The Handler Receives Messages At Or Above The Minimum Level`()
    throws
  {
    defer { resetLogging() }
    let recorder = ValueRecorder<MMKVLog.Message>()
    MMKVLog.minimumLevel = .info
    MMKVLog.setHandler(recorder.record)

    let id = uniqueStoreID()
    _ = try makeStore(id: id)

    let messages = recorder.all.filter { $0.text.contains(id.rawValue) }
    let message = try #require(messages.first)
    #expect(message.level == .info)
    #expect(message.file.hasSuffix(".cpp"))
    #expect(!message.function.isEmpty)
    #expect(message.line > 0)
  }

  @Test(.requires(.logging)) func `Messages Below The Minimum Level Are Dropped`() throws {
    defer { resetLogging() }
    let recorder = ValueRecorder<MMKVLog.Message>()
    MMKVLog.minimumLevel = .warning
    MMKVLog.setHandler(recorder.record)

    let id = uniqueStoreID()
    _ = try makeStore(id: id)

    #expect(!recorder.all.contains { $0.text.contains(id.rawValue) })
  }

  @Test(.requires(.logging)) func `Nothing Is Logged Without A Minimum Level`() throws {
    defer { resetLogging() }
    let recorder = ValueRecorder<MMKVLog.Message>()
    MMKVLog.minimumLevel = nil
    MMKVLog.setHandler(recorder.record)

    _ = try makeStore(id: uniqueStoreID())

    #expect(recorder.all.isEmpty)
  }

  @Test(.requires(.logging)) func `A Removed Handler No Longer Receives Messages`() throws {
    defer { resetLogging() }
    let recorder = ValueRecorder<MMKVLog.Message>()
    MMKVLog.minimumLevel = .info
    MMKVLog.setHandler(recorder.record)
    MMKVLog.setHandler(nil)
    MMKVLog.minimumLevel = .warning

    let id = uniqueStoreID()
    _ = try makeStore(id: id)

    #expect(!recorder.all.contains { $0.text.contains(id.rawValue) })
  }

  #if Logging
    @Test(.requires(.logging)) func `Messages Go To The Logger`() throws {
      defer { resetLogging() }
      let recorder = ValueRecorder<RecordingLogHandler.Entry>()
      var logger = Logger(label: "test") { _ in RecordingLogHandler(recorder: recorder) }
      logger.logLevel = .info
      MMKVLog.logger = logger

      let id = uniqueStoreID()
      _ = try makeStore(id: id)

      let entry = try #require(recorder.all.first { $0.message.contains(id.rawValue) })
      #expect(entry.level == .info)
      #expect(entry.source == "MMKV")
      #expect(entry.file.hasSuffix(".cpp"))
      #expect(!entry.function.isEmpty)
      #expect(entry.line > 0)
    }

    @Test func `Setting The Logger Sets The Minimum Level To Match`() {
      defer { resetLogging() }
      MMKVLog.logger.logLevel = .error
      #expect(MMKVLog.minimumLevel == .error)

      MMKVLog.logger.logLevel = .debug
      #expect(MMKVLog.minimumLevel == .info)

      var logger = Logger(label: "test")
      logger.logLevel = .warning
      MMKVLog.logger = logger
      #expect(MMKVLog.minimumLevel == .warning)
      #expect(MMKVLog.logger.label == "test")
    }

    @Test(.requires(.logging)) func `The Minimum Level Can Be Stricter Than The Logger`() throws {
      defer { resetLogging() }
      let recorder = ValueRecorder<RecordingLogHandler.Entry>()
      var logger = Logger(label: "test") { _ in RecordingLogHandler(recorder: recorder) }
      logger.logLevel = .trace
      MMKVLog.logger = logger
      MMKVLog.minimumLevel = .warning

      let id = uniqueStoreID()
      _ = try makeStore(id: id)

      #expect(!recorder.all.contains { $0.message.contains(id.rawValue) })
    }

    @Test(.requires(.logging)) func `A Handler Takes Over From The Logger Until It Is Removed`()
      throws
    {
      defer { resetLogging() }
      let logged = ValueRecorder<RecordingLogHandler.Entry>()
      let handled = ValueRecorder<MMKVLog.Message>()
      var logger = Logger(label: "test") { _ in RecordingLogHandler(recorder: logged) }
      logger.logLevel = .info
      MMKVLog.logger = logger

      MMKVLog.setHandler(handled.record)
      let first = uniqueStoreID()
      _ = try makeStore(id: first)
      MMKVLog.setHandler(nil)
      let second = uniqueStoreID()
      _ = try makeStore(id: second)

      #expect(handled.all.contains { $0.text.contains(first.rawValue) })
      #expect(!logged.all.contains { $0.message.contains(first.rawValue) })
      #expect(!handled.all.contains { $0.text.contains(second.rawValue) })
      #expect(logged.all.contains { $0.message.contains(second.rawValue) })
    }

    @Test func `Levels Convert To And From Those Of A Logger`() {
      #expect(MMKVLog.Level.allCases.map(Logger.Level.init) == [.info, .warning, .error])
      #expect(
        Logger.Level.allCases.map(MMKVLog.Level.init)
          == [.info, .info, .info, .info, .warning, .error, .error]
      )
    }
  #endif
}

// MARK: - C Interface

extension MMKVLogTests {
  @Test func `The C Interface Reads And Sets The Minimum Level`() {
    defer { resetLogging() }
    #expect(swiftmmkv_log_minimum_level() == SWIFTMMKV_LOG_WARNING)

    swiftmmkv_log_set_minimum_level(SWIFTMMKV_LOG_INFO)
    #expect(swiftmmkv_log_minimum_level() == SWIFTMMKV_LOG_INFO)
    #expect(MMKVLog.minimumLevel == .info)

    swiftmmkv_log_set_minimum_level(SWIFTMMKV_LOG_NONE)
    #expect(swiftmmkv_log_minimum_level() == SWIFTMMKV_LOG_NONE)
    #expect(MMKVLog.minimumLevel == nil)

    swiftmmkv_log_set_minimum_level(SWIFTMMKV_LOG_ERROR)
    swiftmmkv_log_set_minimum_level(99)
    #expect(swiftmmkv_log_minimum_level() == SWIFTMMKV_LOG_ERROR)
  }

  @Test(.requires(.logging, .cInterface))
  func `The C Interface's Handler Receives Messages Until It Is Replaced`() throws {
    defer { resetLogging() }
    let first = CCallbackRecorder()
    let second = CCallbackRecorder()
    swiftmmkv_log_set_minimum_level(SWIFTMMKV_LOG_INFO)
    swiftmmkv_log_set_handler(first.context, CCallbackRecorder.onLog, CCallbackRecorder.release)

    let firstID = uniqueStoreID()
    _ = try makeStore(id: firstID)

    let message = try #require(first.events.first { $0.contains(firstID.rawValue) })
    let fields = message.split(separator: " ", maxSplits: 3)
    #expect(fields[0] == "\(SWIFTMMKV_LOG_INFO)")
    #expect(fields[1].contains(".cpp:"))
    #expect(!fields[2].isEmpty)
    #expect(first.releases == 0)

    swiftmmkv_log_set_handler(second.context, CCallbackRecorder.onLog, CCallbackRecorder.release)
    #expect(first.isReleasedOnce)
    let secondID = uniqueStoreID()
    _ = try makeStore(id: secondID)
    #expect(!first.events.contains { $0.contains(secondID.rawValue) })
    #expect(second.events.contains { $0.contains(secondID.rawValue) })

    swiftmmkv_log_set_handler(nil, nil, nil)
    #expect(second.isReleasedOnce)
    let thirdID = uniqueStoreID()
    _ = try makeStore(id: thirdID)
    #expect(!second.events.contains { $0.contains(thirdID.rawValue) })
  }

  @Test func `The C Interface Releases A Context Given Without A Handler`() {
    defer { resetLogging() }
    let recorder = CCallbackRecorder()

    swiftmmkv_log_set_handler(recorder.context, nil, CCallbackRecorder.release)

    #expect(recorder.releases == 1)
  }
}

private func resetLogging() {
  MMKVLog.setHandler(nil)
  #if Logging
    MMKVLog.logger = Logger(label: "swift-mmkv")
  #endif
  MMKVLog.minimumLevel = .warning
}

private func uniqueStoreID() -> MMKVStore.ID {
  MMKVStore.ID(rawValue: "log-\(UUID().uuidString)")
}

#if Logging
  /// Records what a logger is asked to log.
  private struct RecordingLogHandler: LogHandler {
    struct Entry: Sendable {
      let level: Logger.Level
      let message: String
      let source: String
      let file: String
      let function: String
      let line: UInt
    }

    let recorder: ValueRecorder<Entry>
    var metadata = Logger.Metadata()
    var logLevel = Logger.Level.info

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
      get { self.metadata[key] }
      set { self.metadata[key] = newValue }
    }

    func log(event: LogEvent) {
      self.recorder.record(
        Entry(
          level: event.level,
          message: event.message.description,
          source: event.source,
          file: event.file,
          function: event.function,
          line: event.line
        )
      )
    }
  }
#endif
