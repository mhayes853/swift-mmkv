import CSwiftMMKV
import SwiftMMKV

// The implementation of `swiftmmkv.h`. The compiler checks every function here against its
// declaration in the header, which is also where each one is documented.

@c @implementation
public func swiftmmkv_abi_version() -> UInt32 {
  UInt32(SWIFTMMKV_ABI_VERSION)
}

// MARK: - Handles

// Every opaque type of the header is a pointer to a retained Swift object. C sees them as
// distinct types, but Swift imports each as `OpaquePointer`, so the functions here name the
// class they expect.

extension OpaquePointer {
  /// A handle that owns a reference to `object`, to be given up with ``release(as:)``.
  fileprivate init(retaining object: some AnyObject) {
    self.init(Unmanaged.passRetained(object).toOpaque())
  }

  /// The object behind a handle, which the handle goes on owning.
  fileprivate func object<T: AnyObject>(_ type: T.Type) -> T {
    Unmanaged<T>.fromOpaque(UnsafeRawPointer(self)).takeUnretainedValue()
  }

  /// Gives up the reference a handle owns, after which the handle is invalid.
  fileprivate func release<T: AnyObject>(as type: T.Type) {
    Unmanaged<T>.fromOpaque(UnsafeRawPointer(self)).release()
  }

  /// The store behind a `swiftmmkv_store`.
  fileprivate var store: MMKVStore {
    self.object(MMKVStore.self)
  }
}

// MARK: - Arguments

extension MMKVDirectory {
  fileprivate init(_ path: UnsafePointer<CChar>) {
    self.init(path: String(cString: path))
  }
}

extension MMKVStore.ID {
  fileprivate init(_ id: UnsafePointer<CChar>) {
    self.init(rawValue: String(cString: id))
  }
}

/// The strings of a C array of C strings.
private func makeStrings(_ strings: UnsafePointer<UnsafePointer<CChar>>?, _ count: Int) -> [String]
{
  UnsafeBufferPointer(start: strings, count: strings == nil ? 0 : count)
    .map { String(cString: $0) }
}

/// The expiry of a C write, where zero seconds means never.
private func makeExpiry(_ seconds: UInt32) -> Duration? {
  seconds == 0 ? nil : .seconds(Int64(seconds))
}

private func makeMode(_ mode: swiftmmkv_mode) -> MMKVConfiguration.Mode? {
  switch mode {
  case SWIFTMMKV_MODE_SINGLE_PROCESS: .singleProcess
  case SWIFTMMKV_MODE_MULTI_PROCESS: .multiProcess
  default: nil
  }
}

private func makeRecovery(_ recovery: swiftmmkv_recovery) -> MMKVConfiguration.Recovery? {
  switch recovery {
  case SWIFTMMKV_RECOVERY_DISCARD: .discard
  case SWIFTMMKV_RECOVERY_RECOVER: .recover
  default: nil
  }
}

/// The cipher and key of a C call, or `nil` if `encryption` is not one of its constants.
///
/// A key of the wrong length is let through, for the store to turn down.
private func makeEncryption(
  _ encryption: swiftmmkv_encryption,
  _ key: UnsafeRawPointer?,
  _ keyCount: Int
) -> MMKVConfiguration.Encryption?? {
  let key = [UInt8](UnsafeRawBufferPointer(start: key, count: key == nil ? 0 : keyCount))
  return switch encryption {
  case SWIFTMMKV_ENCRYPTION_NONE: .some(nil)
  case SWIFTMMKV_ENCRYPTION_AES128: .aes128(key: key)
  case SWIFTMMKV_ENCRYPTION_AES256: .aes256(key: key)
  default: nil
  }
}

// MARK: - Memory

