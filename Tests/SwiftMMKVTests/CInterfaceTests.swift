import CSwiftMMKV
import Foundation
import SwiftMMKV
import Testing

/// The C interface, called the way a binding in another language would call it.
@Suite struct CInterfaceTests {
  // MARK: - Version And Status

  @Test func `Reports The Version Of The Header It Was Built With`() {
    #expect(swiftmmkv_abi_version() == UInt32(SWIFTMMKV_ABI_VERSION))
  }

  @Test func `Every Status Has A Message Of Its Own`() {
    let statuses = code(SWIFTMMKV_OK)...code(SWIFTMMKV_APP_GROUP_CONTAINER_UNAVAILABLE)
    let messages = statuses.map { String(cString: swiftmmkv_status_message($0)) }
    let unknown = String(cString: swiftmmkv_status_message(9999))

    #expect(Set(messages).count == messages.count)
    #expect(!messages.contains(unknown))
    #expect(!messages.contains(""))
    #expect(!unknown.isEmpty)
  }

  // MARK: - Configuration

  @Test func `Opens A Store In A Temporary Directory`() throws {
    let configuration = swiftmmkv_configuration_create_temporary()
    var handle: OpaquePointer?
    let status = swiftmmkv_store_open(configuration, &handle)
    swiftmmkv_configuration_destroy(configuration)
    defer { swiftmmkv_store_close(handle) }

    #expect(status == code(SWIFTMMKV_OK))
    let store = try #require(handle)
    #expect(swiftmmkv_store_count(store) == 0)
    #expect(swiftmmkv_store_set_bool(store, "flag", true, 0) == true)
    #expect(swiftmmkv_store_count(store) == 1)
  }

  @Test func `A Store Opened Twice Shares Its Contents`() throws {
    let directory = temporaryRootDirectory()
    let first = try CStore(id: "shared", directory: directory)
    defer { first.close() }
    let second = try CStore(id: "shared", directory: directory)
    defer { second.close() }

    #expect(swiftmmkv_store_set_string(first.handle, "username", "blob", 0) == true)

    #expect(second.string(forKey: "username") == "blob")
    #expect(try makeStore(id: "shared", rootDirectory: directory)["username"] == "blob")
  }

  @Test func `An Unknown Mode Fails The Open Until It Is Replaced`() {
    let configuration = swiftmmkv_configuration_create(temporaryRootDirectory(), 99)
    defer { swiftmmkv_configuration_destroy(configuration) }
    var handle: OpaquePointer?
    defer { swiftmmkv_store_close(handle) }

    #expect(swiftmmkv_store_open(configuration, &handle) == code(SWIFTMMKV_INVALID_ARGUMENT))
    #expect(handle == nil)

    swiftmmkv_configuration_set_mode(configuration, code(SWIFTMMKV_MODE_MULTI_PROCESS))
    #expect(swiftmmkv_store_open(configuration, &handle) == code(SWIFTMMKV_OK))
    #expect(handle != nil)
  }

