import Foundation
import SwiftMMKV
import Testing

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

  @Test func `The Handler Receives Messages At Or Above The Minimum Level`() throws {
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

  @Test func `Messages Below The Minimum Level Are Dropped`() throws {
    defer { resetLogging() }
    let recorder = ValueRecorder<MMKVLog.Message>()
    MMKVLog.minimumLevel = .warning
    MMKVLog.setHandler(recorder.record)

    let id = uniqueStoreID()
    _ = try makeStore(id: id)

    #expect(!recorder.all.contains { $0.text.contains(id.rawValue) })
  }

  @Test func `Nothing Is Logged Without A Minimum Level`() throws {
    defer { resetLogging() }
    let recorder = ValueRecorder<MMKVLog.Message>()
    MMKVLog.minimumLevel = nil
    MMKVLog.setHandler(recorder.record)

    _ = try makeStore(id: uniqueStoreID())

    #expect(recorder.all.isEmpty)
  }

  @Test func `A Removed Handler No Longer Receives Messages`() throws {
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
}

private func resetLogging() {
  MMKVLog.setHandler(nil)
  MMKVLog.minimumLevel = .warning
}

private func uniqueStoreID() -> MMKVStore.ID {
  MMKVStore.ID(rawValue: "log-\(UUID().uuidString)")
}