/// Copies `string` into memory the caller of the C interface owns.
///
/// - Returns: The NUL-terminated copy, and its length in bytes without the terminator.
private func makeCString(_ string: String) -> (pointer: UnsafeMutablePointer<CChar>, length: Int) {
  var string = string
  return string.withUTF8 { utf8 in
    let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count + 1)
    UnsafeMutableRawBufferPointer(start: pointer, count: utf8.count)
      .copyMemory(from: UnsafeRawBufferPointer(utf8))
    pointer[utf8.count] = 0
    return (pointer, utf8.count)
  }
}

@c @implementation
public func swiftmmkv_free(_ pointer: UnsafeMutableRawPointer?) {
  pointer?.deallocate()
}

/// The object behind a `swiftmmkv_string_list`.
private final class StringList {
  let strings: [UnsafeMutablePointer<CChar>]

  init(_ strings: some Sequence<String>) {
    self.strings = strings.map { makeCString($0).pointer }
  }

  deinit {
    for string in self.strings {
      string.deallocate()
    }
  }
}

@c @implementation
public func swiftmmkv_string_list_count(_ list: OpaquePointer) -> Int {
  list.object(StringList.self).strings.count
}

@c @implementation
public func swiftmmkv_string_list_get(_ list: OpaquePointer, _ index: Int) -> UnsafePointer<CChar> {
  UnsafePointer(list.object(StringList.self).strings[index])
}

@c @implementation
public func swiftmmkv_string_list_free(_ list: OpaquePointer?) {
  list?.release(as: StringList.self)
}

// MARK: - Status

/// Runs `body`, and reports what it throws as a status. What it returns goes to `output`.
private func status<T>(
  storingInto output: UnsafeMutablePointer<T>? = nil,
  of body: () throws(MMKVError) -> T
) -> swiftmmkv_status {
  do throws(MMKVError) {
    let value = try body()
    output?.pointee = value
    return SWIFTMMKV_OK
  } catch {
    return switch error {
    case .openFailed: SWIFTMMKV_OPEN_FAILED
    case .invalidEncryptionKey: SWIFTMMKV_INVALID_ENCRYPTION_KEY
    case .rekeyFailed: SWIFTMMKV_REKEY_FAILED
    case .appGroupContainerUnavailable: SWIFTMMKV_APP_GROUP_CONTAINER_UNAVAILABLE
    case .writeFailed: SWIFTMMKV_WRITE_FAILED
    case .storeIsOpen: SWIFTMMKV_STORE_IS_OPEN
    case .storesAreOpen: SWIFTMMKV_STORES_ARE_OPEN
    case .directoryUnreadable: SWIFTMMKV_DIRECTORY_UNREADABLE
    case .backupFailed: SWIFTMMKV_BACKUP_FAILED
    case .restoreFailed: SWIFTMMKV_RESTORE_FAILED
    case .storesNotBackedUp: SWIFTMMKV_STORES_NOT_BACKED_UP
    case .storesNotRestored: SWIFTMMKV_STORES_NOT_RESTORED
    case .backupInvalid: SWIFTMMKV_BACKUP_INVALID
    case .backupIsStoreDirectory: SWIFTMMKV_BACKUP_IS_STORE_DIRECTORY
    case .storeIsSuspended: SWIFTMMKV_STORE_IS_SUSPENDED
    }
  }
}

