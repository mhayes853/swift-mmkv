import CJNI
import SwiftMMKV
import Synchronization

// The functions Kotlin's `NativeBridge` declares as `external`. Strings cross as UTF-8 byte
// arrays, because JNI's own string functions use a modified UTF-8 that mangles emoji.

/// The stores the app has opened, each with a record of the changes it has reported.
private struct Entry: Sendable {
  let store: MMKVStore
  let subscription: MMKVSubscription
  let changes: ChangeLog
}

private final class ChangeLog: Sendable {
  private let changes = Mutex([String]())

  var all: [String] {
    self.changes.withLock { $0 }
  }

  func append(_ change: String) {
    self.changes.withLock { $0.append(change) }
  }
}

private let entries = Mutex([Entry]())

private func entry(_ handle: jlong) -> Entry {
  entries.withLock { $0[Int(handle)] }
}

@_cdecl("Java_expo_modules_nativemmkv_NativeBridge_open")
public func open(
  env: Env,
  class: jclass?,
  rootDirectory: jbyteArray?,
  id: jbyteArray?,
  encryptionKey: jbyteArray?
) -> jlong {
  // React Native links its own copy of MMKV into this process, so the store is opened in
  // multi-process mode on both sides.
  let configuration = MMKVConfiguration(
    id: env.string(id),
    directory: MMKVDirectory(path: env.string(rootDirectory)),
    mode: .multiProcess,
    encryption: encryptionKey.map { .aes128(key: env.bytes($0)) }
  )
  guard let store = try? MMKVStore(configuration) else { return -1 }
  let changes = ChangeLog()
  let subscription = store.subscribe { change in
    switch change {
    case .key(let key): changes.append("key:\(key)")
    case .external: changes.append("external")
    }
  }
  return entries.withLock { entries in
    entries.append(Entry(store: store, subscription: subscription, changes: changes))
    return jlong(entries.count - 1)
  }
}

@_cdecl("Java_expo_modules_nativemmkv_NativeBridge_setString")
public func setString(
  env: Env, class: jclass?, handle: jlong, key: jbyteArray?, value: jbyteArray?
) -> jboolean {
  jboolean(entry(handle).store.set(env.string(value), forKey: env.string(key)))
}

@_cdecl("Java_expo_modules_nativemmkv_NativeBridge_getString")
public func getString(env: Env, class: jclass?, handle: jlong, key: jbyteArray?) -> jbyteArray? {
  entry(handle).store.value(forKey: env.string(key), as: String.self)
    .flatMap { env.byteArray(Array($0.utf8)) }
}

@_cdecl("Java_expo_modules_nativemmkv_NativeBridge_setNumber")
public func setNumber(
  env: Env, class: jclass?, handle: jlong, key: jbyteArray?, value: jdouble
) -> jboolean {
  jboolean(entry(handle).store.set(value, forKey: env.string(key)))
}

/// Returns an array holding the number, or an empty array if the key has no value.
@_cdecl("Java_expo_modules_nativemmkv_NativeBridge_getNumber")
public func getNumber(env: Env, class: jclass?, handle: jlong, key: jbyteArray?) -> jdoubleArray? {
  let value = entry(handle).store.value(forKey: env.string(key), as: Double.self)
  let array = env.pointee!.pointee.NewDoubleArray(env, value == nil ? 0 : 1)
  if var value {
    env.pointee!.pointee.SetDoubleArrayRegion(env, array, 0, 1, &value)
  }
  return array
}

@_cdecl("Java_expo_modules_nativemmkv_NativeBridge_setBoolean")
public func setBoolean(
  env: Env, class: jclass?, handle: jlong, key: jbyteArray?, value: jboolean
) -> jboolean {
  jboolean(entry(handle).store.set(value != 0, forKey: env.string(key)))
}

/// Returns 1 or 0, or -1 if the key has no value.
@_cdecl("Java_expo_modules_nativemmkv_NativeBridge_getBoolean")
public func getBoolean(env: Env, class: jclass?, handle: jlong, key: jbyteArray?) -> jint {
  switch entry(handle).store.value(forKey: env.string(key), as: Bool.self) {
  case true: 1
  case false: 0
  case nil: -1
  }
}