  @Test func `An Unknown Cipher Or Recovery Fails The Open`() {
    #expect(throws: CStatusError(status: code(SWIFTMMKV_INVALID_ARGUMENT))) {
      try CStore { swiftmmkv_configuration_set_encryption($0, 99, "key", 3) }
    }
    #expect(throws: CStatusError(status: code(SWIFTMMKV_INVALID_ARGUMENT))) {
      try CStore { swiftmmkv_configuration_set_recovery($0, 99) }
    }
  }

  @Test func `An Encryption Key Of The Wrong Length Fails The Open`() {
    #expect(throws: CStatusError(status: code(SWIFTMMKV_INVALID_ENCRYPTION_KEY))) {
      try CStore {
        swiftmmkv_configuration_set_encryption($0, code(SWIFTMMKV_ENCRYPTION_AES128), nil, 0)
      }
    }
    #expect(throws: CStatusError(status: code(SWIFTMMKV_INVALID_ENCRYPTION_KEY))) {
      try CStore {
        let key = [UInt8](repeating: 1, count: 17)
        swiftmmkv_configuration_set_encryption(
          $0,
          code(SWIFTMMKV_ENCRYPTION_AES128),
          key,
          key.count
        )
      }
    }
  }

  @Test func `An Empty Identifier Fails The Open`() {
    #expect(throws: CStatusError(status: code(SWIFTMMKV_OPEN_FAILED))) {
      try CStore(id: "")
    }
  }

  @Test func `The Directory Can Be Replaced Before Opening`() throws {
    let directory = temporaryRootDirectory()
    let store = try CStore(id: "moved", directory: temporaryRootDirectory()) {
      swiftmmkv_configuration_set_directory($0, directory)
    }
    defer { store.close() }

    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == true)
    #expect(swiftmmkv_directory_contains_store(directory, "moved") == true)
  }

  @Test func `An Encrypted Store Keeps Its Values Out Of Its File`() throws {
    let directory = temporaryRootDirectory()
    let marker = "plain-text-marker"
    let plain = try CStore(id: "plain", directory: directory)
    defer { plain.close() }
    let encrypted = try CStore(id: "encrypted", directory: directory) {
      let key = Array("secret".utf8)
      swiftmmkv_configuration_set_encryption(
        $0,
        code(SWIFTMMKV_ENCRYPTION_AES256),
        key,
        key.count
      )
    }
    defer { encrypted.close() }

    #expect(swiftmmkv_store_set_string(plain.handle, "key", marker, 0) == true)
    #expect(swiftmmkv_store_set_string(encrypted.handle, "key", marker, 0) == true)

    #expect(encrypted.string(forKey: "key") == marker)
    let plainFile = try Data(contentsOf: URL(fileURLWithPath: "\(directory)/plain"))
    let encryptedFile = try Data(contentsOf: URL(fileURLWithPath: "\(directory)/encrypted"))
    #expect(plainFile.range(of: Data(marker.utf8)) != nil)
    #expect(encryptedFile.range(of: Data(marker.utf8)) == nil)
  }

  @Test func `A Read Only Store Reads But Does Not Write`() throws {
    let directory = temporaryRootDirectory()
    try makeUnopenedStoreFiles(at: "\(directory)/frozen")
    let store = try CStore(id: "frozen", directory: directory) {
      swiftmmkv_configuration_set_read_only($0, true)
    }
    defer { store.close() }

    #expect(store.string(forKey: "key") == "value")
    #expect(swiftmmkv_store_set_string(store.handle, "key", "changed", 0) == false)
    #expect(store.string(forKey: "key") == "value")
  }

  @Test func `The Item Size Limit Turns Large Values Away`() throws {
    let store = try CStore {
      swiftmmkv_configuration_set_item_size_limit($0, 64)
      swiftmmkv_configuration_set_compare_before_set($0, true)
      swiftmmkv_configuration_set_recovery($0, code(SWIFTMMKV_RECOVERY_RECOVER))
    }

    #expect(swiftmmkv_store_set_string(store.handle, "small", "value", 0) == true)
    #expect(
      swiftmmkv_store_set_string(store.handle, "large", String(repeating: "x", count: 256), 0)
        == false
    )
    #expect(swiftmmkv_store_contains(store.handle, "small") == true)
    #expect(swiftmmkv_store_contains(store.handle, "large") == false)
  }

  @Test func `The Expected Capacity Sizes The File`() throws {
    let store = try CStore {
      swiftmmkv_configuration_set_expected_capacity($0, 1 << 20)
    }

    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == true)
    #expect(swiftmmkv_store_byte_size(store.handle) >= 1 << 20)
  }

  // MARK: - Values

  @Test func `Scalars Round Trip`() throws {
    let store = try CStore()
    defer { store.close() }

    #expect(swiftmmkv_store_set_bool(store.handle, "bool", true, 0) == true)
    #expect(swiftmmkv_store_set_int32(store.handle, "int32", .min, 0) == true)
    #expect(swiftmmkv_store_set_uint32(store.handle, "uint32", .max, 0) == true)
    #expect(swiftmmkv_store_set_int64(store.handle, "int64", .min, 0) == true)
    #expect(swiftmmkv_store_set_uint64(store.handle, "uint64", .max, 0) == true)
    #expect(swiftmmkv_store_set_float(store.handle, "float", 1.5, 0) == true)
    #expect(swiftmmkv_store_set_double(store.handle, "double", -2.25, 0) == true)

    var bool = false
    var int32: Int32 = 0
    var uint32: UInt32 = 0
    var int64: Int64 = 0
    var uint64: UInt64 = 0
    var float: Float = 0
    var double: Double = 0
    #expect(swiftmmkv_store_get_bool(store.handle, "bool", &bool) == true)
    #expect(swiftmmkv_store_get_int32(store.handle, "int32", &int32) == true)
    #expect(swiftmmkv_store_get_uint32(store.handle, "uint32", &uint32) == true)
    #expect(swiftmmkv_store_get_int64(store.handle, "int64", &int64) == true)
    #expect(swiftmmkv_store_get_uint64(store.handle, "uint64", &uint64) == true)
    #expect(swiftmmkv_store_get_float(store.handle, "float", &float) == true)
    #expect(swiftmmkv_store_get_double(store.handle, "double", &double) == true)
    #expect(bool)
    #expect(int32 == .min)
    #expect(uint32 == .max)
    #expect(int64 == .min)
    #expect(uint64 == .max)
    #expect(float == 1.5)
    #expect(double == -2.25)
  }

  @Test func `A Missing Key Reads Nothing And Leaves The Output Alone`() throws {
    let store = try CStore()
    defer { store.close() }

    var bool = true
    var int32: Int32 = 7
    var uint32: UInt32 = 7
    var int64: Int64 = 7
    var uint64: UInt64 = 7
    var float: Float = 7
    var double: Double = 7
    var string: UnsafeMutablePointer<CChar>?
    var length = 7
    var bytes: UnsafeMutablePointer<UInt8>?
    var count = 7
    var strings: OpaquePointer?
    #expect(swiftmmkv_store_get_bool(store.handle, "missing", &bool) == false)
    #expect(swiftmmkv_store_get_int32(store.handle, "missing", &int32) == false)
    #expect(swiftmmkv_store_get_uint32(store.handle, "missing", &uint32) == false)
    #expect(swiftmmkv_store_get_int64(store.handle, "missing", &int64) == false)
    #expect(swiftmmkv_store_get_uint64(store.handle, "missing", &uint64) == false)
    #expect(swiftmmkv_store_get_float(store.handle, "missing", &float) == false)
    #expect(swiftmmkv_store_get_double(store.handle, "missing", &double) == false)
    #expect(swiftmmkv_store_get_string(store.handle, "missing", &string, &length) == false)
    #expect(swiftmmkv_store_get_bytes(store.handle, "missing", &bytes, &count) == false)
    #expect(swiftmmkv_store_get_strings(store.handle, "missing", &strings) == false)
    #expect(bool)
    #expect(int32 == 7)
    #expect(uint32 == 7)
    #expect(int64 == 7)
    #expect(uint64 == 7)
    #expect(float == 7)
    #expect(double == 7)
    #expect(string == nil)
    #expect(length == 7)
    #expect(bytes == nil)
    #expect(count == 7)
    #expect(strings == nil)
  }

  @Test func `Strings Round Trip With Their Length In Bytes`() throws {
    let store = try CStore()
    defer { store.close() }
    let text = "héllo wörld 👋"

    #expect(swiftmmkv_store_set_string(store.handle, "greeting", text, 0) == true)

    var value: UnsafeMutablePointer<CChar>?
    var length = 0
    #expect(swiftmmkv_store_get_string(store.handle, "greeting", &value, &length) == true)
    defer { swiftmmkv_free(value) }
    #expect(String(cString: try #require(value)) == text)
    #expect(length == text.utf8.count)
  }

  @Test func `A String With An Embedded NUL Reports Its Whole Length`() throws {
    let directory = temporaryRootDirectory()
    let store = try CStore(directory: directory)
    defer { store.close() }
    try makeStore(rootDirectory: directory).set("a\0b", forKey: "text")

    var value: UnsafeMutablePointer<CChar>?
    var length = 0
    #expect(swiftmmkv_store_get_string(store.handle, "text", &value, &length) == true)
    defer { swiftmmkv_free(value) }
    let pointer = try #require(value)
    #expect(length == 3)
    #expect(strlen(pointer) == 1)
    #expect(pointer[2] == CChar(UInt8(ascii: "b")))
    #expect(pointer[3] == 0)
  }

  @Test func `Bytes Round Trip`() throws {
    let store = try CStore()
    defer { store.close() }
    let payload: [UInt8] = [0, 1, 2, 255, 0]

    #expect(swiftmmkv_store_set_bytes(store.handle, "payload", payload, payload.count, 0) == true)

    var bytes: UnsafeMutablePointer<UInt8>?
    var count = 0
    #expect(swiftmmkv_store_get_bytes(store.handle, "payload", &bytes, &count) == true)
    defer { swiftmmkv_free(bytes) }
    #expect(Array(UnsafeBufferPointer(start: bytes, count: count)) == payload)
  }

  @Test func `Empty Bytes Are A Value With An Allocation To Free`() throws {
    let store = try CStore()
    defer { store.close() }

    #expect(swiftmmkv_store_set_bytes(store.handle, "empty", nil, 0, 0) == true)

    var bytes: UnsafeMutablePointer<UInt8>?
    var count = 7
    #expect(swiftmmkv_store_get_bytes(store.handle, "empty", &bytes, &count) == true)
    defer { swiftmmkv_free(bytes) }
    #expect(bytes != nil)
    #expect(count == 0)
  }

  @Test func `String Arrays Round Trip`() throws {
    let store = try CStore()
    defer { store.close() }

    #expect(
      withCStrings(["a", "", "ünï"]) {
        swiftmmkv_store_set_strings(store.handle, "tags", $0, $1, 0)
      }
    )
    #expect(swiftmmkv_store_set_strings(store.handle, "none", nil, 0, 0) == true)

    var tags: OpaquePointer?
    var none: OpaquePointer?
    #expect(swiftmmkv_store_get_strings(store.handle, "tags", &tags) == true)
    #expect(swiftmmkv_store_get_strings(store.handle, "none", &none) == true)
    #expect(takeStrings(try #require(tags)) == ["a", "", "ünï"])
    #expect(takeStrings(try #require(none)) == [])
  }

  @Test func `Values Are The Ones The Swift Interface Reads And Writes`() throws {
    let directory = temporaryRootDirectory()
    let store = try CStore(directory: directory)
    defer { store.close() }
    let swiftStore = try makeStore(rootDirectory: directory)

    #expect(swiftmmkv_store_set_double(store.handle, "volume", 0.5, 0) == true)
    #expect(swiftmmkv_store_set_string(store.handle, "username", "blob", 0) == true)
    swiftStore.set(Int64(42), forKey: "answer")

    var answer: Int64 = 0
    #expect(swiftStore.value(forKey: "volume", as: Double.self) == 0.5)
    #expect(swiftStore.value(forKey: "username", as: String.self) == "blob")
    #expect(swiftmmkv_store_get_int64(store.handle, "answer", &answer) == true)
    #expect(answer == 42)
  }

  @Test func `A Value With An Expiry Is Stored`() throws {
    let store = try CStore()
    defer { store.close() }

    #expect(swiftmmkv_store_set_string(store.handle, "token", "abc", 3600) == true)

    #expect(store.string(forKey: "token") == "abc")
  }

  @Test func `Freeing Nothing Does Nothing`() {
    swiftmmkv_free(nil)
    swiftmmkv_string_list_free(nil)
    swiftmmkv_configuration_destroy(nil)
    swiftmmkv_store_close(nil)
    swiftmmkv_subscription_cancel(nil)
  }

  // MARK: - Keys And Removal

  @Test func `Lists Counts And Removes Keys`() throws {
    let store = try CStore()
    defer { store.close() }
    for key in ["a", "b", "c", "d"] {
      #expect(swiftmmkv_store_set_int32(store.handle, key, 1, 0) == true)
    }

    #expect(swiftmmkv_store_count(store.handle) == 4)
    #expect(swiftmmkv_store_contains(store.handle, "a") == true)
    #expect(swiftmmkv_store_contains(store.handle, "z") == false)
    #expect(takeStrings(swiftmmkv_store_keys(store.handle)).sorted() == ["a", "b", "c", "d"])

    #expect(swiftmmkv_store_remove(store.handle, "a") == true)
    #expect(swiftmmkv_store_contains(store.handle, "a") == false)

    withCStrings(["b", "c", "missing"]) { swiftmmkv_store_remove_many(store.handle, $0, $1) }
    swiftmmkv_store_remove_many(store.handle, nil, 0)
    #expect(takeStrings(swiftmmkv_store_keys(store.handle)) == ["d"])

    swiftmmkv_store_remove_all(store.handle, true)
    #expect(swiftmmkv_store_count(store.handle) == 0)
    #expect(takeStrings(swiftmmkv_store_keys(store.handle)) == [])
  }

  @Test func `Imports The Contents Of Another Store`() throws {
    let source = try CStore()
    defer { source.close() }
    let destination = try CStore()
    defer { destination.close() }
    #expect(swiftmmkv_store_set_string(source.handle, "a", "from source", 0) == true)
    #expect(swiftmmkv_store_set_string(source.handle, "b", "from source", 0) == true)
    #expect(swiftmmkv_store_set_string(destination.handle, "b", "from destination", 0) == true)
    #expect(swiftmmkv_store_set_string(destination.handle, "c", "from destination", 0) == true)

    #expect(swiftmmkv_store_import_all(destination.handle, source.handle) == 2)

    #expect(takeStrings(swiftmmkv_store_keys(destination.handle)).sorted() == ["a", "b", "c"])
    var value: UnsafeMutablePointer<CChar>?
    #expect(swiftmmkv_store_get_string(destination.handle, "b", &value, nil) == true)
    defer { swiftmmkv_free(value) }
    #expect(String(cString: try #require(value)) == "from source")
  }

  // MARK: - Exclusive Access

  @Test func `Runs A Read Modify Write With The Lock Held`() throws {
    let store = try CStore()
    defer { store.close() }
    var calls = 0

    for _ in 0..<3 {
      swiftmmkv_store_with_exclusive_lock(store.handle, &calls) { context, locked in
        context!.assumingMemoryBound(to: Int.self).pointee += 1
        var count: Int32 = 0
        _ = swiftmmkv_store_get_int32(locked, "count", &count)
        _ = swiftmmkv_store_set_int32(locked, "count", count + 1, 0)
        // The lock is recursive.
        swiftmmkv_store_with_exclusive_lock(locked, nil) { _, nested in
          _ = swiftmmkv_store_set_bool(nested, "nested", true, 0)
        }
      }
    }

    var count: Int32 = 0
    #expect(calls == 3)
    #expect(swiftmmkv_store_get_int32(store.handle, "count", &count) == true)
    #expect(count == 3)
    #expect(swiftmmkv_store_contains(store.handle, "nested") == true)
  }

  @Test func `Listeners Hear Of A Locked Batch Once It Is Done`() throws {
    let store = try CStore()
    defer { store.close() }
    let recorder = CCallbackRecorder()
    let subscription = swiftmmkv_store_subscribe(
      store.handle,
      recorder.context,
      CCallbackRecorder.onChange,
      CCallbackRecorder.release
    )
    defer { swiftmmkv_subscription_cancel(subscription) }

    swiftmmkv_store_with_exclusive_lock(store.handle, recorder.context) { context, locked in
      let recorder = Unmanaged<CCallbackRecorder>.fromOpaque(context!).takeUnretainedValue()
      _ = swiftmmkv_store_set_int32(locked, "a", 1, 0)
      _ = swiftmmkv_store_set_int32(locked, "a", 2, 0)
      _ = swiftmmkv_store_set_int32(locked, "b", 1, 0)
      recorder.record("body done")
    }

    #expect(recorder.events.first == "body done")
    #expect(recorder.events.dropFirst().sorted() == ["key:a", "key:b"])
  }

  // MARK: - Changes

  @Test func `A Subscription Hears Of Every Key Until It Is Cancelled`() throws {
    let store = try CStore()
    defer { store.close() }
    let recorder = CCallbackRecorder()
    let subscription = swiftmmkv_store_subscribe(
      store.handle,
      recorder.context,
      CCallbackRecorder.onChange,
      CCallbackRecorder.release
    )

    #expect(swiftmmkv_store_set_string(store.handle, "username", "blob", 0) == true)
    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == true)
    #expect(swiftmmkv_store_remove(store.handle, "username") == true)
    #expect(recorder.events == ["key:username", "key:flag", "key:username"])
    #expect(recorder.releases == 0)

    swiftmmkv_subscription_cancel(subscription)
    #expect(recorder.releases == 1)

    #expect(swiftmmkv_store_set_bool(store.handle, "flag", false, 0) == true)
    #expect(recorder.events.count == 3)
    #expect(recorder.releases == 1)
  }

  @Test func `A Key Subscription Only Hears Of Its Key`() throws {
    let store = try CStore()
    defer { store.close() }
    let recorder = CCallbackRecorder()
    let subscription = swiftmmkv_store_subscribe_key(
      store.handle,
      "username",
      recorder.context,
      CCallbackRecorder.onChange,
      CCallbackRecorder.release
    )

    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == true)
    #expect(swiftmmkv_store_set_string(store.handle, "username", "blob", 0) == true)
    #expect(recorder.events == ["key:username"])

    swiftmmkv_subscription_cancel(subscription)
    #expect(recorder.releases == 1)
  }

  @Test func `A Subscription Works Without A Context Or A Release`() throws {
    let store = try CStore()
    defer { store.close() }
    let subscription = swiftmmkv_store_subscribe(store.handle, nil, { _, _, _ in }, nil)

    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == true)

    swiftmmkv_subscription_cancel(subscription)
  }

  @Test func `Subscriptions Hear Of Changes From Outside`() throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)
    let configuration = first.configuration
    let store = try CStore(
      id: configuration.id.rawValue,
      directory: configuration.directory.path,
      mode: SWIFTMMKV_MODE_MULTI_PROCESS
    )
    defer { store.close() }
    let recorder = CCallbackRecorder()
    let all = swiftmmkv_store_subscribe(
      store.handle,
      recorder.context,
      CCallbackRecorder.onChange,
      CCallbackRecorder.release
    )
    let keyed = swiftmmkv_store_subscribe_key(
      store.handle,
      "username",
      recorder.context,
      CCallbackRecorder.onChange,
      CCallbackRecorder.release
    )
    defer {
      swiftmmkv_subscription_cancel(all)
      swiftmmkv_subscription_cancel(keyed)
    }

    second.set("blob", forKey: "other")
    swiftmmkv_store_check_for_external_changes(store.handle)

    #expect(recorder.events == ["external", "external"])
  }

  // MARK: - Suspension

  @Test func `A Suspended Store Turns Operations Away Until It Is Resumed`() throws {
    let store = try CStore(
      id: "suspension-\(UUID().uuidString)",
      mode: SWIFTMMKV_MODE_MULTI_PROCESS
    )
    defer { store.close() }
    #expect(swiftmmkv_store_set_string(store.handle, "username", "blob", 0) == true)
    #expect(swiftmmkv_store_is_suspended(store.handle) == false)

    swiftmmkv_store_suspend(store.handle)

    let key = Array("secret".utf8)
    #expect(swiftmmkv_store_is_suspended(store.handle) == true)
    #expect(store.string(forKey: "username") == nil)
    #expect(swiftmmkv_store_set_string(store.handle, "username", "changed", 0) == false)
    #expect(swiftmmkv_store_count(store.handle) == 0)
    #expect(
      swiftmmkv_store_rekey(store.handle, code(SWIFTMMKV_ENCRYPTION_AES128), key, key.count)
        == code(SWIFTMMKV_STORE_IS_SUSPENDED)
    )
    #expect(
      swiftmmkv_store_back_up(store.handle, temporaryRootDirectory())
        == code(SWIFTMMKV_STORE_IS_SUSPENDED)
    )

    swiftmmkv_store_resume(store.handle)

    #expect(swiftmmkv_store_is_suspended(store.handle) == false)
    #expect(store.string(forKey: "username") == "blob")
  }

  @Test func `A Single Process Store Is Never Suspended`() throws {
    let store = try CStore()
    defer { store.close() }

    swiftmmkv_store_suspend(store.handle)

    #expect(swiftmmkv_store_is_suspended(store.handle) == false)
    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == true)
    swiftmmkv_store_resume(store.handle)
  }

  // MARK: - Maintenance

  @Test func `Reports Sizes And Survives A Trim And A Sync`() throws {
    let store = try CStore()
    defer { store.close() }
    #expect(swiftmmkv_store_set_string(store.handle, "username", "blob", 0) == true)

    #expect(swiftmmkv_store_byte_size(store.handle) > 0)
    #expect(swiftmmkv_store_used_byte_size(store.handle) > 0)
    #expect(
      swiftmmkv_store_used_byte_size(store.handle) <= swiftmmkv_store_byte_size(store.handle)
    )

    swiftmmkv_store_trim(store.handle)
    swiftmmkv_store_sync(store.handle)

    #expect(store.string(forKey: "username") == "blob")
  }

  @Test func `Rekeys A Store And Keeps Its Values`() throws {
    let directory = temporaryRootDirectory()
    let store = try CStore(directory: directory)
    defer { store.close() }
    let marker = "plain-text-marker"
    let path = URL(fileURLWithPath: "\(directory)/mmkv.default")
    let key = Array("secret".utf8)
    #expect(swiftmmkv_store_set_string(store.handle, "key", marker, 0) == true)

    #expect(
      swiftmmkv_store_rekey(store.handle, code(SWIFTMMKV_ENCRYPTION_AES256), key, key.count)
        == code(SWIFTMMKV_OK)
    )
    #expect(store.string(forKey: "key") == marker)
    #expect(try Data(contentsOf: path).range(of: Data(marker.utf8)) == nil)

    #expect(
      swiftmmkv_store_rekey(store.handle, code(SWIFTMMKV_ENCRYPTION_NONE), nil, 0)
        == code(SWIFTMMKV_OK)
    )
    #expect(store.string(forKey: "key") == marker)
    #expect(try Data(contentsOf: path).range(of: Data(marker.utf8)) != nil)
  }

  @Test func `Rekeying Reports What Is Wrong With Its Arguments`() throws {
    let store = try CStore()
    defer { store.close() }

    #expect(swiftmmkv_store_rekey(store.handle, 99, "key", 3) == code(SWIFTMMKV_INVALID_ARGUMENT))
    #expect(
      swiftmmkv_store_rekey(store.handle, code(SWIFTMMKV_ENCRYPTION_AES128), nil, 0)
        == code(SWIFTMMKV_INVALID_ENCRYPTION_KEY)
    )
  }

  // MARK: - Backups

  @Test func `Backs Up And Restores A Store`() throws {
    let directory = temporaryRootDirectory()
    let backup = temporaryRootDirectory()
    let store = try CStore(id: "settings", directory: directory)
    defer { store.close() }
    #expect(swiftmmkv_store_set_string(store.handle, "username", "blob", 0) == true)

    #expect(swiftmmkv_store_back_up(store.handle, backup) == code(SWIFTMMKV_OK))
    #expect(swiftmmkv_directory_contains_store(backup, "settings") == true)
    #expect(swiftmmkv_directory_is_store_valid(backup, "settings") == true)

    #expect(swiftmmkv_store_set_string(store.handle, "username", "changed", 0) == true)
    var didRestore = false
    #expect(swiftmmkv_store_restore(store.handle, backup, &didRestore) == code(SWIFTMMKV_OK))
    #expect(didRestore)
    #expect(store.string(forKey: "username") == "blob")

    #expect(swiftmmkv_store_restore(store.handle, backup, nil) == code(SWIFTMMKV_OK))
  }

  @Test func `Restoring From A Directory Without A Copy Restores Nothing`() throws {
    let store = try CStore()
    defer { store.close() }
    #expect(swiftmmkv_store_set_string(store.handle, "username", "blob", 0) == true)

    var didRestore = true
    #expect(
      swiftmmkv_store_restore(store.handle, temporaryRootDirectory(), &didRestore)
        == code(SWIFTMMKV_OK)
    )

    #expect(!didRestore)
    #expect(store.string(forKey: "username") == "blob")
  }

  @Test func `A Store Cannot Be Backed Up Into Its Own Directory`() throws {
    let directory = temporaryRootDirectory()
    let store = try CStore(directory: directory)
    defer { store.close() }
    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == true)

    var didRestore = true
    #expect(
      swiftmmkv_store_back_up(store.handle, directory)
        == code(SWIFTMMKV_BACKUP_IS_STORE_DIRECTORY)
    )
    #expect(
      swiftmmkv_store_restore(store.handle, directory, &didRestore)
        == code(SWIFTMMKV_BACKUP_IS_STORE_DIRECTORY)
    )
    #expect(didRestore)
  }

  // MARK: - Directories

  @Test func `Finds Checks And Removes The Stores Of A Directory`() throws {
    let directory = temporaryRootDirectory()
    try makeUnopenedStoreFiles(at: "\(directory)/first")

    #expect(swiftmmkv_directory_contains_store(directory, "first") == true)
    #expect(swiftmmkv_directory_is_store_valid(directory, "first") == true)
    #expect(swiftmmkv_directory_contains_store(directory, "second") == false)
    #expect(swiftmmkv_directory_is_store_valid(directory, "second") == false)

    var didRemove = false
    #expect(
      swiftmmkv_directory_remove_store(directory, "first", &didRemove) == code(SWIFTMMKV_OK)
    )
    #expect(didRemove)
    #expect(swiftmmkv_directory_contains_store(directory, "first") == false)

    #expect(
      swiftmmkv_directory_remove_store(directory, "first", &didRemove) == code(SWIFTMMKV_OK)
    )
    #expect(!didRemove)
    #expect(swiftmmkv_directory_remove_store(directory, "first", nil) == code(SWIFTMMKV_OK))
  }

  @Test func `An Open Store Cannot Be Removed`() throws {
    let directory = temporaryRootDirectory()
    try makeUnopenedStoreFiles(at: "\(directory)/closed")
    let store = try CStore(id: "open", directory: directory)
    defer { store.close() }
    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == true)

    var didRemove = false
    var count = 7
    #expect(
      swiftmmkv_directory_remove_store(directory, "open", &didRemove)
        == code(SWIFTMMKV_STORE_IS_OPEN)
    )
    #expect(
      swiftmmkv_directory_remove_all_stores(directory, &count)
        == code(SWIFTMMKV_STORES_ARE_OPEN)
    )

    #expect(!didRemove)
    #expect(count == 7)
    #expect(swiftmmkv_directory_contains_store(directory, "open") == true)
    #expect(swiftmmkv_directory_contains_store(directory, "closed") == false)
  }

  @Test func `Backs Up Restores And Removes Every Store Of A Directory`() throws {
    let directory = temporaryRootDirectory()
    let backup = temporaryRootDirectory()
    try makeUnopenedStoreFiles(at: "\(directory)/first")
    try makeUnopenedStoreFiles(at: "\(directory)/second")

    var count = 0
    #expect(
      swiftmmkv_directory_back_up_all_stores(directory, backup, &count) == code(SWIFTMMKV_OK)
    )
    #expect(count == 2)
    #expect(swiftmmkv_directory_contains_store(backup, "first") == true)
    #expect(swiftmmkv_directory_contains_store(backup, "second") == true)

    #expect(swiftmmkv_directory_remove_all_stores(directory, &count) == code(SWIFTMMKV_OK))
    #expect(count == 2)
    #expect(swiftmmkv_directory_contains_store(directory, "first") == false)

    #expect(
      swiftmmkv_directory_restore_all_stores(directory, backup, &count) == code(SWIFTMMKV_OK)
    )
    #expect(count == 2)
    #expect(swiftmmkv_directory_is_store_valid(directory, "first") == true)
    #expect(swiftmmkv_directory_is_store_valid(directory, "second") == true)

    #expect(swiftmmkv_directory_remove_all_stores(directory, nil) == code(SWIFTMMKV_OK))
    #expect(
      swiftmmkv_directory_back_up_all_stores(directory, backup, nil) == code(SWIFTMMKV_OK)
    )
    #expect(
      swiftmmkv_directory_restore_all_stores(directory, backup, nil) == code(SWIFTMMKV_OK)
    )
  }

  @Test func `Backs Up And Restores One Store Of A Directory`() throws {
    let directory = temporaryRootDirectory()
    let backup = temporaryRootDirectory()
    try makeUnopenedStoreFiles(at: "\(directory)/first")

    var didBackUp = false
    var didRestore = false
    #expect(
      swiftmmkv_directory_back_up_store(directory, "first", backup, &didBackUp)
        == code(SWIFTMMKV_OK)
    )
    #expect(didBackUp)
    #expect(
      swiftmmkv_directory_back_up_store(directory, "missing", backup, &didBackUp)
        == code(SWIFTMMKV_OK)
    )
    #expect(!didBackUp)

    #expect(swiftmmkv_directory_remove_store(directory, "first", nil) == code(SWIFTMMKV_OK))
    #expect(
      swiftmmkv_directory_restore_store(directory, "first", backup, &didRestore)
        == code(SWIFTMMKV_OK)
    )
    #expect(didRestore)
    #expect(swiftmmkv_directory_is_store_valid(directory, "first") == true)
    #expect(
      swiftmmkv_directory_restore_store(directory, "missing", backup, &didRestore)
        == code(SWIFTMMKV_OK)
    )
    #expect(!didRestore)

    #expect(
      swiftmmkv_directory_back_up_store(directory, "first", directory, nil)
        == code(SWIFTMMKV_BACKUP_IS_STORE_DIRECTORY)
    )
    #expect(
      swiftmmkv_directory_restore_store(directory, "first", directory, nil)
        == code(SWIFTMMKV_BACKUP_IS_STORE_DIRECTORY)
    )
  }
}