@c @implementation
public func swiftmmkv_status_message(_ status: swiftmmkv_status) -> UnsafePointer<CChar> {
  let message: StaticString =
    switch status {
    case SWIFTMMKV_OK: "The operation succeeded."
    case SWIFTMMKV_OPEN_FAILED: "The store could not be opened."
    case SWIFTMMKV_INVALID_ENCRYPTION_KEY:
      "The encryption key is empty or longer than its cipher allows."
    case SWIFTMMKV_REKEY_FAILED: "The store could not be re-encrypted."
    case SWIFTMMKV_STORE_IS_OPEN: "The store is open in this process."
    case SWIFTMMKV_STORES_ARE_OPEN: "Some stores are open in this process."
    case SWIFTMMKV_DIRECTORY_UNREADABLE: "The directory's contents cannot be listed."
    case SWIFTMMKV_STORE_IS_SUSPENDED: "The store is suspended."
    case SWIFTMMKV_INVALID_ARGUMENT: "An argument is not a value this version knows."
    case SWIFTMMKV_BACKUP_FAILED: "The store's files could not be copied into the backup."
    case SWIFTMMKV_RESTORE_FAILED:
      "The store could not be overwritten with its copy in the backup."
    case SWIFTMMKV_STORES_NOT_BACKED_UP: "Some stores could not be copied into the backup."
    case SWIFTMMKV_STORES_NOT_RESTORED:
      "Some stores could not be overwritten with their copies in the backup."
    case SWIFTMMKV_BACKUP_INVALID: "The store's copy in the backup does not match its checksum."
    case SWIFTMMKV_BACKUP_IS_STORE_DIRECTORY:
      "The backup directory is the directory the stores are in."
    case SWIFTMMKV_WRITE_FAILED: "The store did not accept a write."
    case SWIFTMMKV_APP_GROUP_CONTAINER_UNAVAILABLE:
      "The app group has no container this process can reach."
    default: "An unknown status."
    }
  // A static string's bytes are NUL-terminated and live for the rest of the process.
  return UnsafeRawPointer(message.utf8Start).assumingMemoryBound(to: CChar.self)
}

// MARK: - Configuration

/// The object behind a `swiftmmkv_configuration`.
private final class Configuration {
  var value: MMKVConfiguration

  /// The options that were last set to a value this version does not know. The setters return
  /// nothing, so these are reported when a store is opened.
  var unknownOptions = Set<PartialKeyPath<MMKVConfiguration>>()

  init(_ value: MMKVConfiguration) {
    self.value = value
  }

  /// Sets `option`, or marks it as unknown if `value` is `nil`.
  func set<V>(_ option: WritableKeyPath<MMKVConfiguration, V>, to value: V?) {
    if let value {
      self.value[keyPath: option] = value
      self.unknownOptions.remove(option)
    } else {
      self.unknownOptions.insert(option)
    }
  }
}

extension OpaquePointer {
  /// The configuration behind a `swiftmmkv_configuration`.
  fileprivate var configuration: Configuration {
    self.object(Configuration.self)
  }
}

@c @implementation
public func swiftmmkv_configuration_create(
  _ directory: UnsafePointer<CChar>,
  _ mode: swiftmmkv_mode
) -> OpaquePointer {
  let configuration = Configuration(
    MMKVConfiguration(directory: MMKVDirectory(directory), mode: .singleProcess)
  )
  configuration.set(\.mode, to: makeMode(mode))
  return OpaquePointer(retaining: configuration)
}

@c @implementation
public func swiftmmkv_configuration_create_temporary() -> OpaquePointer {
  OpaquePointer(retaining: Configuration(.temporary()))
}

@c @implementation
public func swiftmmkv_configuration_destroy(_ configuration: OpaquePointer?) {
  configuration?.release(as: Configuration.self)
}

@c @implementation
public func swiftmmkv_configuration_set_id(
  _ configuration: OpaquePointer,
  _ id: UnsafePointer<CChar>
) {
  configuration.configuration.value.id = MMKVStore.ID(id)
}

@c @implementation
public func swiftmmkv_configuration_set_directory(
  _ configuration: OpaquePointer,
  _ directory: UnsafePointer<CChar>
) {
  configuration.configuration.value.directory = MMKVDirectory(directory)
}

@c @implementation
public func swiftmmkv_configuration_set_mode(_ configuration: OpaquePointer, _ mode: swiftmmkv_mode)
{
  configuration.configuration.set(\.mode, to: makeMode(mode))
}

@c @implementation
public func swiftmmkv_configuration_set_read_only(_ configuration: OpaquePointer, _ readOnly: Bool)
{
  configuration.configuration.value.isReadOnly = readOnly
}

