import Foundation
import SwiftMMKV
import Testing

@Suite struct MMKVBackupTests {
  private func corrupt(_ path: String) throws {
    let handle = try #require(FileHandle(forWritingAtPath: path))
    defer { try? handle.close() }
    try handle.seek(toOffset: 4)
    try handle.write(contentsOf: Data(repeating: 0xFF, count: 8))
  }

  @Test func `A Store Is Backed Up And Restored`() throws {
    let store = try makeStore(id: "settings")
    let backup = MMKVDirectory(path: temporaryRootDirectory() + "/backup")
    store.set("dark", forKey: "theme")

    try store.backUp(to: backup)
    store.set("light", forKey: "theme")
    store.set(1.0, forKey: "extra")

    #expect(backup.containsStore(id: "settings"))
    #expect(try store.restore(from: backup))
    #expect(store.value(forKey: "theme", as: String.self) == "dark")
    #expect(!store.contains("extra"))
  }

  @Test func `A Backup Is A Directory Of Stores`() throws {
    let store = try makeStore(id: "settings")
    let backup = MMKVDirectory(path: temporaryRootDirectory())
    store.set("dark", forKey: "theme")
    try store.backUp(to: backup)
    store.set("light", forKey: "theme")

    #expect(try backup.stores.map(\.id) == ["settings"])
    let snapshot = try makeStore(id: "settings", rootDirectory: backup.path)
    #expect(snapshot.value(forKey: "theme", as: String.self) == "dark")
  }

  @Test func `A Backup Replaces An Earlier One`() throws {
    let store = try makeStore(id: "settings")
    let backup = MMKVDirectory(path: temporaryRootDirectory())
    store.set("dark", forKey: "theme")
    try store.backUp(to: backup)
    store.set("light", forKey: "theme")
    try store.backUp(to: backup)
    store.removeAll()

    try store.restore(from: backup)

    #expect(store.value(forKey: "theme", as: String.self) == "light")
  }

  @Test func `A Directory Backs Up And Restores A Store That Is Not Open`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    let backup = MMKVDirectory(path: temporaryRootDirectory())
    let restored = MMKVDirectory(path: temporaryRootDirectory() + "/restored")
    try makeUnopenedStoreFiles(at: "\(rootDirectory)/unopened")

    #expect(try directory.backUpStore(id: "unopened", to: backup))
    #expect(try restored.restoreStore(id: "unopened", from: backup))

