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
    let statuses = SWIFTMMKV_OK...SWIFTMMKV_STORE_IS_CLOSED
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
    defer { swiftmmkv_store_destroy(handle) }

    #expect(status == SWIFTMMKV_OK)
    let store = try #require(handle)
    #expect(swiftmmkv_store_count(store) == 0)
    #expect(swiftmmkv_store_set_bool(store, "flag", true, 0) == true)
    #expect(swiftmmkv_store_count(store) == 1)
  }

  /// The first `length` bytes of `buffer`, which must be followed by a terminator.
  private func string(_ buffer: [CChar], _ length: Int) -> String? {
    guard length < buffer.count, buffer[length] == 0 else { return nil }
    return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  @Test func `A Configuration's Directory Is Copied Into A Buffer It Fits`() {
    let configuration = swiftmmkv_configuration_create(
      "/stores/first",
      SWIFTMMKV_MODE_SINGLE_PROCESS
    )
    defer { swiftmmkv_configuration_destroy(configuration) }

    var length = 0
    swiftmmkv_configuration_directory(configuration, nil, 64, &length)
    #expect(length == "/stores/first".utf8.count)

    // A buffer the path fits without its terminator is left as it was.
    var exact = [CChar](repeating: 0x55, count: length)
    swiftmmkv_configuration_directory(configuration, &exact, exact.count, &length)
    #expect(length == exact.count)
    #expect(exact.allSatisfy { $0 == 0x55 })

    var buffer = [CChar](repeating: 0x55, count: length + 2)
    swiftmmkv_configuration_directory(configuration, &buffer, buffer.count, &length)
    #expect(string(buffer, length) == "/stores/first")
    #expect(buffer[length + 1] == 0x55)

    swiftmmkv_configuration_set_directory(configuration, "/stores/second")
    swiftmmkv_configuration_directory(configuration, &buffer, buffer.count, &length)
    #expect(string(buffer, length) == "/stores/second")
  }

  @Test func `A Temporary Configuration Tells Which Directory It Made`() throws {
    let configuration = swiftmmkv_configuration_create_temporary()
    defer { swiftmmkv_configuration_destroy(configuration) }
    var length = 0
    swiftmmkv_configuration_directory(configuration, nil, 0, &length)
    var buffer = [CChar](repeating: 0, count: length + 1)
    swiftmmkv_configuration_directory(configuration, &buffer, buffer.count, &length)
    let directory = try #require(string(buffer, length))
    #expect(!directory.isEmpty)
    #expect(swiftmmkv_directory_contains_store(directory, "mmkv.default") == false)

    var handle: OpaquePointer?
    #expect(swiftmmkv_store_open(configuration, &handle) == SWIFTMMKV_OK)
    defer { swiftmmkv_store_destroy(handle) }

    #expect(swiftmmkv_directory_contains_store(directory, "mmkv.default") == true)
  }

  @Test func `A Store Opened Twice Shares Its Contents`() throws {
    let directory = temporaryRootDirectory()
    let first = try CStore(id: "shared", directory: directory)
    defer { first.destroy() }
    let second = try CStore(id: "shared", directory: directory)
    defer { second.destroy() }

    #expect(swiftmmkv_store_set_string(first.handle, "username", "blob", 0) == true)

    #expect(second.string(forKey: "username") == "blob")
    #expect(try makeStore(id: "shared", rootDirectory: directory)["username"] == "blob")
  }

  @Test func `An Unknown Mode Fails The Open Until It Is Replaced`() {
    let configuration = swiftmmkv_configuration_create(temporaryRootDirectory(), 99)
    defer { swiftmmkv_configuration_destroy(configuration) }
    var handle: OpaquePointer?
    defer { swiftmmkv_store_destroy(handle) }

    #expect(swiftmmkv_store_open(configuration, &handle) == SWIFTMMKV_INVALID_ARGUMENT)
    #expect(handle == nil)

    swiftmmkv_configuration_set_mode(configuration, SWIFTMMKV_MODE_MULTI_PROCESS)
    #expect(swiftmmkv_store_open(configuration, &handle) == SWIFTMMKV_OK)
    #expect(handle != nil)
  }

  @Test func `An Unknown Cipher, Recovery, Or File Protection Fails The Open`() {
    #expect(throws: CStatusError(status: SWIFTMMKV_INVALID_ARGUMENT)) {
      try CStore { swiftmmkv_configuration_set_file_protection($0, 99) }
    }
    #expect(throws: CStatusError(status: SWIFTMMKV_INVALID_ARGUMENT)) {
      try CStore { swiftmmkv_configuration_set_encryption($0, 99, "key", 3) }
    }
    #expect(throws: CStatusError(status: SWIFTMMKV_INVALID_ARGUMENT)) {
      try CStore { swiftmmkv_configuration_set_recovery($0, 99) }
    }
  }

  @Test(
    arguments: [
      SWIFTMMKV_FILE_PROTECTION_COMPLETE_UNTIL_FIRST_USER_AUTHENTICATION,
      SWIFTMMKV_FILE_PROTECTION_NONE,
      SWIFTMMKV_FILE_PROTECTION_UNCHANGED
    ]
  )
  func `A Store Opens With Each File Protection`(protection: swiftmmkv_file_protection) throws {
    let store = try CStore {
      swiftmmkv_configuration_set_file_protection($0, 99)
      swiftmmkv_configuration_set_file_protection($0, protection)
    }
    defer { store.destroy() }

    #expect(swiftmmkv_store_set_string(store.handle, "name", "blob", 0) == true)
    #expect(store.string(forKey: "name") == "blob")
  }

  @Test func `An Encryption Key Of The Wrong Length Fails The Open`() {
    #expect(throws: CStatusError(status: SWIFTMMKV_INVALID_ENCRYPTION_KEY)) {
      try CStore {
        swiftmmkv_configuration_set_encryption($0, SWIFTMMKV_ENCRYPTION_AES128, nil, 0)
      }
    }
    #expect(throws: CStatusError(status: SWIFTMMKV_INVALID_ENCRYPTION_KEY)) {
      try CStore {
        let key = [UInt8](repeating: 1, count: 17)
        swiftmmkv_configuration_set_encryption(
          $0,
          SWIFTMMKV_ENCRYPTION_AES128,
          key,
          key.count
        )
      }
    }
  }

  @Test func `An Empty Identifier Fails The Open`() {
    #expect(throws: CStatusError(status: SWIFTMMKV_OPEN_FAILED)) {
      try CStore(id: "")
    }
  }

  @Test func `The Directory Can Be Replaced Before Opening`() throws {
    let directory = temporaryRootDirectory()
    let store = try CStore(id: "moved", directory: temporaryRootDirectory()) {
      swiftmmkv_configuration_set_directory($0, directory)
    }
    defer { store.destroy() }

    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == true)
    #expect(swiftmmkv_directory_contains_store(directory, "moved") == true)
  }

  @Test func `An Encrypted Store Keeps Its Values Out Of Its File`() throws {
    let directory = temporaryRootDirectory()
    let marker = "plain-text-marker"
    let plain = try CStore(id: "plain", directory: directory)
    defer { plain.destroy() }
    let encrypted = try CStore(id: "encrypted", directory: directory) {
      let key = Array("secret".utf8)
      swiftmmkv_configuration_set_encryption(
        $0,
        SWIFTMMKV_ENCRYPTION_AES256,
        key,
        key.count
      )
    }
    defer { encrypted.destroy() }

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
    defer { store.destroy() }

    #expect(store.string(forKey: "key") == "value")
    #expect(swiftmmkv_store_set_string(store.handle, "key", "changed", 0) == false)
    #expect(store.string(forKey: "key") == "value")
  }

  @Test func `The Item Size Limit Turns Large Values Away`() throws {
    let store = try CStore {
      swiftmmkv_configuration_set_item_size_limit($0, 64)
      swiftmmkv_configuration_set_compare_before_set($0, true)
      swiftmmkv_configuration_set_recovery($0, SWIFTMMKV_RECOVERY_RECOVER)
    }
    defer { store.destroy() }

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
    defer { store.destroy() }

    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == true)
    #expect(swiftmmkv_store_byte_size(store.handle) >= 1 << 20)
  }

  // MARK: - Values

  @Test func `Scalars Round Trip`() throws {
    let store = try CStore()
    defer { store.destroy() }

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
    defer { store.destroy() }

    var bool = true
    var int32: Int32 = 7
    var uint32: UInt32 = 7
    var int64: Int64 = 7
    var uint64: UInt64 = 7
    var float: Float = 7
    var double: Double = 7
    var string: [CChar] = [7, 7]
    var length = 7
    var bytes: [UInt8] = [7, 7]
    var count = 7
    var size = 7
    #expect(swiftmmkv_store_get_bool(store.handle, "missing", &bool) == false)
    #expect(swiftmmkv_store_get_int32(store.handle, "missing", &int32) == false)
    #expect(swiftmmkv_store_get_uint32(store.handle, "missing", &uint32) == false)
    #expect(swiftmmkv_store_get_int64(store.handle, "missing", &int64) == false)
    #expect(swiftmmkv_store_get_uint64(store.handle, "missing", &uint64) == false)
    #expect(swiftmmkv_store_get_float(store.handle, "missing", &float) == false)
    #expect(swiftmmkv_store_get_double(store.handle, "missing", &double) == false)
    #expect(swiftmmkv_store_get_string(store.handle, "missing", &string, 2, &length) == false)
    #expect(swiftmmkv_store_get_bytes(store.handle, "missing", &bytes, 2, &count) == false)
    #expect(
      swiftmmkv_store_get_strings(store.handle, "missing", &string, 2, &size, &count) == false
    )
    #expect(swiftmmkv_store_value_size(store.handle, "missing", &size) == false)
    #expect(bool)
    #expect(int32 == 7)
    #expect(uint32 == 7)
    #expect(int64 == 7)
    #expect(uint64 == 7)
    #expect(float == 7)
    #expect(double == 7)
    #expect(string == [7, 7])
    #expect(length == 7)
    #expect(bytes == [7, 7])
    #expect(count == 7)
    #expect(size == 7)
  }

  @Test func `A String Is Copied With Its Terminator Into A Buffer It Fits`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let text = "héllo wörld 👋"
    #expect(swiftmmkv_store_set_string(store.handle, "greeting", text, 0) == true)

    var exact = [CChar](repeating: 7, count: text.utf8.count + 1)
    var roomy = [CChar](repeating: 7, count: text.utf8.count + 3)
    var length = 0
    #expect(
      swiftmmkv_store_get_string(store.handle, "greeting", &exact, exact.count, &length) == true
    )
    #expect(length == text.utf8.count)
    #expect(exact == Array(text.utf8CString))

    length = 0
    #expect(
      swiftmmkv_store_get_string(store.handle, "greeting", &roomy, roomy.count, &length) == true
    )
    #expect(length == text.utf8.count)
    #expect(roomy == Array(text.utf8CString) + [7, 7])
  }

  @Test func `A String That Does Not Fit Is Sized And Not Copied`() throws {
    let store = try CStore()
    defer { store.destroy() }
    #expect(swiftmmkv_store_set_string(store.handle, "username", "blob", 0) == true)

    // Four bytes hold the string, but not its terminator.
    for capacity in [0, 1, 4] {
      var buffer = [CChar](repeating: 7, count: 4)
      var length = 0
      #expect(
        swiftmmkv_store_get_string(store.handle, "username", &buffer, capacity, &length) == true
      )
      #expect(length == 4)
      #expect(buffer == [7, 7, 7, 7])
    }

    var length = 0
    var size = 0
    #expect(swiftmmkv_store_get_string(store.handle, "username", nil, 0, &length) == true)
    #expect(swiftmmkv_store_get_string(store.handle, "username", nil, 99, &size) == true)
    #expect(length == 4)
    #expect(size == 4)
  }

  @Test func `A String With An Embedded NUL Is Copied Whole`() throws {
    let directory = temporaryRootDirectory()
    let store = try CStore(directory: directory)
    defer { store.destroy() }
    try makeStore(rootDirectory: directory).set("a\0b", forKey: "text")

    var buffer = [CChar](repeating: 7, count: 4)
    var length = 0
    #expect(
      swiftmmkv_store_get_string(store.handle, "text", &buffer, buffer.count, &length) == true
    )
    #expect(length == 3)
    #expect(buffer == [CChar(UInt8(ascii: "a")), 0, CChar(UInt8(ascii: "b")), 0])
  }

  @Test func `An Empty String Is A Value Of No Length`() throws {
    let store = try CStore()
    defer { store.destroy() }
    #expect(swiftmmkv_store_set_string(store.handle, "empty", "", 0) == true)

    var buffer: [CChar] = [7]
    var length = 7
    #expect(swiftmmkv_store_get_string(store.handle, "empty", &buffer, 1, &length) == true)
    #expect(length == 0)
    #expect(buffer == [0])
    #expect(store.string(forKey: "empty") == "")
  }

  @Test func `Bytes Are Copied Into A Buffer They Fit`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let payload: [UInt8] = [0, 1, 2, 255, 0]
    #expect(swiftmmkv_store_set_bytes(store.handle, "payload", payload, payload.count, 0) == true)

    var exact = [UInt8](repeating: 7, count: 5)
    var roomy = [UInt8](repeating: 7, count: 7)
    var count = 0
    #expect(swiftmmkv_store_get_bytes(store.handle, "payload", &exact, exact.count, &count) == true)
    #expect(count == 5)
    #expect(exact == payload)

    count = 0
    #expect(swiftmmkv_store_get_bytes(store.handle, "payload", &roomy, roomy.count, &count) == true)
    #expect(count == 5)
    #expect(roomy == payload + [7, 7])
  }

  @Test func `Bytes That Do Not Fit Are Sized And Not Copied`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let payload: [UInt8] = [1, 2, 3, 4, 5]
    #expect(swiftmmkv_store_set_bytes(store.handle, "payload", payload, payload.count, 0) == true)

    for capacity in [0, 1, 4] {
      var buffer = [UInt8](repeating: 7, count: 5)
      var count = 0
      #expect(swiftmmkv_store_get_bytes(store.handle, "payload", &buffer, capacity, &count) == true)
      #expect(count == 5)
      #expect(buffer == [7, 7, 7, 7, 7])
    }

    var count = 0
    var size = 0
    #expect(swiftmmkv_store_get_bytes(store.handle, "payload", nil, 99, &count) == true)
    #expect(swiftmmkv_store_value_size(store.handle, "payload", &size) == true)
    #expect(count == 5)
    #expect(size == 5)
  }

  @Test func `Empty Bytes Are A Value Of No Size`() throws {
    let store = try CStore()
    defer { store.destroy() }
    #expect(swiftmmkv_store_set_bytes(store.handle, "empty", nil, 0, 0) == true)

    var buffer: [UInt8] = [7]
    var count = 7
    var size = 7
    #expect(swiftmmkv_store_get_bytes(store.handle, "empty", &buffer, 1, &count) == true)
    #expect(swiftmmkv_store_value_size(store.handle, "empty", &size) == true)
    #expect(count == 0)
    #expect(size == 0)
    #expect(buffer == [7])
    #expect(store.bytes(forKey: "empty") == [])
  }

  @Test func `Bytes Larger Than A Page Round Trip`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let payload = (0..<100_000).map { UInt8(truncatingIfNeeded: $0) }

    #expect(swiftmmkv_store_set_bytes(store.handle, "payload", payload, payload.count, 0) == true)

    #expect(store.bytes(forKey: "payload") == payload)
  }

  @Test func `A String Is Read As Bytes Without Its Terminator`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let utf8 = Array("ünï".utf8)
    #expect(swiftmmkv_store_set_string(store.handle, "text", "ünï", 0) == true)
    #expect(swiftmmkv_store_set_bytes(store.handle, "bytes", utf8, utf8.count, 0) == true)

    var size = 0
    #expect(swiftmmkv_store_value_size(store.handle, "text", &size) == true)
    #expect(size == utf8.count)
    #expect(store.bytes(forKey: "text") == utf8)
    #expect(store.string(forKey: "bytes") == "ünï")
  }

  @Test func `Values Of An Encrypted Store Are Copied As They Were Written`() throws {
    let store = try CStore {
      let key = Array("secret".utf8)
      swiftmmkv_configuration_set_encryption($0, SWIFTMMKV_ENCRYPTION_AES256, key, key.count)
    }
    defer { store.destroy() }
    let small: [UInt8] = [1, 2, 3]
    let large = (0..<10_000).map { UInt8(truncatingIfNeeded: $0) }

    #expect(swiftmmkv_store_set_bytes(store.handle, "small", small, small.count, 0) == true)
    #expect(swiftmmkv_store_set_bytes(store.handle, "large", large, large.count, 0) == true)

    #expect(store.bytes(forKey: "small") == small)
    #expect(store.bytes(forKey: "large") == large)
  }

  @Test func `A Value With An Expiry Is Copied Without It`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let payload: [UInt8] = [1, 2, 3]
    let later = swiftmmkv_expiry_after(60)

    #expect(
      swiftmmkv_store_set_bytes(store.handle, "payload", payload, payload.count, later) == true
    )
    #expect(swiftmmkv_store_set_string(store.handle, "text", "blob", later) == true)

    #expect(store.bytes(forKey: "payload") == payload)
    #expect(store.string(forKey: "text") == "blob")
  }

  @Test func `String Lists Round Trip Packed`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let tags = packed(["a", "", "ünï"])
    let blank = packed([""])

    #expect(swiftmmkv_store_set_strings(store.handle, "tags", tags, tags.count, 0) == true)
    #expect(swiftmmkv_store_set_strings(store.handle, "blank", blank, blank.count, 0) == true)
    #expect(swiftmmkv_store_set_strings(store.handle, "none", nil, 0, 0) == true)

    var buffer = [CChar](repeating: 7, count: tags.count + 2)
    var size = 0
    var count = 0
    #expect(
      swiftmmkv_store_get_strings(store.handle, "tags", &buffer, buffer.count, &size, &count)
        == true
    )
    #expect(size == tags.count)
    #expect(count == 3)
    #expect(buffer == tags + [7, 7])
    #expect(store.strings(forKey: "tags") == ["a", "", "ünï"])
    #expect(store.strings(forKey: "blank") == [""])
    #expect(store.strings(forKey: "none") == [])
  }

  @Test func `A Packed List May Leave Out Its Last Terminator`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let tags = packed(["a", "bc"])

    #expect(swiftmmkv_store_set_strings(store.handle, "tags", tags, tags.count - 1, 0) == true)
    #expect(swiftmmkv_store_set_bool(store.handle, "a", true, 0) == true)
    #expect(swiftmmkv_store_set_bool(store.handle, "bc", true, 0) == true)
    swiftmmkv_store_remove_many(store.handle, tags, tags.count - 1)

    #expect(store.strings(forKey: "tags") == ["a", "bc"])
    #expect(store.keys() == ["tags"])
  }

  @Test func `A String List That Does Not Fit Is Sized And Not Copied`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let tags = packed(["a", "bc"])
    #expect(swiftmmkv_store_set_strings(store.handle, "tags", tags, tags.count, 0) == true)

    for capacity in [0, 1, 4] {
      var buffer = [CChar](repeating: 7, count: 5)
      var size = 0
      var count = 0
      #expect(
        swiftmmkv_store_get_strings(store.handle, "tags", &buffer, capacity, &size, &count) == true
      )
      #expect(size == 5)
      #expect(count == 2)
      #expect(buffer == [7, 7, 7, 7, 7])
    }
  }

  @Test func `A Packed List Is The One The Swift Interface Reads And Writes`() throws {
    let directory = temporaryRootDirectory()
    let store = try CStore(directory: directory)
    defer { store.destroy() }
    let swiftStore = try makeStore(rootDirectory: directory)
    let tags = packed(["a", "b"])

    #expect(swiftmmkv_store_set_strings(store.handle, "tags", tags, tags.count, 0) == true)
    swiftStore.set(["c", "d"], forKey: "more")

    #expect(swiftStore.value(forKey: "tags", as: [String].self) == ["a", "b"])
    #expect(store.strings(forKey: "more") == ["c", "d"])
  }

  @Test func `Values Are The Ones The Swift Interface Reads And Writes`() throws {
    let directory = temporaryRootDirectory()
    let store = try CStore(directory: directory)
    defer { store.destroy() }
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

  @Test func `Values Of Every Type Disappear After Their Expiry`() async throws {
    let store = try CStore()
    defer { store.destroy() }
    let bytes: [UInt8] = [1, 2, 3]
    let soon = swiftmmkv_expiry_after(1)

    #expect(swiftmmkv_store_set_string(store.handle, "kept", "kept", 0) == true)
    #expect(swiftmmkv_store_set_bool(store.handle, "bool", true, soon) == true)
    #expect(swiftmmkv_store_set_int32(store.handle, "int32", 1, soon) == true)
    #expect(swiftmmkv_store_set_uint32(store.handle, "uint32", 1, soon) == true)
    #expect(swiftmmkv_store_set_int64(store.handle, "int64", 1, soon) == true)
    #expect(swiftmmkv_store_set_uint64(store.handle, "uint64", 1, soon) == true)
    #expect(swiftmmkv_store_set_float(store.handle, "float", 1, soon) == true)
    #expect(swiftmmkv_store_set_double(store.handle, "double", 1, soon) == true)
    #expect(swiftmmkv_store_set_string(store.handle, "string", "abc", soon) == true)
    #expect(swiftmmkv_store_set_bytes(store.handle, "bytes", bytes, bytes.count, soon) == true)
    #expect(swiftmmkv_store_set_strings(store.handle, "strings", "a", 2, soon) == true)
    #expect(swiftmmkv_store_count(store.handle) == 11)

    try await Task.sleep(for: .seconds(2.1))

    #expect(store.keys() == ["kept"])
    #expect(store.string(forKey: "string") == nil)
    #expect(store.string(forKey: "kept") == "kept")
  }

  @Test func `Releasing Nothing Does Nothing`() {
    swiftmmkv_configuration_destroy(nil)
    swiftmmkv_store_destroy(nil)
    swiftmmkv_subscription_cancel(nil)
  }

  // MARK: - Expiry

  @Test func `A Zeroed Expiry Is The Store's Default`() {
    #expect(SWIFTMMKV_EXPIRY_DEFAULT == 0)
    #expect(swiftmmkv_expiry_never() != SWIFTMMKV_EXPIRY_DEFAULT)
    #expect(swiftmmkv_expiry_after(0) != SWIFTMMKV_EXPIRY_DEFAULT)
    #expect(swiftmmkv_expiry_at(0) != SWIFTMMKV_EXPIRY_DEFAULT)
    #expect(swiftmmkv_expiry_after(30) != swiftmmkv_expiry_at(30))
    #expect(swiftmmkv_expiry_after(30) == swiftmmkv_expiry_after(30))
  }

  @Test func `A Store Keeps Its Values Until They Are Removed By Default`() throws {
    let store = try CStore()
    defer { store.destroy() }

    #expect(
      swiftmmkv_store_set_bool(store.handle, "default", true, SWIFTMMKV_EXPIRY_DEFAULT) == true
    )
    #expect(swiftmmkv_store_set_bool(store.handle, "never", true, swiftmmkv_expiry_never()) == true)

    #expect(swiftmmkv_store_is_expiry_enabled(store.handle) == false)
  }

  @Test func `Values Expire After A Duration Or At A Moment`() async throws {
    let store = try CStore()
    defer { store.destroy() }
    let now = Date().timeIntervalSince1970

    #expect(swiftmmkv_store_set_bool(store.handle, "kept", true, swiftmmkv_expiry_never()) == true)
    #expect(
      swiftmmkv_store_set_bool(store.handle, "later", true, swiftmmkv_expiry_at(now + 3600)) == true
    )
    #expect(
      swiftmmkv_store_set_bool(store.handle, "after", true, swiftmmkv_expiry_after(1)) == true
    )
    #expect(
      swiftmmkv_store_set_bool(store.handle, "at", true, swiftmmkv_expiry_at(now + 1)) == true
    )
    #expect(swiftmmkv_store_is_expiry_enabled(store.handle) == true)
    #expect(store.keys().sorted() == ["after", "at", "kept", "later"])

    try await Task.sleep(for: .seconds(3.1))

    #expect(store.keys().sorted() == ["kept", "later"])
  }

  @Test func `The Shortest Expiry Is One Second`() throws {
    let store = try CStore()
    defer { store.destroy() }

    #expect(swiftmmkv_store_set_bool(store.handle, "none", true, swiftmmkv_expiry_after(0)) == true)
    #expect(
      swiftmmkv_store_set_bool(store.handle, "less", true, swiftmmkv_expiry_after(-5)) == true
    )
    #expect(swiftmmkv_store_set_bool(store.handle, "past", true, swiftmmkv_expiry_at(0)) == true)
    #expect(
      swiftmmkv_store_set_bool(store.handle, "never", true, swiftmmkv_expiry_at(-.infinity)) == true
    )

    #expect(swiftmmkv_store_is_expiry_enabled(store.handle) == true)
    #expect(store.keys().sorted() == ["less", "never", "none", "past"])
  }

  @Test func `An Expiry Later Than MMKV Can Record Is Never`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let far = [
      swiftmmkv_expiry_after(.infinity), swiftmmkv_expiry_at(.infinity),
      swiftmmkv_expiry_after(1e300), swiftmmkv_expiry_at(1e12)
    ]

    for expiry in far {
      #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, expiry) == true)
    }

    #expect(swiftmmkv_store_is_expiry_enabled(store.handle) == false)
  }

  @Test func `A Write With An Expiry No Function Made Stores Nothing`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let bytes: [UInt8] = [1]

    for expiry in [1, 42, .max, swiftmmkv_expiry_after(.nan), swiftmmkv_expiry_at(.nan)] {
      #expect(swiftmmkv_store_set_bool(store.handle, "bool", true, expiry) == false)
      #expect(swiftmmkv_store_set_string(store.handle, "string", "blob", expiry) == false)
      #expect(swiftmmkv_store_set_bytes(store.handle, "bytes", bytes, 1, expiry) == false)
      #expect(swiftmmkv_store_set_strings(store.handle, "strings", "a", 2, expiry) == false)
    }

    #expect(swiftmmkv_store_count(store.handle) == 0)
  }

  @Test func `A Store's Default Expiry Applies To Writes That Name None`() async throws {
    let store = try CStore {
      swiftmmkv_configuration_set_default_expiry($0, swiftmmkv_expiry_after(1))
    }
    defer { store.destroy() }

    #expect(swiftmmkv_store_set_bool(store.handle, "default", true, 0) == true)
    #expect(swiftmmkv_store_set_bool(store.handle, "kept", true, swiftmmkv_expiry_never()) == true)
    #expect(
      swiftmmkv_store_set_bool(store.handle, "later", true, swiftmmkv_expiry_after(3600)) == true
    )
    #expect(store.keys().sorted() == ["default", "kept", "later"])

    try await Task.sleep(for: .seconds(2.1))

    #expect(store.keys().sorted() == ["kept", "later"])
  }

  @Test func `A Default Expiry That Is Not An Expiry Fails The Open`() {
    for expiry in [SWIFTMMKV_EXPIRY_DEFAULT, 42, swiftmmkv_expiry_after(.nan)] {
      #expect(throws: CStatusError(status: SWIFTMMKV_INVALID_ARGUMENT)) {
        try CStore { swiftmmkv_configuration_set_default_expiry($0, expiry) }
      }
    }
  }

  @Test func `A Default Expiry Can Be Replaced Before Opening`() throws {
    let store = try CStore {
      swiftmmkv_configuration_set_default_expiry($0, 42)
      swiftmmkv_configuration_set_default_expiry($0, swiftmmkv_expiry_never())
    }
    defer { store.destroy() }

    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == true)
    #expect(swiftmmkv_store_is_expiry_enabled(store.handle) == false)
  }

  @Test func `Disabling Expiry Keeps Every Value That Has Not Expired`() throws {
    let store = try CStore()
    defer { store.destroy() }
    #expect(swiftmmkv_store_set_bool(store.handle, "kept", true, 0) == true)
    #expect(
      swiftmmkv_store_set_bool(store.handle, "later", true, swiftmmkv_expiry_after(60)) == true
    )
    #expect(swiftmmkv_store_is_expiry_enabled(store.handle) == true)

    #expect(swiftmmkv_store_disable_expiry(store.handle) == SWIFTMMKV_OK)

    #expect(swiftmmkv_store_is_expiry_enabled(store.handle) == false)
    #expect(store.keys().sorted() == ["kept", "later"])
    #expect(swiftmmkv_store_disable_expiry(store.handle) == SWIFTMMKV_OK)
  }

  @Test func `A Read Only Store Cannot Have Its Expiry Disabled`() throws {
    // The copy in the backup has never been opened for writing in this process.
    let backup = temporaryRootDirectory()
    let writer = try CStore(id: "expiring")
    defer { writer.destroy() }
    #expect(
      swiftmmkv_store_set_bool(writer.handle, "flag", true, swiftmmkv_expiry_after(60)) == true
    )
    #expect(swiftmmkv_store_back_up(writer.handle, backup) == SWIFTMMKV_OK)
    let store = try CStore(id: "expiring", directory: backup) {
      swiftmmkv_configuration_set_read_only($0, true)
    }
    defer { store.destroy() }

    #expect(swiftmmkv_store_is_expiry_enabled(store.handle) == true)
    #expect(swiftmmkv_store_disable_expiry(store.handle) == SWIFTMMKV_DISABLE_EXPIRY_FAILED)
    #expect(swiftmmkv_store_is_expiry_enabled(store.handle) == true)
  }

  // MARK: - Keys And Removal

  @Test func `Lists Counts And Removes Keys`() throws {
    let store = try CStore()
    defer { store.destroy() }
    for key in ["a", "b", "c", "d"] {
      #expect(swiftmmkv_store_set_int32(store.handle, key, 1, 0) == true)
    }

    #expect(swiftmmkv_store_count(store.handle) == 4)
    #expect(swiftmmkv_store_contains(store.handle, "a") == true)
    #expect(swiftmmkv_store_contains(store.handle, "z") == false)
    #expect(store.keys().sorted() == ["a", "b", "c", "d"])

    #expect(swiftmmkv_store_remove(store.handle, "a") == true)
    #expect(swiftmmkv_store_contains(store.handle, "a") == false)

    let doomed = packed(["b", "c", "missing"])
    swiftmmkv_store_remove_many(store.handle, doomed, doomed.count)
    swiftmmkv_store_remove_many(store.handle, nil, 0)
    #expect(store.keys() == ["d"])

    swiftmmkv_store_remove_all(store.handle, true)
    #expect(swiftmmkv_store_count(store.handle) == 0)
    #expect(store.keys() == [])
  }

  @Test func `Removing A Key Reports Whether It Had A Value`() throws {
    let store = try CStore()
    defer { store.destroy() }
    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == true)

    #expect(swiftmmkv_store_remove(store.handle, "flag") == true)
    #expect(swiftmmkv_store_remove(store.handle, "flag") == false)
    #expect(swiftmmkv_store_remove(store.handle, "missing") == false)
  }

  @Test func `Keys That Do Not Fit Are Sized And Not Copied`() throws {
    let store = try CStore()
    defer { store.destroy() }
    #expect(swiftmmkv_store_set_bool(store.handle, "first", true, 0) == true)
    #expect(swiftmmkv_store_set_bool(store.handle, "second", true, 0) == true)

    var buffer = [CChar](repeating: 7, count: 13)
    var size = 0
    var count = 0
    swiftmmkv_store_keys(store.handle, &buffer, 12, &size, &count)
    #expect(size == 13)
    #expect(count == 2)
    #expect(buffer == [CChar](repeating: 7, count: 13))

    swiftmmkv_store_keys(store.handle, &buffer, 13, &size, &count)
    #expect(size == 13)
    #expect(count == 2)
    #expect(unpacked(buffer).sorted() == ["first", "second"])
  }

  @Test func `The Keys Of A Store Can Be Passed Straight Back To Remove Them`() throws {
    let store = try CStore()
    defer { store.destroy() }
    for key in ["a", "b", "c"] {
      #expect(swiftmmkv_store_set_int32(store.handle, key, 1, 0) == true)
    }

    var buffer = [CChar](repeating: 0, count: 64)
    var size = 0
    var count = 0
    swiftmmkv_store_keys(store.handle, &buffer, buffer.count, &size, &count)
    #expect(swiftmmkv_store_set_bool(store.handle, "later", true, 0) == true)
    swiftmmkv_store_remove_many(store.handle, buffer, size)

    #expect(count == 3)
    #expect(store.keys() == ["later"])
  }

  @Test func `Imports The Contents Of Another Store`() throws {
    let source = try CStore()
    defer { source.destroy() }
    let destination = try CStore()
    defer { destination.destroy() }
    #expect(swiftmmkv_store_set_string(source.handle, "a", "from source", 0) == true)
    #expect(swiftmmkv_store_set_string(source.handle, "b", "from source", 0) == true)
    #expect(swiftmmkv_store_set_string(destination.handle, "b", "from destination", 0) == true)
    #expect(swiftmmkv_store_set_string(destination.handle, "c", "from destination", 0) == true)

    #expect(swiftmmkv_store_import_all(destination.handle, source.handle) == 2)

    #expect(destination.keys().sorted() == ["a", "b", "c"])
    #expect(destination.string(forKey: "b") == "from source")
  }

  @Test func `Keys Under A Prefix Are Listed And Removed Together`() throws {
    let store = try CStore()
    defer { store.destroy() }
    for key in ["settings", "settings.theme", "settings.sync.isEnabled", "settingsTheme", "user"] {
      #expect(swiftmmkv_store_set_bool(store.handle, key, true, 0) == true)
    }

    #expect(
      store.keys(under: "settings").sorted()
        == ["settings", "settings.sync.isEnabled", "settings.theme"]
    )
    #expect(store.keys(under: "settings.sync") == ["settings.sync.isEnabled"])
    #expect(store.keys(under: "missing").isEmpty)
    #expect(store.keys(under: "").count == 5)

    swiftmmkv_store_remove_under(store.handle, "settings", nil)

    #expect(store.keys().sorted() == ["settingsTheme", "user"])
  }

  @Test func `Keys Under A Prefix Can Be Joined By Another Separator`() throws {
    let store = try CStore()
    defer { store.destroy() }
    for key in ["settings/theme", "settings.theme", "settings/sync/isEnabled"] {
      #expect(swiftmmkv_store_set_bool(store.handle, key, true, 0) == true)
    }

    #expect(
      store.keys(under: "settings", separator: "/").sorted()
        == ["settings/sync/isEnabled", "settings/theme"]
    )

    swiftmmkv_store_remove_under(store.handle, "settings", "/")

    #expect(store.keys() == ["settings.theme"])
  }

  @Test func `Keys Under A Prefix That Do Not Fit Are Sized And Not Copied`() throws {
    let store = try CStore()
    defer { store.destroy() }
    #expect(swiftmmkv_store_set_bool(store.handle, "a.b", true, 0) == true)
    #expect(swiftmmkv_store_set_bool(store.handle, "c", true, 0) == true)
    var buffer = [CChar](repeating: 7, count: 3)
    var size = 0
    var count = 0

    swiftmmkv_store_keys_under(store.handle, "a", nil, &buffer, 3, &size, &count)

    #expect(size == 4)
    #expect(count == 1)
    #expect(buffer == [7, 7, 7])
  }

  // MARK: - Exclusive Access

  @Test func `Runs A Read Modify Write With The Lock Held`() throws {
    let store = try CStore()
    defer { store.destroy() }
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
    defer { store.destroy() }
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

    #expect(recorder.events == ["body done", "key:a,key:b"])
  }

  @Test func `Runs A Read Modify Write Between A Lock And An Unlock`() throws {
    let store = try CStore()
    defer { store.destroy() }

    for _ in 0..<3 {
      swiftmmkv_store_lock_exclusive(store.handle)
      var count: Int32 = 0
      _ = swiftmmkv_store_get_int32(store.handle, "count", &count)
      _ = swiftmmkv_store_set_int32(store.handle, "count", count + 1, 0)
      // The lock is recursive, and can be taken inside the callback form and around it.
      swiftmmkv_store_lock_exclusive(store.handle)
      swiftmmkv_store_with_exclusive_lock(store.handle, nil) { _, nested in
        _ = swiftmmkv_store_set_bool(nested, "nested", true, 0)
      }
      swiftmmkv_store_unlock_exclusive(store.handle)
      swiftmmkv_store_unlock_exclusive(store.handle)
    }

    var count: Int32 = 0
    #expect(swiftmmkv_store_get_int32(store.handle, "count", &count) == true)
    #expect(count == 3)
    #expect(swiftmmkv_store_contains(store.handle, "nested") == true)
  }

  @Test func `Listeners Hear Of What A Lock Covered Once All Of It Is Given Up`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let recorder = CCallbackRecorder()
    let subscription = swiftmmkv_store_subscribe(
      store.handle,
      recorder.context,
      CCallbackRecorder.onChange,
      CCallbackRecorder.release
    )
    defer { swiftmmkv_subscription_cancel(subscription) }

    swiftmmkv_store_lock_exclusive(store.handle)
    _ = swiftmmkv_store_set_int32(store.handle, "a", 1, 0)
    swiftmmkv_store_lock_exclusive(store.handle)
    _ = swiftmmkv_store_set_int32(store.handle, "a", 2, 0)
    _ = swiftmmkv_store_set_int32(store.handle, "b", 1, 0)
    swiftmmkv_store_unlock_exclusive(store.handle)
    recorder.record("inner unlocked")
    _ = swiftmmkv_store_set_int32(store.handle, "c", 1, 0)
    swiftmmkv_store_unlock_exclusive(store.handle)

    #expect(recorder.events == ["inner unlocked", "key:a,key:b,key:c"])
  }

  @Test func `Another Thread Waits For The Lock To Be Given Up`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let recorder = CCallbackRecorder()
    let context = CReadingContext(store: store.handle, recorder: recorder)

    swiftmmkv_store_lock_exclusive(store.handle)
    let writer = Thread {
      _ = swiftmmkv_store_set_bool(context.store, "flag", true, 0)
      context.recorder.record("wrote")
    }
    writer.start()
    usleep(100_000)
    recorder.record("unlocking")
    swiftmmkv_store_unlock_exclusive(store.handle)
    for _ in 0..<5000 where recorder.events.count < 2 {
      usleep(1000)
    }

    #expect(recorder.events == ["unlocking", "wrote"])
  }

  @Test func `An Unlock Without A Lock Does Nothing`() throws {
    let store = try CStore()
    defer { store.destroy() }

    swiftmmkv_store_unlock_exclusive(store.handle)

    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == true)
    swiftmmkv_store_lock_exclusive(store.handle)
    swiftmmkv_store_unlock_exclusive(store.handle)
    swiftmmkv_store_unlock_exclusive(store.handle)
    #expect(swiftmmkv_store_contains(store.handle, "flag") == true)
  }

  @Test func `A Lock On A Suspended Or Closed Store Takes Nothing`() throws {
    let store = try CStore(
      id: "lock-\(UUID().uuidString)",
      mode: SWIFTMMKV_MODE_MULTI_PROCESS
    )
    defer { store.destroy() }

    swiftmmkv_store_suspend(store.handle)
    swiftmmkv_store_lock_exclusive(store.handle)
    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == false)
    // Nothing was taken, so resuming does not wait for the lock, and the unlock that
    // balances it gives nothing up.
    swiftmmkv_store_resume(store.handle)
    swiftmmkv_store_lock_exclusive(store.handle)
    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == true)
    swiftmmkv_store_unlock_exclusive(store.handle)
    swiftmmkv_store_unlock_exclusive(store.handle)

    swiftmmkv_store_close(store.handle)
    swiftmmkv_store_lock_exclusive(store.handle)
    #expect(swiftmmkv_store_contains(store.handle, "flag") == false)
    swiftmmkv_store_unlock_exclusive(store.handle)
  }

  // MARK: - Changes

  @Test func `A Subscription Hears Of Every Operation Until It Is Cancelled`() throws {
    let store = try CStore()
    defer { store.destroy() }
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
    defer { store.destroy() }
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

  @Test func `A Prefix Subscription Only Hears Of The Keys Under It`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let recorder = CCallbackRecorder()
    let subscription = swiftmmkv_store_subscribe_under(
      store.handle,
      "settings",
      nil,
      recorder.context,
      CCallbackRecorder.onChange,
      CCallbackRecorder.release
    )

    #expect(swiftmmkv_store_set_bool(store.handle, "user", true, 0) == true)
    #expect(swiftmmkv_store_set_bool(store.handle, "settingsTheme", true, 0) == true)
    #expect(swiftmmkv_store_set_bool(store.handle, "settings", true, 0) == true)
    #expect(swiftmmkv_store_set_bool(store.handle, "settings.theme", true, 0) == true)
    #expect(swiftmmkv_store_remove(store.handle, "settings.theme") == true)
    #expect(
      recorder.events == ["key:settings", "key:settings.theme", "key:settings.theme"]
    )

    swiftmmkv_subscription_cancel(subscription)
    #expect(recorder.releases == 1)
  }

  @Test func `A Prefix Subscription Takes A Separator, And An Empty Prefix Hears All`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let slashes = CCallbackRecorder()
    let all = CCallbackRecorder()
    let first = swiftmmkv_store_subscribe_under(
      store.handle, "settings", "/", slashes.context, CCallbackRecorder.onChange, nil
    )
    let second = swiftmmkv_store_subscribe_under(
      store.handle, "", nil, all.context, CCallbackRecorder.onChange, nil
    )

    #expect(swiftmmkv_store_set_bool(store.handle, "settings.theme", true, 0) == true)
    #expect(swiftmmkv_store_set_bool(store.handle, "settings/theme", true, 0) == true)

    #expect(slashes.events == ["key:settings/theme"])
    #expect(all.events == ["key:settings.theme", "key:settings/theme"])
    swiftmmkv_subscription_cancel(first)
    swiftmmkv_subscription_cancel(second)
  }

  @Test func `A Prefix Subscription Hears Once Of Each Operation, With Its Keys`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let recorder = CCallbackRecorder()
    let subscription = swiftmmkv_store_subscribe_under(
      store.handle,
      "settings",
      nil,
      recorder.context,
      CCallbackRecorder.onChange,
      CCallbackRecorder.release
    )

    swiftmmkv_store_with_exclusive_lock(store.handle, nil) { _, locked in
      _ = swiftmmkv_store_set_string(locked, "settings.theme", "dark", 0)
      _ = swiftmmkv_store_set_double(locked, "settings.fontSize", 16, 0)
      _ = swiftmmkv_store_set_bool(locked, "user", false, 0)
    }
    #expect(recorder.events == ["key:settings.theme,key:settings.fontSize"])

    swiftmmkv_store_with_exclusive_lock(store.handle, nil) { _, locked in
      _ = swiftmmkv_store_set_bool(locked, "user", true, 0)
    }
    #expect(recorder.events.count == 1)

    swiftmmkv_store_remove_under(store.handle, "settings", nil)
    #expect(recorder.events.count == 2)
    #expect(
      Set(recorder.events[1].split(separator: ","))
        == ["key:settings.theme", "key:settings.fontSize"]
    )

    swiftmmkv_subscription_cancel(subscription)
    #expect(swiftmmkv_store_set_bool(store.handle, "settings", true, 0) == true)
    #expect(recorder.events.count == 2)
    #expect(recorder.releases == 1)
  }

  @Test func `A Prefix Subscription Reads A Whole Value From Its Callback`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let recorder = CCallbackRecorder()
    let reading = CReadingContext(store: store.handle, recorder: recorder)
    let subscription = swiftmmkv_store_subscribe_under(
      store.handle,
      "point",
      nil,
      Unmanaged.passUnretained(reading).toOpaque(),
      { context, batch in
        let reading = Unmanaged<CReadingContext>.fromOpaque(context!).takeUnretainedValue()
        var (x, y): (Int32, Int32) = (0, 0)
        _ = swiftmmkv_store_get_int32(reading.store, "point.x", &x)
        _ = swiftmmkv_store_get_int32(reading.store, "point.y", &y)
        reading.recorder.record("\(batch.pointee.key_count) keys: \(x),\(y)")
      },
      nil
    )

    swiftmmkv_store_with_exclusive_lock(store.handle, nil) { _, locked in
      _ = swiftmmkv_store_set_int32(locked, "point.x", 1, 0)
      _ = swiftmmkv_store_set_int32(locked, "point.y", 2, 0)
    }

    #expect(recorder.events == ["2 keys: 1,2"])
    swiftmmkv_subscription_cancel(subscription)
  }

  @Test func `A Batch Has No Keys For A Change From Outside`() throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)
    let configuration = first.configuration
    let store = try CStore(
      id: configuration.id.rawValue,
      directory: configuration.directory.path,
      mode: SWIFTMMKV_MODE_MULTI_PROCESS
    )
    defer { store.destroy() }
    let recorder = CCallbackRecorder()
    let subscription = swiftmmkv_store_subscribe_under(
      store.handle,
      "settings",
      "/",
      recorder.context,
      CCallbackRecorder.onChange,
      nil
    )

    #expect(swiftmmkv_store_set_bool(store.handle, "settings.theme", true, 0) == true)
    #expect(recorder.events.isEmpty)
    #expect(swiftmmkv_store_set_bool(store.handle, "settings/theme", true, 0) == true)
    #expect(recorder.events == ["key:settings/theme"])

    second.set("blob", forKey: "username")
    swiftmmkv_store_check_for_external_changes(store.handle)

    #expect(recorder.events == ["key:settings/theme", "external"])
    swiftmmkv_subscription_cancel(subscription)
  }

  @Test func `A Subscription Works Without A Context Or A Release`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let subscription = swiftmmkv_store_subscribe(store.handle, nil, { _, _ in }, nil)

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
    defer { store.destroy() }
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
    defer { store.destroy() }
    #expect(swiftmmkv_store_set_string(store.handle, "username", "blob", 0) == true)
    #expect(swiftmmkv_store_is_suspended(store.handle) == false)

    swiftmmkv_store_suspend(store.handle)

    let key = Array("secret".utf8)
    #expect(swiftmmkv_store_is_suspended(store.handle) == true)
    #expect(store.string(forKey: "username") == nil)
    #expect(swiftmmkv_store_set_string(store.handle, "username", "changed", 0) == false)
    #expect(swiftmmkv_store_count(store.handle) == 0)
    #expect(
      swiftmmkv_store_rekey(store.handle, SWIFTMMKV_ENCRYPTION_AES128, key, key.count)
        == SWIFTMMKV_STORE_IS_SUSPENDED
    )
    #expect(
      swiftmmkv_store_back_up(store.handle, temporaryRootDirectory())
        == SWIFTMMKV_STORE_IS_SUSPENDED
    )
    #expect(swiftmmkv_store_disable_expiry(store.handle) == SWIFTMMKV_STORE_IS_SUSPENDED)
    #expect(swiftmmkv_store_is_expiry_enabled(store.handle) == false)

    swiftmmkv_store_resume(store.handle)

    #expect(swiftmmkv_store_is_suspended(store.handle) == false)
    #expect(store.string(forKey: "username") == "blob")
  }

  @Test func `A Single Process Store Is Never Suspended`() throws {
    let store = try CStore()
    defer { store.destroy() }

    swiftmmkv_store_suspend(store.handle)

    #expect(swiftmmkv_store_is_suspended(store.handle) == false)
    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == true)
    swiftmmkv_store_resume(store.handle)
  }

  // MARK: - Closing

  @Test func `A Closed Store Turns Everything Away And Can Be Removed`() throws {
    let directory = temporaryRootDirectory()
    let store = try CStore(id: "settings", directory: directory)
    defer { store.destroy() }
    #expect(swiftmmkv_store_set_string(store.handle, "name", "blob", 0) == true)
    #expect(swiftmmkv_store_is_closed(store.handle) == false)

    swiftmmkv_store_close(store.handle)
    swiftmmkv_store_close(store.handle)

    #expect(swiftmmkv_store_is_closed(store.handle) == true)
    #expect(swiftmmkv_store_is_suspended(store.handle) == false)
    #expect(store.string(forKey: "name") == nil)
    #expect(store.keys().isEmpty)
    #expect(swiftmmkv_store_count(store.handle) == 0)
    #expect(swiftmmkv_store_set_string(store.handle, "name", "blob", 0) == false)
    #expect(swiftmmkv_store_disable_expiry(store.handle) == SWIFTMMKV_STORE_IS_CLOSED)
    #expect(
      swiftmmkv_store_back_up(store.handle, temporaryRootDirectory())
        == SWIFTMMKV_STORE_IS_CLOSED
    )
    var didRemove = false
    #expect(
      swiftmmkv_directory_remove_store(directory, "settings", &didRemove) == SWIFTMMKV_OK
    )
    #expect(didRemove)
  }

  @Test func `Destroying A Handle Leaves Its Store Open`() throws {
    let directory = temporaryRootDirectory()
    let first = try CStore(id: "settings", directory: directory)
    let second = try CStore(id: "settings", directory: directory)
    defer { second.destroy() }
    #expect(swiftmmkv_store_set_string(first.handle, "name", "blob", 0) == true)

    first.destroy()

    #expect(swiftmmkv_store_is_closed(second.handle) == false)
    #expect(second.string(forKey: "name") == "blob")
    #expect(
      swiftmmkv_directory_remove_store(directory, "settings", nil) == SWIFTMMKV_STORE_IS_OPEN
    )
  }

  @Test func `Closing A Store Closes Every Handle Over Its Files`() throws {
    let directory = temporaryRootDirectory()
    let first = try CStore(id: "settings", directory: directory)
    let second = try CStore(id: "settings", directory: directory)
    defer {
      first.destroy()
      second.destroy()
    }

    swiftmmkv_store_close(first.handle)

    #expect(swiftmmkv_store_is_closed(second.handle) == true)
  }

  @Test func `A Closed Store Can Be Opened Again`() throws {
    let directory = temporaryRootDirectory()
    let store = try CStore(id: "settings", directory: directory)
    #expect(swiftmmkv_store_set_string(store.handle, "name", "blob", 0) == true)
    swiftmmkv_store_close(store.handle)
    store.destroy()

    let reopened = try CStore(id: "settings", directory: directory)
    defer { reopened.destroy() }

    #expect(swiftmmkv_store_is_closed(reopened.handle) == false)
    #expect(reopened.string(forKey: "name") == "blob")
  }

  @Test func `Closing Tells Listeners Once And Releases Their Contexts`() throws {
    let store = try CStore()
    defer { store.destroy() }
    let recorder = CCallbackRecorder()
    let subscription = swiftmmkv_store_subscribe(
      store.handle,
      recorder.context,
      CCallbackRecorder.onChange,
      CCallbackRecorder.release
    )

    swiftmmkv_store_close(store.handle)
    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == false)

    #expect(recorder.events == ["external"])
    #expect(recorder.releases == 1)
    swiftmmkv_subscription_cancel(subscription)
    #expect(recorder.releases == 1)
  }

  // MARK: - Maintenance

  @Test func `Reports Sizes And Survives A Trim And A Sync`() throws {
    let store = try CStore()
    defer { store.destroy() }
    #expect(swiftmmkv_store_set_string(store.handle, "username", "blob", 0) == true)

    #expect(swiftmmkv_store_byte_size(store.handle) > 0)
    #expect(swiftmmkv_store_used_byte_size(store.handle) > 0)
    #expect(
      swiftmmkv_store_used_byte_size(store.handle) <= swiftmmkv_store_byte_size(store.handle)
    )

    swiftmmkv_store_trim(store.handle)
    swiftmmkv_store_release_memory(store.handle)
    swiftmmkv_store_sync(store.handle)

    #expect(store.string(forKey: "username") == "blob")
  }

  @Test func `Rekeys A Store And Keeps Its Values`() throws {
    let directory = temporaryRootDirectory()
    let store = try CStore(directory: directory)
    defer { store.destroy() }
    let marker = "plain-text-marker"
    let path = URL(fileURLWithPath: "\(directory)/mmkv.default")
    let key = Array("secret".utf8)
    #expect(swiftmmkv_store_set_string(store.handle, "key", marker, 0) == true)

    #expect(
      swiftmmkv_store_rekey(store.handle, SWIFTMMKV_ENCRYPTION_AES256, key, key.count)
        == SWIFTMMKV_OK
    )
    #expect(store.string(forKey: "key") == marker)
    #expect(try Data(contentsOf: path).range(of: Data(marker.utf8)) == nil)

    #expect(
      swiftmmkv_store_rekey(store.handle, SWIFTMMKV_ENCRYPTION_NONE, nil, 0)
        == SWIFTMMKV_OK
    )
    #expect(store.string(forKey: "key") == marker)
    #expect(try Data(contentsOf: path).range(of: Data(marker.utf8)) != nil)
  }

  @Test func `Rekeying Reports What Is Wrong With Its Arguments`() throws {
    let store = try CStore()
    defer { store.destroy() }

    #expect(swiftmmkv_store_rekey(store.handle, 99, "key", 3) == SWIFTMMKV_INVALID_ARGUMENT)
    #expect(
      swiftmmkv_store_rekey(store.handle, SWIFTMMKV_ENCRYPTION_AES128, nil, 0)
        == SWIFTMMKV_INVALID_ENCRYPTION_KEY
    )
  }

  // MARK: - Backups

  @Test func `Backs Up And Restores A Store`() throws {
    let directory = temporaryRootDirectory()
    let backup = temporaryRootDirectory()
    let store = try CStore(id: "settings", directory: directory)
    defer { store.destroy() }
    #expect(swiftmmkv_store_set_string(store.handle, "username", "blob", 0) == true)

    #expect(swiftmmkv_store_back_up(store.handle, backup) == SWIFTMMKV_OK)
    #expect(swiftmmkv_directory_contains_store(backup, "settings") == true)
    #expect(swiftmmkv_directory_is_store_valid(backup, "settings") == true)

    #expect(swiftmmkv_store_set_string(store.handle, "username", "changed", 0) == true)
    var didRestore = false
    #expect(swiftmmkv_store_restore(store.handle, backup, &didRestore) == SWIFTMMKV_OK)
    #expect(didRestore)
    #expect(store.string(forKey: "username") == "blob")

    #expect(swiftmmkv_store_restore(store.handle, backup, nil) == SWIFTMMKV_OK)
  }

  @Test func `Restoring From A Directory Without A Copy Restores Nothing`() throws {
    let store = try CStore()
    defer { store.destroy() }
    #expect(swiftmmkv_store_set_string(store.handle, "username", "blob", 0) == true)

    var didRestore = true
    #expect(
      swiftmmkv_store_restore(store.handle, temporaryRootDirectory(), &didRestore)
        == SWIFTMMKV_OK
    )

    #expect(!didRestore)
    #expect(store.string(forKey: "username") == "blob")
  }

  @Test func `A Store Cannot Be Backed Up Into Its Own Directory`() throws {
    let directory = temporaryRootDirectory()
    let store = try CStore(directory: directory)
    defer { store.destroy() }
    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == true)

    var didRestore = true
    #expect(
      swiftmmkv_store_back_up(store.handle, directory)
        == SWIFTMMKV_BACKUP_IS_STORE_DIRECTORY
    )
    #expect(
      swiftmmkv_store_restore(store.handle, directory, &didRestore)
        == SWIFTMMKV_BACKUP_IS_STORE_DIRECTORY
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
      swiftmmkv_directory_remove_store(directory, "first", &didRemove) == SWIFTMMKV_OK
    )
    #expect(didRemove)
    #expect(swiftmmkv_directory_contains_store(directory, "first") == false)

    #expect(
      swiftmmkv_directory_remove_store(directory, "first", &didRemove) == SWIFTMMKV_OK
    )
    #expect(!didRemove)
    #expect(swiftmmkv_directory_remove_store(directory, "first", nil) == SWIFTMMKV_OK)
  }

  @Test func `An Open Store Cannot Be Removed`() throws {
    let directory = temporaryRootDirectory()
    try makeUnopenedStoreFiles(at: "\(directory)/closed")
    let store = try CStore(id: "open", directory: directory)
    defer { store.destroy() }
    #expect(swiftmmkv_store_set_bool(store.handle, "flag", true, 0) == true)

    var didRemove = false
    var count = 7
    #expect(
      swiftmmkv_directory_remove_store(directory, "open", &didRemove)
        == SWIFTMMKV_STORE_IS_OPEN
    )
    #expect(
      swiftmmkv_directory_remove_all_stores(directory, &count)
        == SWIFTMMKV_STORES_ARE_OPEN
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
      swiftmmkv_directory_back_up_all_stores(directory, backup, &count) == SWIFTMMKV_OK
    )
    #expect(count == 2)
    #expect(swiftmmkv_directory_contains_store(backup, "first") == true)
    #expect(swiftmmkv_directory_contains_store(backup, "second") == true)

    #expect(swiftmmkv_directory_remove_all_stores(directory, &count) == SWIFTMMKV_OK)
    #expect(count == 2)
    #expect(swiftmmkv_directory_contains_store(directory, "first") == false)

    #expect(
      swiftmmkv_directory_restore_all_stores(directory, backup, &count) == SWIFTMMKV_OK
    )
    #expect(count == 2)
    #expect(swiftmmkv_directory_is_store_valid(directory, "first") == true)
    #expect(swiftmmkv_directory_is_store_valid(directory, "second") == true)

    #expect(swiftmmkv_directory_remove_all_stores(directory, nil) == SWIFTMMKV_OK)
    #expect(
      swiftmmkv_directory_back_up_all_stores(directory, backup, nil) == SWIFTMMKV_OK
    )
    #expect(
      swiftmmkv_directory_restore_all_stores(directory, backup, nil) == SWIFTMMKV_OK
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
        == SWIFTMMKV_OK
    )
    #expect(didBackUp)
    #expect(
      swiftmmkv_directory_back_up_store(directory, "missing", backup, &didBackUp)
        == SWIFTMMKV_OK
    )
    #expect(!didBackUp)

    #expect(swiftmmkv_directory_remove_store(directory, "first", nil) == SWIFTMMKV_OK)
    #expect(
      swiftmmkv_directory_restore_store(directory, "first", backup, &didRestore)
        == SWIFTMMKV_OK
    )
    #expect(didRestore)
    #expect(swiftmmkv_directory_is_store_valid(directory, "first") == true)
    #expect(
      swiftmmkv_directory_restore_store(directory, "missing", backup, &didRestore)
        == SWIFTMMKV_OK
    )
    #expect(!didRestore)

    #expect(
      swiftmmkv_directory_back_up_store(directory, "first", directory, nil)
        == SWIFTMMKV_BACKUP_IS_STORE_DIRECTORY
    )
    #expect(
      swiftmmkv_directory_restore_store(directory, "first", directory, nil)
        == SWIFTMMKV_BACKUP_IS_STORE_DIRECTORY
    )
  }
}