@c @implementation
public func swiftmmkv_configuration_set_encryption(
  _ configuration: OpaquePointer,
  _ encryption: swiftmmkv_encryption,
  _ key: UnsafeRawPointer?,
  _ keyCount: Int
) {
  configuration.configuration.set(\.encryption, to: makeEncryption(encryption, key, keyCount))
}

@c @implementation
public func swiftmmkv_configuration_set_expected_capacity(
  _ configuration: OpaquePointer,
  _ bytes: Int
) {
  configuration.configuration.value.expectedCapacity = bytes
}

@c @implementation
public func swiftmmkv_configuration_set_recovery(
  _ configuration: OpaquePointer,
  _ recovery: swiftmmkv_recovery
) {
  configuration.configuration.set(\.recovery, to: makeRecovery(recovery))
}

@c @implementation
public func swiftmmkv_configuration_set_compare_before_set(
  _ configuration: OpaquePointer,
  _ enabled: Bool
) {
  configuration.configuration.value.compareBeforeSet = enabled
}

@c @implementation
public func swiftmmkv_configuration_set_item_size_limit(
  _ configuration: OpaquePointer,
  _ bytes: Int
) {
  configuration.configuration.value.itemSizeLimit = bytes == 0 ? nil : bytes
}

// MARK: - Stores

@c @implementation
public func swiftmmkv_store_open(
  _ configuration: OpaquePointer,
  _ outStore: UnsafeMutablePointer<OpaquePointer?>
) -> swiftmmkv_status {
  let configuration = configuration.configuration
  guard configuration.unknownOptions.isEmpty else { return SWIFTMMKV_INVALID_ARGUMENT }
  return status(storingInto: outStore) { () throws(MMKVError) in
    OpaquePointer(retaining: try MMKVStore(configuration.value))
  }
}

@c @implementation
public func swiftmmkv_store_close(_ store: OpaquePointer?) {
  store?.release(as: MMKVStore.self)
}

// MARK: - Writes

private func set(
  _ value: some MMKVValue,
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ expiresInSeconds: UInt32
) -> Bool {
  store.store.set(value, forKey: String(cString: key), expiringIn: makeExpiry(expiresInSeconds))
}

@c @implementation
public func swiftmmkv_store_set_bool(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ value: Bool,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(value, store, key, expiresInSeconds)
}

@c @implementation
public func swiftmmkv_store_set_int32(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ value: Int32,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(value, store, key, expiresInSeconds)
}

@c @implementation
public func swiftmmkv_store_set_uint32(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ value: UInt32,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(value, store, key, expiresInSeconds)
}

@c @implementation
public func swiftmmkv_store_set_int64(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ value: Int64,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(value, store, key, expiresInSeconds)
}

@c @implementation
public func swiftmmkv_store_set_uint64(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ value: UInt64,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(value, store, key, expiresInSeconds)
}

@c @implementation
public func swiftmmkv_store_set_float(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ value: Float,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(value, store, key, expiresInSeconds)
}

@c @implementation
public func swiftmmkv_store_set_double(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ value: Double,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(value, store, key, expiresInSeconds)
}

@c @implementation
public func swiftmmkv_store_set_string(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ value: UnsafePointer<CChar>,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(String(cString: value), store, key, expiresInSeconds)
}

@c @implementation
public func swiftmmkv_store_set_bytes(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ bytes: UnsafeRawPointer?,
  _ count: Int,
  _ expiresInSeconds: UInt32
) -> Bool {
  store.store.set(
    unsafeBytes: UnsafeRawBufferPointer(start: bytes, count: bytes == nil ? 0 : count),
    forKey: String(cString: key),
    expiringIn: makeExpiry(expiresInSeconds)
  )
}

@c @implementation
public func swiftmmkv_store_set_strings(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ values: UnsafePointer<UnsafePointer<CChar>>?,
  _ count: Int,
  _ expiresInSeconds: UInt32
) -> Bool {
  set(makeStrings(values, count), store, key, expiresInSeconds)
}

