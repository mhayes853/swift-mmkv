import CSwiftMMKV
import SwiftMMKV

// MARK: - Stores

@c @implementation
public func swiftmmkv_store_open(
  _ configuration: OpaquePointer,
  _ outStore: UnsafeMutablePointer<OpaquePointer?>
) -> swiftmmkv_status {
  let configuration = configuration.object(Configuration.self)
  guard !configuration.hasInvalidArgument else {
    return swiftmmkv_status(SWIFTMMKV_INVALID_ARGUMENT)
  }
  return status { () throws(MMKVError) in
    outStore.pointee = OpaquePointer(retaining: try MMKVStore(configuration.value))
  }
}

@c @implementation
public func swiftmmkv_store_close(_ store: OpaquePointer?) {
  store?.release(as: MMKVStore.self)
}

// MARK: - Keys

@c @implementation
public func swiftmmkv_store_contains(_ store: OpaquePointer, _ key: UnsafePointer<CChar>) -> Bool {
  store.store.contains(String(cString: key))
}

@c @implementation
public func swiftmmkv_store_count(_ store: OpaquePointer) -> Int {
  store.store.count
}

@c @implementation
public func swiftmmkv_store_keys(_ store: OpaquePointer) -> OpaquePointer {
  OpaquePointer(retaining: StringList(store.store.keys))
}

// MARK: - Removal

@c @implementation
public func swiftmmkv_store_remove(_ store: OpaquePointer, _ key: UnsafePointer<CChar>) -> Bool {
  store.store.removeValue(forKey: String(cString: key))
}

@c @implementation
public func swiftmmkv_store_remove_many(
  _ store: OpaquePointer,
  _ keys: UnsafePointer<UnsafePointer<CChar>>?,
  _ count: Int
) {
  store.store.removeValues(forKeys: makeStrings(keys, count))
}

@c @implementation
public func swiftmmkv_store_remove_all(_ store: OpaquePointer, _ keepingCapacity: Bool) {
  store.store.removeAll(keepingCapacity: keepingCapacity)
}

@c @implementation
public func swiftmmkv_store_import_all(_ store: OpaquePointer, _ source: OpaquePointer) -> Int {
  store.store.importAll(from: source.store)
}

// MARK: - Exclusive Access

@c @implementation
public func swiftmmkv_store_with_exclusive_lock(
  _ store: OpaquePointer,
  _ context: UnsafeMutableRawPointer?,
  _ body: swiftmmkv_locked_callback
) {
  store.store.withExclusiveLock { _ in body(context, store) }
}

// MARK: - Changes

/// Calls a C change callback with a change, lending it the key for the length of the call.
private func send(
  _ change: MMKVStore.Change,
  to onChange: swiftmmkv_change_callback,
  _ context: CallbackContext
) {
  switch change {
  case .key(let key):
    key.withCString { onChange(context.pointer, swiftmmkv_change_kind(SWIFTMMKV_CHANGE_KEY), $0) }
  case .external:
    onChange(context.pointer, swiftmmkv_change_kind(SWIFTMMKV_CHANGE_EXTERNAL), nil)
  }
}

@c @implementation
public func swiftmmkv_store_subscribe(
  _ store: OpaquePointer,
  _ context: UnsafeMutableRawPointer?,
  _ onChange: swiftmmkv_change_callback,
  _ release: swiftmmkv_context_release?
) -> OpaquePointer {
  let context = CallbackContext(context, release: release)
  let subscription = store.store.subscribe { change in
    send(change, to: onChange, context)
  }
  return OpaquePointer(retaining: Subscription(subscription))
}

@c @implementation
public func swiftmmkv_store_subscribe_key(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ context: UnsafeMutableRawPointer?,
  _ onChange: swiftmmkv_change_callback,
  _ release: swiftmmkv_context_release?
) -> OpaquePointer {
  let key = String(cString: key)
  let context = CallbackContext(context, release: release)
  let subscription = store.store.subscribe { change in
    if case .key(let changed) = change, changed != key { return }
    send(change, to: onChange, context)
  }
  return OpaquePointer(retaining: Subscription(subscription))
}

@c @implementation
public func swiftmmkv_store_check_for_external_changes(_ store: OpaquePointer) {
  store.store.checkForExternalChanges()
}

// MARK: - Suspension

@c @implementation
public func swiftmmkv_store_is_suspended(_ store: OpaquePointer) -> Bool {
  store.store.isSuspended
}

@c @implementation
public func swiftmmkv_store_suspend(_ store: OpaquePointer) {
  store.store.suspend()
}

@c @implementation
public func swiftmmkv_store_resume(_ store: OpaquePointer) {
  store.store.resume()
}

// MARK: - Maintenance

@c @implementation
public func swiftmmkv_store_byte_size(_ store: OpaquePointer) -> Int {
  store.store.byteSize
}

@c @implementation
public func swiftmmkv_store_used_byte_size(_ store: OpaquePointer) -> Int {
  store.store.usedByteSize
}

@c @implementation
public func swiftmmkv_store_trim(_ store: OpaquePointer) {
  store.store.trim()
}

@c @implementation
public func swiftmmkv_store_sync(_ store: OpaquePointer) {
  store.store.sync()
}

@c @implementation
public func swiftmmkv_store_rekey(
  _ store: OpaquePointer,
  _ encryption: swiftmmkv_encryption,
  _ key: UnsafeRawPointer?,
  _ keyCount: Int
) -> swiftmmkv_status {
  guard let encryption = makeEncryption(encryption, key, keyCount) else {
    return swiftmmkv_status(SWIFTMMKV_INVALID_ARGUMENT)
  }
  return status { () throws(MMKVError) in try store.store.rekey(encryption) }
}

@c @implementation
public func swiftmmkv_store_back_up(
  _ store: OpaquePointer,
  _ backup: UnsafePointer<CChar>
) -> swiftmmkv_status {
  status { () throws(MMKVError) in
    try store.store.backUp(to: MMKVDirectory(path: String(cString: backup)))
  }
}

@c @implementation
public func swiftmmkv_store_restore(
  _ store: OpaquePointer,
  _ backup: UnsafePointer<CChar>,
  _ outRestored: UnsafeMutablePointer<Bool>?
) -> swiftmmkv_status {
  status { () throws(MMKVError) in
    let didRestore = try store.store.restore(from: MMKVDirectory(path: String(cString: backup)))
    outRestored?.pointee = didRestore
  }
}
