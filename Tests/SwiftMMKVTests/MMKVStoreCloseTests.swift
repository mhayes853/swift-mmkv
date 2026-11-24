import Foundation
import SwiftMMKV
import Testing

@Suite struct MMKVStoreCloseTests {
  @Test func `A Closed Store Turns Reads And Writes Away`() throws {
    let store = try makeStore()
    store.set("blob", forKey: "username")
    #expect(!store.isClosed)

    store.close()
    #expect(store.isClosed)
    #expect(store.value(forKey: "username", as: String.self) == nil)
    #expect(store.withBytes(forKey: "username") { $0.byteCount } == nil)
    #expect(store.keys.isEmpty)
    #expect(store.keys(underKey: "").isEmpty)
    #expect(store.count == 0)
    #expect(!store.contains("username"))
    #expect(store.byteSize == 0)
    #expect(store.usedByteSize == 0)
    #expect(!store.isExpiryEnabled)
    #expect(!store.set("other", forKey: "username"))
    #expect(!store.set(1.0, forKey: "number"))
    #expect(!store.removeValue(forKey: "username"))
    store.removeAll()
    store.removeAll { _ in true }
    store.removeValues(underKey: "")
    store.trim()
    store.sync()
    store.checkForExternalChanges()
    #expect(store.importAll(from: try makeStore()) == 0)
    #expect(try makeStore().importAll(from: store) == 0)
  }

  @Test func `A Closed Store Keeps Its Identifier And Configuration`() throws {
    let store = try makeStore(id: "settings")
    let configuration = store.configuration

    store.close()

    #expect(store.id == "settings")
    #expect(store.configuration == configuration)
  }

  @Test func `Closing Twice Has No Further Effect`() throws {
    let store = try makeStore()
    store.close()
    store.close()
    #expect(store.isClosed)
  }

  @Test func `Stores Over The Same Files Are Closed Together`() throws {
    let rootDirectory = temporaryRootDirectory()
    let first = try makeStore(id: "shared", rootDirectory: rootDirectory)
    let second = try makeStore(id: "shared", rootDirectory: rootDirectory)
    let other = try makeStore(id: "other", rootDirectory: rootDirectory)
    first.set("value", forKey: "key")

    first.close()

    #expect(second.isClosed)
    #expect(second.value(forKey: "key", as: String.self) == nil)
    #expect(!other.isClosed)
    #expect(other.set("value", forKey: "key"))
  }

  @Test func `Throwing Operations Report The Closure`() throws {
    let store = try makeStore()
    let backup = MMKVDirectory(path: temporaryRootDirectory())
    try store.encode(1, forKey: "count", with: TextCoder.shared)
    try store.backUp(to: backup)
    store.close()

    let error = expectError(.storeIsClosed) {
      try store.decode(Int.self, forKey: "count", with: TextCoder.shared)
    }
    #expect(error?.message == "The store \"mmkv.default\" is closed.")
    expectError(.storeIsClosed) { try store.encode(2, forKey: "count", with: TextCoder.shared) }
    expectError(.storeIsClosed) { try store.encode(["a": 1], intoKeysUnder: "object") }
    expectError(.storeIsClosed) { try store.decode([String: Int].self, fromKeysUnder: "object") }
    expectError(.storeIsClosed) { try store.rekey(.aes128(key: "key")) }
    expectError(.storeIsClosed) { try store.disableExpiry() }
  }

