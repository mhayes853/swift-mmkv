import Foundation
import SwiftMMKV
import Testing

@Suite struct MMKVStoreValueTests {
  @Test func `Round Trips Every Primitive`() throws {
    let store = try makeStore()

    #expect(store.set(true, forKey: "bool"))
    #expect(store.set(Int32.min, forKey: "int32"))
    #expect(store.set(UInt32.max, forKey: "uint32"))
    #expect(store.set(Int64.min, forKey: "int64"))
    #expect(store.set(UInt64.max, forKey: "uint64"))
    #expect(store.set(Float(1.5), forKey: "float"))
    #expect(store.set(Double.pi, forKey: "double"))
    #expect(store.set("héllo 👋", forKey: "string"))
    #expect(store.set([UInt8]([0, 1, 2, 255]), forKey: "bytes"))
    #expect(store.set(["a", "", "ç"], forKey: "strings"))

    #expect(store.value(forKey: "bool", as: Bool.self) == true)
    #expect(store.value(forKey: "int32", as: Int32.self) == .min)
    #expect(store.value(forKey: "uint32", as: UInt32.self) == .max)
    #expect(store.value(forKey: "int64", as: Int64.self) == .min)
    #expect(store.value(forKey: "uint64", as: UInt64.self) == .max)
    #expect(store.value(forKey: "float", as: Float.self) == 1.5)
    #expect(store.value(forKey: "double", as: Double.self) == .pi)
    #expect(store.value(forKey: "string", as: String.self) == "héllo 👋")
    #expect(store.value(forKey: "bytes", as: [UInt8].self) == [0, 1, 2, 255])
    #expect(store.value(forKey: "strings", as: [String].self) == ["a", "", "ç"])
  }

  @Test func `Missing Keys Read As Nil For Every Type`() throws {
    let store = try makeStore()

    #expect(store.value(forKey: "missing", as: Bool.self) == nil)
    #expect(store.value(forKey: "missing", as: Int32.self) == nil)
    #expect(store.value(forKey: "missing", as: UInt32.self) == nil)
    #expect(store.value(forKey: "missing", as: Int64.self) == nil)
    #expect(store.value(forKey: "missing", as: UInt64.self) == nil)
    #expect(store.value(forKey: "missing", as: Float.self) == nil)
    #expect(store.value(forKey: "missing", as: Double.self) == nil)
    #expect(store.value(forKey: "missing", as: String.self) == nil)
    #expect(store.value(forKey: "missing", as: [UInt8].self) == nil)
    #expect(store.value(forKey: "missing", as: [String].self) == nil)
    #expect(store.withBytes(forKey: "missing") { $0.byteCount } == nil)
  }

  @Test func `Stores Falsy And Empty Values Distinctly From Missing Keys`() throws {
    let store = try makeStore()

    store.set(false, forKey: "bool")
    store.set(0.0, forKey: "double")
    store.set("", forKey: "string")
    store.set([UInt8](), forKey: "bytes")
    store.set([String](), forKey: "strings")

    #expect(store.value(forKey: "bool", as: Bool.self) == false)
    #expect(store.value(forKey: "double", as: Double.self) == 0)
    #expect(store.value(forKey: "string", as: String.self) == "")
    #expect(store.value(forKey: "bytes", as: [UInt8].self) == [])
    #expect(store.value(forKey: "strings", as: [String].self) == [])
  }

  @Test func `Overwrites An Existing Value`() throws {
    let store = try makeStore()

    store.set("first", forKey: "key")
    store.set("second", forKey: "key")

    #expect(store.value(forKey: "key", as: String.self) == "second")
    #expect(store.count == 1)
  }

  @Test func `Subscript Reads Writes And Removes`() throws {
    let store = try makeStore()

    store["volume"] = 0.5
    #expect(store["volume", as: Double.self] == 0.5)

    store["volume", as: Double.self] = nil
    #expect(store["volume", as: Double.self] == nil)
    #expect(!store.contains("volume"))
  }

  @Test func `Reads And Writes Raw Bytes Through Spans`() throws {
    let store = try makeStore()
    let bytes: [UInt8] = [1, 2, 3, 4, 5]

    let didSet = bytes.withUnsafeBytes { store.set(bytes: $0.bytes, forKey: "raw") }
    #expect(didSet)

    let sum = store.withBytes(forKey: "raw") { span in
      (0..<span.byteCount)
        .reduce(0) { $0 + Int(span.unsafeLoad(fromByteOffset: $1, as: UInt8.self)) }
    }
    #expect(sum == 15)
    #expect(store.value(forKey: "raw", as: [UInt8].self) == bytes)
  }