// MARK: - Reads

private func get<V: MMKVValue>(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<V>
) -> Bool {
  guard let value = store.store.value(forKey: String(cString: key), as: V.self) else {
    return false
  }
  outValue.pointee = value
  return true
}

@c @implementation
public func swiftmmkv_store_get_bool(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<Bool>
) -> Bool {
  get(store, key, outValue)
}

@c @implementation
public func swiftmmkv_store_get_int32(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<Int32>
) -> Bool {
  get(store, key, outValue)
}

@c @implementation
public func swiftmmkv_store_get_uint32(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<UInt32>
) -> Bool {
  get(store, key, outValue)
}

@c @implementation
public func swiftmmkv_store_get_int64(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<Int64>
) -> Bool {
  get(store, key, outValue)
}

@c @implementation
public func swiftmmkv_store_get_uint64(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<UInt64>
) -> Bool {
  get(store, key, outValue)
}

@c @implementation
public func swiftmmkv_store_get_float(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<Float>
) -> Bool {
  get(store, key, outValue)
}

@c @implementation
public func swiftmmkv_store_get_double(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<Double>
) -> Bool {
  get(store, key, outValue)
}

@c @implementation
public func swiftmmkv_store_get_string(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValue: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
  _ outLength: UnsafeMutablePointer<Int>?
) -> Bool {
  guard let value = store.store.value(forKey: String(cString: key), as: String.self) else {
    return false
  }
  let (pointer, length) = makeCString(value)
  outValue.pointee = pointer
  outLength?.pointee = length
  return true
}

@c @implementation
public func swiftmmkv_store_get_bytes(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outBytes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
  _ outCount: UnsafeMutablePointer<Int>
) -> Bool {
  let copy = store.store.withUnsafeBytes(forKey: String(cString: key)) { bytes in
    // An empty value still gets an allocation, so that the caller always has one to free.
    let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: max(bytes.count, 1))
    UnsafeMutableRawBufferPointer(start: copy, count: bytes.count).copyMemory(from: bytes)
    return (pointer: copy, count: bytes.count)
  }
  guard let copy else { return false }
  outBytes.pointee = copy.pointer
  outCount.pointee = copy.count
  return true
}

@c @implementation
public func swiftmmkv_store_get_strings(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ outValues: UnsafeMutablePointer<OpaquePointer?>
) -> Bool {
  guard let values = store.store.value(forKey: String(cString: key), as: [String].self) else {
    return false
  }
  outValues.pointee = OpaquePointer(retaining: StringList(values))
  return true
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

@c @implementation
public func swiftmmkv_store_with_exclusive_lock(
  _ store: OpaquePointer,
  _ context: UnsafeMutableRawPointer?,
  _ body: swiftmmkv_locked_callback
) {
  store.store.withExclusiveLock { _ in body(context, store) }
}

// MARK: - Callbacks

/// The context pointer of a C callback, which is released when the last closure that calls
/// the callback is.
///
/// A listener that another thread is in the middle of calling holds on to its closure, so the
/// context outlives every call however a cancellation races with one.
private final class CallbackContext: @unchecked Sendable {
  let pointer: UnsafeMutableRawPointer?
  private let release: swiftmmkv_context_release?

  init(_ pointer: UnsafeMutableRawPointer?, release: swiftmmkv_context_release?) {
    self.pointer = pointer
    self.release = release
  }

  deinit {
    self.release?(self.pointer)
  }
}

/// The object behind a `swiftmmkv_subscription`.
private final class Subscription {
  let value: MMKVSubscription

  init(_ value: MMKVSubscription) {
    self.value = value
  }
}

@c @implementation
public func swiftmmkv_subscription_cancel(_ subscription: OpaquePointer?) {
  guard let subscription else { return }
  subscription.object(Subscription.self).value.cancel()
  subscription.release(as: Subscription.self)
}

// MARK: - Changes

/// Subscribes a C callback to the changes of a store, or to those that `key` is part of. The
/// callback is lent each key for the length of its call.
private func subscribe(
  _ store: OpaquePointer,
  key: String? = nil,
  _ context: UnsafeMutableRawPointer?,
  _ onChange: swiftmmkv_change_callback,
  _ release: swiftmmkv_context_release?
) -> OpaquePointer {
  let context = CallbackContext(context, release: release)
  let subscription = store.store.subscribe { change in
    switch change {
    case .key(let changed):
      guard key == nil || key == changed else { return }
      changed.withCString { onChange(context.pointer, SWIFTMMKV_CHANGE_KEY, $0) }
    case .external:
      onChange(context.pointer, SWIFTMMKV_CHANGE_EXTERNAL, nil)
    }
  }
  return OpaquePointer(retaining: Subscription(subscription))
}

@c @implementation
public func swiftmmkv_store_subscribe(
  _ store: OpaquePointer,
  _ context: UnsafeMutableRawPointer?,
  _ onChange: swiftmmkv_change_callback,
  _ release: swiftmmkv_context_release?
) -> OpaquePointer {
  subscribe(store, context, onChange, release)
}

@c @implementation
public func swiftmmkv_store_subscribe_key(
  _ store: OpaquePointer,
  _ key: UnsafePointer<CChar>,
  _ context: UnsafeMutableRawPointer?,
  _ onChange: swiftmmkv_change_callback,
  _ release: swiftmmkv_context_release?
) -> OpaquePointer {
  subscribe(store, key: String(cString: key), context, onChange, release)
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
    return SWIFTMMKV_INVALID_ARGUMENT
  }
  return status { () throws(MMKVError) in try store.store.rekey(encryption) }
}