  @Test func `A Store Opened Again Reads What The Closed One Wrote`() throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "settings", rootDirectory: rootDirectory)
    store.set("dark", forKey: "theme")
    store.close()

    let reopened = try makeStore(id: "settings", rootDirectory: rootDirectory)

    #expect(!reopened.isClosed)
    #expect(reopened.value(forKey: "theme", as: String.self) == "dark")
    #expect(reopened.set("light", forKey: "theme"))
    #expect(store.isClosed)
    #expect(store.value(forKey: "theme", as: String.self) == nil)
  }

  @Test func `A Store Opened Again Can Be Closed Again`() throws {
    let rootDirectory = temporaryRootDirectory()
    for round in 0..<20 {
      let store = try makeStore(id: "settings", rootDirectory: rootDirectory)
      #expect(store.count == round)
      #expect(store.set(Double(round), forKey: "key-\(round)"))
      store.close()
      #expect(store.isClosed)
    }
  }

  @Test func `A Store Can Be Opened Again With Another Mode`() throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "settings", rootDirectory: rootDirectory)
    store.set("dark", forKey: "theme")
    store.suspend()
    #expect(!store.isSuspended)
    store.close()

    let reopened = try makeStore(id: "settings", rootDirectory: rootDirectory, mode: .multiProcess)
    reopened.suspend()

    #expect(reopened.isSuspended)
    reopened.resume()
    #expect(reopened.value(forKey: "theme", as: String.self) == "dark")
  }

  @Test func `A Closed Store Can Be Removed`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    let store = try makeStore(id: "user", rootDirectory: rootDirectory)
    store.set("blob", forKey: "username")
    expectError(.storeIsOpen) { try directory.removeStore(id: "user") }

    store.close()

    #expect(try directory.removeStore(id: "user"))
    #expect(!directory.containsStore(id: "user"))
    let reopened = try makeStore(id: "user", rootDirectory: rootDirectory)
    #expect(reopened.keys.isEmpty)
    #expect(store.isClosed)
  }

  @Test func `Closed Stores Can All Be Removed`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    let stores = try ["a", "b"].map { try makeStore(id: $0, rootDirectory: rootDirectory) }
    for store in stores {
      store.set("value", forKey: "key")
      store.close()
    }

    #expect(try directory.removeAllStores() == 2)
    #expect(try directory.stores.isEmpty)
  }

  @Test func `A Directory Restores Over A Closed Store`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    let backup = MMKVDirectory(path: temporaryRootDirectory() + "/backup")
    let store = try makeStore(id: "settings", rootDirectory: rootDirectory)
    store.set("dark", forKey: "theme")
    try store.backUp(to: backup)
    store.set("light", forKey: "theme")
    store.close()

    expectError(.storeIsClosed) { try store.backUp(to: backup) }
    expectError(.storeIsClosed) { try store.restore(from: backup) }
    #expect(try directory.restoreStore(id: "settings", from: backup))

    let reopened = try makeStore(id: "settings", rootDirectory: rootDirectory)
    #expect(reopened.value(forKey: "theme", as: String.self) == "dark")
  }

  @Test func `An Exclusive Lock Body Runs Without The Lock Once Closed`() throws {
    let store = try makeStore()
    store.set(1.0, forKey: "count")
    store.close()

    let result = store.withExclusiveLock { store in
      store.set(2.0, forKey: "count")
      return store.value(forKey: "count", as: Double.self)
    }

    #expect(result == nil)
  }

  @Test func `A Suspended Store Can Be Closed`() throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "shared", rootDirectory: rootDirectory, mode: .multiProcess)
    store.set("value", forKey: "key")
    store.suspend()

    store.close()

    #expect(store.isClosed)
    #expect(!store.isSuspended)
    store.resume()
    store.suspend()
    #expect(!store.isSuspended)
    #expect(!store.set("other", forKey: "key"))
    let reopened = try makeStore(id: "shared", rootDirectory: rootDirectory, mode: .multiProcess)
    #expect(!reopened.isSuspended)
    #expect(reopened.value(forKey: "key", as: String.self) == "value")
  }

  @Test func `Closing Waits For An Operation Under Way On Another Thread`() async throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "settings", rootDirectory: rootDirectory)
    let events = ValueRecorder<String>()
    let (lockTaken, lockTakenContinuation) = AsyncStream.makeStream(of: Void.self)

    let writer = Thread {
      store.withExclusiveLock { store in
        lockTakenContinuation.yield()
        Thread.sleep(forTimeInterval: 0.2)
        // The operation under way is let through even though the store is being closed.
        events.record(store.set("value", forKey: "key") ? "wrote" : "refused")
      }
    }
    writer.start()
    for await _ in lockTaken { break }

    store.close()
    events.record("closed")

    #expect(events.all == ["wrote", "closed"])
    let reopened = try makeStore(id: "settings", rootDirectory: rootDirectory)
    #expect(reopened.value(forKey: "key", as: String.self) == "value")
  }

  @Test func `Closing Inside An Exclusive Lock Closes When The Body Returns`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    let store = try makeStore(id: "settings", rootDirectory: rootDirectory)

    store.withExclusiveLock { store in
      #expect(store.set("value", forKey: "key"))
      store.close()
      #expect(store.isClosed)
      // The operation under way is let through, and the files stay open for it.
      #expect(store.set("other", forKey: "key"))
      #expect(store.value(forKey: "key", as: String.self) == "other")
      expectError(.storeIsOpen) { try directory.removeStore(id: "settings") }
    }

    #expect(store.isClosed)
    #expect(!store.set("late", forKey: "key"))
    let reopened = try makeStore(id: "settings", rootDirectory: rootDirectory)
    #expect(reopened.value(forKey: "key", as: String.self) == "other")
    reopened.close()
    #expect(try directory.removeStore(id: "settings"))
  }

  @Test func `Closing While Reading Bytes Leaves The Bytes Readable`() throws {
    let store = try makeStore()
    let bytes = (0..<64).map { UInt8($0) }
    bytes.withUnsafeBytes { _ = store.set(unsafeBytes: $0, forKey: "bytes") }

    let read = store.withUnsafeBytes(forKey: "bytes") { buffer in
      store.close()
      return Array(buffer)
    }

    #expect(read == bytes)
    #expect(store.isClosed)
  }

  @Test func `Closing While Other Threads Write Does Not Lose The Store`() async throws {
    let rootDirectory = temporaryRootDirectory()
    for _ in 0..<20 {
      let store = try makeStore(id: "settings", rootDirectory: rootDirectory)
      await withTaskGroup(of: Void.self) { group in
        for writer in 0..<4 {
          group.addTask {
            for index in 0..<200 {
              _ = store.set(Double(index), forKey: "key-\(writer)-\(index % 10)")
              _ = store.value(forKey: "key-\(writer)-\(index % 10)", as: Double.self)
            }
          }
        }
        group.addTask { store.close() }
        group.addTask { store.close() }
      }
      #expect(store.isClosed)
    }
    let reopened = try makeStore(id: "settings", rootDirectory: rootDirectory)
    #expect(reopened.count <= 40)
    #expect(reopened.set("value", forKey: "key"))
  }

  @Test func `Closing While Other Threads Open The Store Is Safe`() async throws {
    let rootDirectory = temporaryRootDirectory()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<4 {
        group.addTask {
          for index in 0..<200 {
            guard let store = try? makeStore(id: "settings", rootDirectory: rootDirectory) else {
              continue
            }
            _ = store.set(Double(index), forKey: "key")
            store.close()
          }
        }
      }
    }
    let reopened = try makeStore(id: "settings", rootDirectory: rootDirectory)
    #expect(reopened.contains("key"))
  }
}