    let store = try makeStore(id: "unopened", rootDirectory: restored.path)
    #expect(store.value(forKey: "key", as: String.self) == "value")
  }

  @Test func `A Store That Does Not Exist Is Not Backed Up Or Restored`() throws {
    let directory = MMKVDirectory(path: temporaryRootDirectory())
    let backup = MMKVDirectory(path: temporaryRootDirectory())

    #expect(try !directory.backUpStore(id: "missing", to: backup))
    #expect(try !directory.restoreStore(id: "missing", from: backup))
    #expect(try !makeStore(id: "settings").restore(from: backup))
  }

  @Test func `Every Store In A Directory Is Backed Up And Restored`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    let backup = MMKVDirectory(path: temporaryRootDirectory())
    let open = try makeStore(id: "open", rootDirectory: rootDirectory)
    let hashed = try makeStore(id: "a/b", rootDirectory: rootDirectory)
    try makeUnopenedStoreFiles(at: "\(rootDirectory)/unopened")
    open.set("first", forKey: "key")
    hashed.set("first", forKey: "key")

    #expect(try directory.backUpAllStores(to: backup) == 3)
    #expect(try backup.stores.count == 3)
    open.set("second", forKey: "key")
    hashed.set("second", forKey: "key")

    #expect(try directory.restoreAllStores(from: backup) == 3)
    #expect(open.value(forKey: "key", as: String.self) == "first")
    #expect(hashed.value(forKey: "key", as: String.self) == "first")
  }

  @Test func `An Empty Directory Backs Up And Restores Nothing`() throws {
    let directory = MMKVDirectory(path: temporaryRootDirectory())
    let backup = MMKVDirectory(path: temporaryRootDirectory() + "/missing")

    #expect(try directory.backUpAllStores(to: backup) == 0)
    #expect(try directory.restoreAllStores(from: backup) == 0)
  }

  @Test func `Restoring Tells Listeners The Store Changed`() throws {
    let id = MMKVStore.ID(rawValue: "restore-\(UUID().uuidString)")
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: id, rootDirectory: rootDirectory)
    let other = try makeStore(id: id, rootDirectory: rootDirectory)
    let backup = MMKVDirectory(path: temporaryRootDirectory())
    store.set("dark", forKey: "theme")
    try store.backUp(to: backup)
    let changes = ValueRecorder<MMKVStore.Change>()
    let subscription = other.subscribe { changes.record($0) }
    defer { subscription.cancel() }

    try MMKVDirectory(path: rootDirectory).restoreStore(id: id, from: backup)

    #expect(changes.all == [.external])
  }

  @Test func `A Backup Onto The Store's Directory Is Refused`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    let store = try makeStore(id: "settings", rootDirectory: rootDirectory)
    let same = MMKVDirectory(path: rootDirectory + "/./")

    expectError(.backupIsStoreDirectory) {
      try store.backUp(to: same)
    }
    expectError(.backupIsStoreDirectory) {
      try store.restore(from: same)
    }
    expectError(.backupIsStoreDirectory) {
      try directory.backUpAllStores(to: same)
    }
    expectError(.backupIsStoreDirectory) {
      try directory.restoreAllStores(from: same)
    }
  }

  @Test func `A Read Only Store Is Not Restored`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    let backup = MMKVDirectory(path: temporaryRootDirectory())
    try makeUnopenedStoreFiles(at: "\(rootDirectory)/settings")
    try directory.backUpStore(id: "settings", to: backup)
    let store = try makeStore(id: "settings", rootDirectory: rootDirectory, isReadOnly: true)

    expectError(.restoreFailed) {
      try store.restore(from: backup)
    }
    #expect(store.value(forKey: "key", as: String.self) == "value")
  }

  @Test func `A Suspended Store Is Not Backed Up Or Restored`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    let backup = MMKVDirectory(path: temporaryRootDirectory())
    let store = try makeStore(id: "settings", rootDirectory: rootDirectory, mode: .multiProcess)
    store.set("dark", forKey: "theme")
    try store.backUp(to: backup)

    store.suspend()

    expectError(.storeIsSuspended) { try store.backUp(to: backup) }
    expectError(.storeIsSuspended) { try store.restore(from: backup) }
    expectError(.storeIsSuspended) {
      try directory.backUpAllStores(to: backup)
    }
    expectError(.storeIsSuspended) {
      try directory.restoreAllStores(from: backup)
    }

    store.resume()
    #expect(try store.restore(from: backup))
  }

  @Test func `A Backup Open In This Process Is Not Replaced`() throws {
    let store = try makeStore(id: "settings")
    let backupDirectory = temporaryRootDirectory()
    let backup = MMKVDirectory(path: backupDirectory)
    try store.backUp(to: backup)
    let snapshot = try makeStore(id: "settings", rootDirectory: backupDirectory)
    _ = snapshot.count

    expectError(.storeIsOpen) {
      try store.backUp(to: backup)
    }
    expectError(.storesAreOpen) {
      try store.configuration.directory.backUpAllStores(to: backup)
    }
  }

  @Test func `A Store Is Valid Until Its Files Are Damaged`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    #expect(!directory.isStoreValid(id: "settings"))

    try makeUnopenedStoreFiles(at: "\(rootDirectory)/settings")
    #expect(directory.isStoreValid(id: "settings"))

    try self.corrupt("\(rootDirectory)/settings")
    #expect(!directory.isStoreValid(id: "settings"))
  }

  @Test func `A New Store Is Valid`() throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "settings", rootDirectory: rootDirectory)
    _ = store.count

    #expect(MMKVDirectory(path: rootDirectory).isStoreValid(id: "settings"))
  }

  @Test func `A Damaged Backup Is Not Restored`() throws {
    let backupDirectory = temporaryRootDirectory()
    let backup = MMKVDirectory(path: backupDirectory)
    let store = try makeStore(id: "settings")
    store.set("dark", forKey: "theme")
    try store.backUp(to: backup)
    try self.corrupt("\(backupDirectory)/settings")
    store.set("light", forKey: "theme")

    expectError(.backupInvalid) {
      try store.restore(from: backup)
    }
    expectError(.backupInvalid) {
      try store.configuration.directory.restoreAllStores(from: backup)
    }
    #expect(store.value(forKey: "theme", as: String.self) == "light")
  }

  @Test func `An Encrypted Store Is Restored With Its Key`() throws {
    let backup = MMKVDirectory(path: temporaryRootDirectory())
    let store = try makeStore(id: "secrets", encryption: .aes256(key: "key"))
    store.set("token", forKey: "token")
    try store.backUp(to: backup)
    store.removeAll()

    try store.restore(from: backup)

    #expect(store.value(forKey: "token", as: String.self) == "token")
  }

  @Test func `A Multi Process Store Is Backed Up And Restored While It Is Locked`() throws {
    let backup = MMKVDirectory(path: temporaryRootDirectory())
    let store = try makeStore(id: "settings", mode: .multiProcess)
    store.set("dark", forKey: "theme")

    try store.withExclusiveLock { store in
      try store.backUp(to: backup)
      store.set("light", forKey: "theme")
      try store.restore(from: backup)
      #expect(store.value(forKey: "theme", as: String.self) == "dark")
      store.set(1.0, forKey: "extra")
    }

    #expect(store.value(forKey: "theme", as: String.self) == "dark")
    #expect(store.value(forKey: "extra", as: Double.self) == 1.0)
  }

  @Test func `Open Stores Are Restored Together While One Is Being Written`() async throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    let backup = MMKVDirectory(path: temporaryRootDirectory())
    let stores = try ["a", "b", "c"]
      .map {
        try makeStore(id: MMKVStore.ID(rawValue: $0), rootDirectory: rootDirectory)
      }
    for store in stores {
      store.set("backed up", forKey: "state")
    }
    #expect(try directory.backUpAllStores(to: backup) == 3)

    let writer = Task {
      for index in 0..<2_000 {
        stores[index % 3].set(index, forKey: "counter")
      }
    }
    for _ in 0..<20 {
      #expect(try directory.restoreAllStores(from: backup) == 3)
    }
    await writer.value
    #expect(try directory.restoreAllStores(from: backup) == 3)

    for store in stores {
      #expect(store.value(forKey: "state", as: String.self) == "backed up")
      #expect(!store.contains("counter"))
    }
  }
}