@c @implementation
public func swiftmmkv_store_back_up(
  _ store: OpaquePointer,
  _ backup: UnsafePointer<CChar>
) -> swiftmmkv_status {
  status { () throws(MMKVError) in try store.store.backUp(to: MMKVDirectory(backup)) }
}

@c @implementation
public func swiftmmkv_store_restore(
  _ store: OpaquePointer,
  _ backup: UnsafePointer<CChar>,
  _ outRestored: UnsafeMutablePointer<Bool>?
) -> swiftmmkv_status {
  status(storingInto: outRestored) { () throws(MMKVError) in
    try store.store.restore(from: MMKVDirectory(backup))
  }
}

// MARK: - Directories

@c @implementation
public func swiftmmkv_directory_contains_store(
  _ directory: UnsafePointer<CChar>,
  _ id: UnsafePointer<CChar>
) -> Bool {
  MMKVDirectory(directory).containsStore(id: MMKVStore.ID(id))
}

@c @implementation
public func swiftmmkv_directory_is_store_valid(
  _ directory: UnsafePointer<CChar>,
  _ id: UnsafePointer<CChar>
) -> Bool {
  MMKVDirectory(directory).isStoreValid(id: MMKVStore.ID(id))
}

@c @implementation
public func swiftmmkv_directory_remove_store(
  _ directory: UnsafePointer<CChar>,
  _ id: UnsafePointer<CChar>,
  _ outRemoved: UnsafeMutablePointer<Bool>?
) -> swiftmmkv_status {
  status(storingInto: outRemoved) { () throws(MMKVError) in
    try MMKVDirectory(directory).removeStore(id: MMKVStore.ID(id))
  }
}

@c @implementation
public func swiftmmkv_directory_remove_all_stores(
  _ directory: UnsafePointer<CChar>,
  _ outCount: UnsafeMutablePointer<Int>?
) -> swiftmmkv_status {
  status(storingInto: outCount) { () throws(MMKVError) in
    try MMKVDirectory(directory).removeAllStores()
  }
}