@Suite struct MMKVStoreCloseListenerTests {
  @Test func `Closing Tells Listeners Once And Then Nothing`() throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "settings", rootDirectory: rootDirectory)
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)
    store.set("dark", forKey: "theme")

    store.close()
    store.close()
    store.set("light", forKey: "theme")
    let reopened = try makeStore(id: "settings", rootDirectory: rootDirectory)
    reopened.set("light", forKey: "theme")

    #expect(recorder.all == [.key("theme"), .external])
    subscription.cancel()
  }

  @Test func `Closing Tells A Value Listener That The Value Is Gone`() throws {
    let store = try makeStore()
    store.set("dark", forKey: "theme")
    let recorder = ValueRecorder<String?>()
    let subscription = store.subscribe(forKey: "theme", as: String.self, recorder.record)

    store.close()

    #expect(recorder.all == ["dark", nil])
    subscription.cancel()
  }

  @Test func `A Listener Added To A Closed Store Is Told Nothing`() throws {
    let store = try makeStore()
    store.close()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    store.set("dark", forKey: "theme")
    store.close()

    #expect(recorder.all.isEmpty)
    subscription.cancel()
  }

  @Test func `Closing Inside An Exclusive Lock Still Tells Listeners`() throws {
    let store = try makeStore()
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    store.withExclusiveLock { store in
      store.set("dark", forKey: "theme")
      store.close()
      store.set("light", forKey: "theme")
    }

    #expect(recorder.all == [.external])
    subscription.cancel()
  }

  @Test func `Closing Ends The Sequence Of Changes`() async throws {
    let store = try makeStore()
    let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
    let task = Task {
      var changes = [MMKVStore.Change]()
      var iterator = store.changes.makeAsyncIterator()
      startedContinuation.yield()
      while let change = await iterator.next() {
        changes.append(change)
      }
      return changes
    }
    for await _ in started { break }

    store.set("dark", forKey: "theme")
    store.close()

    #expect(await task.value == [.key("theme"), .external])
  }

  @Test func `The Sequence Of Changes Of A Closed Store Is Empty`() async throws {
    let store = try makeStore()
    store.close()

    var changes = [MMKVStore.Change]()
    for await change in store.changes {
      changes.append(change)
    }

    #expect(changes.isEmpty)
  }

  @Test func `Closing Ends The Sequence Of A Key's Values`() async throws {
    let store = try makeStore()
    store.set("dark", forKey: "theme")
    let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
    let task = Task {
      var values = [String?]()
      for await value in store.values(forKey: "theme", as: String.self) {
        values.append(value)
        startedContinuation.yield()
      }
      return values
    }
    for await _ in started { break }

    store.close()

    #expect(await task.value == ["dark", nil])
  }

  @Test func `Closing Ends A Decoding Sequence With The Closure`() async throws {
    let store = try makeStore()
    try store.encode(1, forKey: "count", with: TextCoder.shared)
    let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
    let task = Task {
      var values = [Int?]()
      do {
        for try await value in store.values(forKey: "count", as: Int.self, with: TextCoder.shared) {
          values.append(value)
          startedContinuation.yield()
        }
        return (values, MMKVError.Code?.none)
      } catch {
        return (values, (error as? MMKVError)?.code)
      }
    }
    for await _ in started { break }

    store.close()

    let (values, code) = await task.value
    #expect(values == [1])
    #expect(code == .storeIsClosed)
  }
}