  @Test func `With Bytes Propagates The Body's Error`() throws {
    struct Failure: Error, Equatable {}
    let store = try makeStore()
    store.set([UInt8]([1]), forKey: "raw")

    #expect(throws: Failure()) {
      try store.withBytes(forKey: "raw") { _ throws(Failure) in throw Failure() }
    }
  }

  @Test func `Stores A Large Value That Grows The File`() throws {
    let store = try makeStore()
    let large = String(repeating: "x", count: 1_000_000)

    #expect(store.set(large, forKey: "large"))
    #expect(store.value(forKey: "large", as: String.self) == large)
  }

  @Test func `Rejects An Empty Key`() throws {
    let store = try makeStore()

    #expect(!store.set("value", forKey: ""))
    #expect(store.value(forKey: "", as: String.self) == nil)
    #expect(store.count == 0)
  }

  @Test func `Keys May Contain Any Unicode Including NUL`() throws {
    let store = try makeStore()
    let key = "ké\u{0}y 🔑"

    store.set(1.0, forKey: key)

    #expect(store.value(forKey: key, as: Double.self) == 1)
    #expect(store.keys == [key])
    #expect(store.value(forKey: "ké", as: Double.self) == nil)
  }

  @Test func `A Read Only Store Rejects Writes`() throws {
    let rootDirectory = temporaryRootDirectory()
    let writable = try makeStore(id: "writable", rootDirectory: rootDirectory)
    writable.set("value", forKey: "key")
    writable.sync()

    // A separate copy of the files, because MMKV hands back the already-open writable instance
    // for the same identifier.
    for suffix in ["", ".crc"] {
      try FileManager.default.copyItem(
        atPath: "\(rootDirectory)/writable\(suffix)",
        toPath: "\(rootDirectory)/readonly\(suffix)"
      )
    }
    let readOnly = try makeStore(id: "readonly", rootDirectory: rootDirectory, isReadOnly: true)

    #expect(readOnly.value(forKey: "key", as: String.self) == "value")
    #expect(!readOnly.set("other", forKey: "key"))
    #expect(readOnly.value(forKey: "key", as: String.self) == "value")
  }

  @Test func `Rejects A Pair Over The Item Size Limit`() throws {
    let store = try makeStore(itemSizeLimit: 64)

    #expect(store.set("small", forKey: "small"))
    #expect(!store.set(String(repeating: "x", count: 1024), forKey: "large"))
    #expect(store.keys == ["small"])
  }

  @Test func `An Expiring Value Disappears After Its Duration`() async throws {
    let store = try makeStore()

    store.set("kept", forKey: "kept")
    store.set("123456", forKey: "otp", expiringIn: .seconds(1))
    #expect(store.value(forKey: "otp", as: String.self) == "123456")

    try await Task.sleep(for: .seconds(2.1))

    #expect(store.value(forKey: "otp", as: String.self) == nil)
    #expect(store.value(forKey: "kept", as: String.self) == "kept")
    #expect(store.keys == ["kept"])
    #expect(store.count == 1)
  }
}

@Suite struct MMKVValueConformanceTests {
  enum Theme: String, MMKVValue {
    case light, dark
  }

  enum Level: Int32, MMKVValue {
    case low = 1
    case high = 2
  }

  struct UserID: MMKVValue, Equatable {
    var rawValue: Int64

    init(rawValue: Int64) {
      self.rawValue = rawValue
    }

    init?(from reader: borrowing MMKVValueReader) {
      guard let rawValue = reader.int64() else { return nil }
      self.rawValue = rawValue
    }

    func write(to writer: inout MMKVValueWriter) -> Bool {
      writer.set(self.rawValue)
    }
  }

  struct Color: MMKVValue, Equatable {
    var red, green, blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
      (self.red, self.green, self.blue) = (red, green, blue)
    }

    init?(from reader: borrowing MMKVValueReader) {
      let parsed = reader.withBytes { span -> Color? in
        guard span.byteCount == 3 else { return nil }
        return Color(
          red: span.unsafeLoad(fromByteOffset: 0, as: UInt8.self),
          green: span.unsafeLoad(fromByteOffset: 1, as: UInt8.self),
          blue: span.unsafeLoad(fromByteOffset: 2, as: UInt8.self)
        )
      }
      guard let color = parsed ?? nil else { return nil }
      self = color
    }

    func write(to writer: inout MMKVValueWriter) -> Bool {
      let bytes = [self.red, self.green, self.blue]
      return bytes.withUnsafeBytes { writer.set(bytes: $0.bytes) }
    }
  }

  @Test func `Raw Representable Types Conform Through Their Raw Value`() throws {
    let store = try makeStore()

    store.set(Theme.dark, forKey: "theme")
    store.set(Level.high, forKey: "level")

    #expect(store.value(forKey: "theme", as: Theme.self) == .dark)
    #expect(store.value(forKey: "theme", as: String.self) == "dark")
    #expect(store.value(forKey: "level", as: Level.self) == .high)
  }

  @Test func `An Invalid Raw Value Reads As Nil`() throws {
    let store = try makeStore()

    store.set("sepia", forKey: "theme")

    #expect(store.value(forKey: "theme", as: Theme.self) == nil)
  }

  @Test func `A Custom Type Picks A Primitive Encoding`() throws {
    let store = try makeStore()

    store["user"] = UserID(rawValue: 7)

    #expect(store["user", as: UserID.self] == UserID(rawValue: 7))
    #expect(store["user", as: Int64.self] == 7)
  }

  @Test func `A Byte Backed Type Parses And Validates Its Bytes`() throws {
    let store = try makeStore()

    store.set(Color(red: 255, green: 128, blue: 0), forKey: "accent")
    store.set([UInt8]([1, 2]), forKey: "malformed")

    #expect(store.value(forKey: "accent", as: Color.self) == Color(red: 255, green: 128, blue: 0))
    #expect(store.value(forKey: "accent", as: [UInt8].self) == [255, 128, 0])
    #expect(store.value(forKey: "malformed", as: Color.self) == nil)
  }
}