@c @implementation
public func swiftmmkv_directory_back_up_store(
  _ directory: UnsafePointer<CChar>,
  _ id: UnsafePointer<CChar>,
  _ backup: UnsafePointer<CChar>,
  _ outBackedUp: UnsafeMutablePointer<Bool>?
) -> swiftmmkv_status {
  status(storingInto: outBackedUp) { () throws(MMKVError) in
    try MMKVDirectory(directory).backUpStore(id: MMKVStore.ID(id), to: MMKVDirectory(backup))
  }
}

@c @implementation
public func swiftmmkv_directory_back_up_all_stores(
  _ directory: UnsafePointer<CChar>,
  _ backup: UnsafePointer<CChar>,
  _ outCount: UnsafeMutablePointer<Int>?
) -> swiftmmkv_status {
  status(storingInto: outCount) { () throws(MMKVError) in
    try MMKVDirectory(directory).backUpAllStores(to: MMKVDirectory(backup))
  }
}

@c @implementation
public func swiftmmkv_directory_restore_store(
  _ directory: UnsafePointer<CChar>,
  _ id: UnsafePointer<CChar>,
  _ backup: UnsafePointer<CChar>,
  _ outRestored: UnsafeMutablePointer<Bool>?
) -> swiftmmkv_status {
  status(storingInto: outRestored) { () throws(MMKVError) in
    try MMKVDirectory(directory).restoreStore(id: MMKVStore.ID(id), from: MMKVDirectory(backup))
  }
}

@c @implementation
public func swiftmmkv_directory_restore_all_stores(
  _ directory: UnsafePointer<CChar>,
  _ backup: UnsafePointer<CChar>,
  _ outCount: UnsafeMutablePointer<Int>?
) -> swiftmmkv_status {
  status(storingInto: outCount) { () throws(MMKVError) in
    try MMKVDirectory(directory).restoreAllStores(from: MMKVDirectory(backup))
  }
}

// MARK: - Logging

@c @implementation
public func swiftmmkv_log_minimum_level() -> swiftmmkv_log_level {
  MMKVLog.minimumLevel.map { swiftmmkv_log_level($0.rawValue) } ?? SWIFTMMKV_LOG_NONE
}

@c @implementation
public func swiftmmkv_log_set_minimum_level(_ level: swiftmmkv_log_level) {
  if level == SWIFTMMKV_LOG_NONE {
    MMKVLog.minimumLevel = nil
  } else if let level = MMKVLog.Level(rawValue: Int(level)) {
    MMKVLog.minimumLevel = level
  }
}

@c @implementation
public func swiftmmkv_log_set_handler(
  _ context: UnsafeMutableRawPointer?,
  _ handler: swiftmmkv_log_callback?,
  _ release: swiftmmkv_context_release?
) {
  // Without a handler nothing holds on to the context, which releases it straight away.
  let context = CallbackContext(context, release: release)
  guard let handler else { return MMKVLog.setHandler(nil) }
  MMKVLog.setHandler { message in
    message.text.withCString { text in
      message.file.withCString { file in
        message.function.withCString { function in
          handler(
            context.pointer,
            swiftmmkv_log_level(message.level.rawValue),
            text,
            file,
            function,
            Int32(clamping: message.line)
          )
        }
      }
    }
  }
}

// MARK: - Integrity Failures

@c @implementation
public func swiftmmkv_subscribe_to_integrity_failures(
  _ context: UnsafeMutableRawPointer?,
  _ onFailure: swiftmmkv_integrity_failure_callback,
  _ release: swiftmmkv_context_release?
) -> OpaquePointer {
  let context = CallbackContext(context, release: release)
  let subscription = MMKVStore.subscribeToIntegrityFailures { failure in
    let kind =
      switch failure.kind {
      case .checksum: SWIFTMMKV_INTEGRITY_FAILURE_CHECKSUM
      case .fileLength: SWIFTMMKV_INTEGRITY_FAILURE_FILE_LENGTH
      }
    failure.id.rawValue.withCString { onFailure(context.pointer, $0, kind) }
  }
  return OpaquePointer(retaining: Subscription(subscription))
}