@_cdecl("Java_expo_modules_nativemmkv_NativeBridge_setBytes")
public func setBytes(
  env: Env, class: jclass?, handle: jlong, key: jbyteArray?, value: jbyteArray?
) -> jboolean {
  guard let value else { return 0 }
  let jni = env.pointee!.pointee
  let count = Int(jni.GetArrayLength(env, value))
  guard let elements = jni.GetByteArrayElements(env, value, nil) else { return 0 }
  defer { jni.ReleaseByteArrayElements(env, value, elements, JNI_ABORT) }
  let buffer = UnsafeRawBufferPointer(start: elements, count: count)
  return jboolean(entry(handle).store.set(unsafeBytes: buffer, forKey: env.string(key)))
}

@_cdecl("Java_expo_modules_nativemmkv_NativeBridge_getBytes")
public func getBytes(env: Env, class: jclass?, handle: jlong, key: jbyteArray?) -> jbyteArray? {
  entry(handle).store
    .withUnsafeBytes(forKey: env.string(key)) { env.byteArray($0) }
    .flatMap { $0 }
}

/// Returns the keys, sorted and separated by NUL bytes.
@_cdecl("Java_expo_modules_nativemmkv_NativeBridge_keys")
public func keys(env: Env, class: jclass?, handle: jlong) -> jbyteArray? {
  env.byteArray(Array(entry(handle).store.keys.sorted().joined(separator: "\0").utf8))
}

@_cdecl("Java_expo_modules_nativemmkv_NativeBridge_remove")
public func remove(env: Env, class: jclass?, handle: jlong, key: jbyteArray?) -> jboolean {
  jboolean(entry(handle).store.removeValue(forKey: env.string(key)))
}

@_cdecl("Java_expo_modules_nativemmkv_NativeBridge_removeAll")
public func removeAll(env: Env, class: jclass?, handle: jlong) {
  entry(handle).store.removeAll()
}

/// A read-modify-write under the store's exclusive lock, to interleave with the same operation
/// in JavaScript.
@_cdecl("Java_expo_modules_nativemmkv_NativeBridge_increment")
public func increment(env: Env, class: jclass?, handle: jlong, key: jbyteArray?) -> jdouble {
  let key = env.string(key)
  return entry(handle).store.withExclusiveLock { store in
    let next = (store.value(forKey: key, as: Double.self) ?? 0) + 1
    store.set(next, forKey: key)
    return next
  }
}

@_cdecl("Java_expo_modules_nativemmkv_NativeBridge_checkForExternalChanges")
public func checkForExternalChanges(env: Env, class: jclass?, handle: jlong) {
  entry(handle).store.checkForExternalChanges()
}

/// Returns the changes the store has reported, separated by NUL bytes.
@_cdecl("Java_expo_modules_nativemmkv_NativeBridge_changes")
public func changes(env: Env, class: jclass?, handle: jlong) -> jbyteArray? {
  env.byteArray(Array(entry(handle).changes.all.joined(separator: "\0").utf8))
}

// MARK: - JNI conversions

public typealias Env = UnsafeMutablePointer<JNIEnv?>

extension jboolean {
  fileprivate init(_ value: Bool) {
    self = value ? 1 : 0
  }
}

extension Env {
  fileprivate func bytes(_ array: jbyteArray?) -> [UInt8] {
    guard let array else { return [] }
    let count = self.pointee!.pointee.GetArrayLength(self, array)
    return [UInt8](unsafeUninitializedCapacity: Int(count)) { buffer, initializedCount in
      buffer.withMemoryRebound(to: jbyte.self) { buffer in
        self.pointee!.pointee.GetByteArrayRegion(self, array, 0, count, buffer.baseAddress)
      }
      initializedCount = Int(count)
    }
  }

  fileprivate func string(_ array: jbyteArray?) -> String {
    String(decoding: self.bytes(array), as: UTF8.self)
  }

  fileprivate func byteArray(_ bytes: [UInt8]) -> jbyteArray? {
    bytes.withUnsafeBytes { self.byteArray($0) }
  }

  fileprivate func byteArray(_ buffer: UnsafeRawBufferPointer) -> jbyteArray? {
    let array = self.pointee!.pointee.NewByteArray(self, jsize(buffer.count))
    self.pointee!.pointee.SetByteArrayRegion(
      self,
      array,
      0,
      jsize(buffer.count),
      buffer.bindMemory(to: jbyte.self).baseAddress
    )
    return array
  }
}
