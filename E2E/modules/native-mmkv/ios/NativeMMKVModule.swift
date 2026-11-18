import ExpoModulesCore
import Foundation
import SwiftMMKV

/// Exposes swift-mmkv to JavaScript, so the test app can compare what Swift sees in a store
/// with what react-native-mmkv sees in the same files.
public final class NativeMMKVModule: Module {
  private let stores = Stores()

  public func definition() -> ModuleDefinition {
    Name("NativeMMKV")

    Function("rootDirectory") { () -> String in
      try MMKVDirectory.reactNative().path
    }

    Function("setString") { (store: StoreOptions, key: String, value: String) -> Bool in
      try self.stores.open(store).set(value, forKey: key)
    }
    Function("getString") { (store: StoreOptions, key: String) -> String? in
      try self.stores.open(store).value(forKey: key, as: String.self)
    }

    Function("setNumber") { (store: StoreOptions, key: String, value: Double) -> Bool in
      try self.stores.open(store).set(value, forKey: key)
    }
    Function("getNumber") { (store: StoreOptions, key: String) -> Double? in
      try self.stores.open(store).value(forKey: key, as: Double.self)
    }

    Function("setBoolean") { (store: StoreOptions, key: String, value: Bool) -> Bool in
      try self.stores.open(store).set(value, forKey: key)
    }
    Function("getBoolean") { (store: StoreOptions, key: String) -> Bool? in
      try self.stores.open(store).value(forKey: key, as: Bool.self)
    }

    Function("setBytes") { (store: StoreOptions, key: String, value: [UInt8]) -> Bool in
      try self.stores.open(store).set(value, forKey: key)
    }
    Function("getBytes") { (store: StoreOptions, key: String) -> [UInt8]? in
      try self.stores.open(store).value(forKey: key, as: [UInt8].self)
    }

    Function("keys") { (store: StoreOptions) -> [String] in
      try self.stores.open(store).keys.sorted()
    }
    Function("remove") { (store: StoreOptions, key: String) -> Bool in
      try self.stores.open(store).removeValue(forKey: key)
    }
    Function("removeAll") { (store: StoreOptions) in
      try self.stores.open(store).removeAll()
    }

    // A read-modify-write under the store's exclusive lock, to interleave with the same
    // operation in JavaScript.
    Function("increment") { (store: StoreOptions, key: String) -> Double in
      try self.stores.open(store).withExclusiveLock { store in
        let next = (store.value(forKey: key, as: Double.self) ?? 0) + 1
        store.set(next, forKey: key)
        return next
      }
    }

    Function("checkForExternalChanges") { (store: StoreOptions) in
      try self.stores.open(store).checkForExternalChanges()
    }
    Function("changes") { (store: StoreOptions) -> [String] in
      try self.stores.changes(store)
    }

    // Leaves the outcome where the script that launched the app can read it.
    Function("writeResults") { (json: String) in
      let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      try Data(json.utf8).write(to: documents.appendingPathComponent("e2e-results.json"))
    }
  }
}

struct StoreOptions: Record {
  @Field var id: String = MMKVStore.ID.default.rawValue
  @Field var encryptionKey: String?
}

/// The stores the app has opened, each with a record of the changes it has reported.
private final class Stores: @unchecked Sendable {
  private struct Entry {
    let store: MMKVStore
    let subscription: MMKVSubscription
    let changes: ChangeLog
  }

  private let lock = NSLock()
  private var entries = [String: Entry]()

  func open(_ options: StoreOptions) throws -> MMKVStore {
    try self.entry(options).store
  }

  func changes(_ options: StoreOptions) throws -> [String] {
    try self.entry(options).changes.all
  }

  private func entry(_ options: StoreOptions) throws -> Entry {
    try self.lock.withLock {
      if let entry = self.entries[options.id] {
        return entry
      }
      // React Native links its own copy of MMKV into this process, so the store is opened in
      // multi-process mode on both sides.
      let store = try MMKVStore(
        MMKVConfiguration(
          id: MMKVStore.ID(rawValue: options.id),
          directory: .reactNative(),
          mode: .multiProcess,
          encryption: options.encryptionKey.map { .aes128(key: $0) }
        )
      )
      let changes = ChangeLog()
      let subscription = store.subscribe { change in
        switch change {
        case .key(let key): changes.append("key:\(key)")
        case .external: changes.append("external")
        }
      }
      let entry = Entry(store: store, subscription: subscription, changes: changes)
      self.entries[options.id] = entry
      return entry
    }
  }
}

private final class ChangeLog: @unchecked Sendable {
  private let lock = NSLock()
  private var changes = [String]()

  var all: [String] {
    self.lock.withLock { self.changes }
  }

  func append(_ change: String) {
    self.lock.withLock { self.changes.append(change) }
  }
}
