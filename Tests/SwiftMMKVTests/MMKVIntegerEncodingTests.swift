import SwiftMMKV
import Testing

@Suite struct MMKVIntegerEncodingTests {
  enum NativePriority: Int64, MMKVValue, Codable {
    case low, high
  }

  enum Priority: Int64, MMKVValue, Codable {
    case low, high
    static let integerEncoding = MMKVIntegerEncoding.number
  }

  struct Count: RawRepresentable, MMKVValue, Equatable {
    var rawValue: UInt64
    static let integerEncoding = MMKVIntegerEncoding.number
  }

  enum Theme: String, MMKVValue {
    case light, dark
    static let integerEncoding = MMKVIntegerEncoding.number
  }

  /// Calls the helpers itself, as a type without a raw value does.
  struct UserID: MMKVValue, Codable, Equatable {
    var value: Int

    init(value: Int) { self.value = value }

    init?(from reader: borrowing MMKVValueReader) {
      guard let value = reader.number(as: Int.self) else { return nil }
      self.value = value
    }

    func write(to writer: inout MMKVValueWriter) -> Bool {
      writer.set(number: self.value)
    }
  }

  @Test func `An Integer Raw Value Is Native By Default`() throws {
    let store = try makeStore()

    store.set(NativePriority.high, forKey: "priority")

    #expect(NativePriority.integerEncoding == .native)
    #expect(store.value(forKey: "priority", as: Int64.self) == 1)
    #expect(store.value(forKey: "priority", as: NativePriority.self) == .high)
  }

  @Test func `An Integer Raw Value Can Be Stored As A Number`() throws {
    let store = try makeStore()

    store.set(Priority.high, forKey: "priority")
    store.set(0.0, forKey: "javascript")

    #expect(store.value(forKey: "priority", as: Double.self) == 1)
    #expect(store.value(forKey: "priority", as: Priority.self) == .high)
    #expect(store.value(forKey: "javascript", as: Priority.self) == .low)
    #expect(store.value(forKey: "missing", as: Priority.self) == nil)
  }

  @Test func `A Number That Is Not A Raw Value Reads As Nil`() throws {
    let store = try makeStore()
    store.set(0.5, forKey: "fraction")
    store.set(7.0, forKey: "unknown")
    store.set(-1.0, forKey: "negative")

    #expect(store.value(forKey: "fraction", as: Priority.self) == nil)
    #expect(store.value(forKey: "unknown", as: Priority.self) == nil)
    #expect(store.value(forKey: "negative", as: Count.self) == nil)
  }

  @Test func `An Integer A Double Cannot Hold Is Not Stored As A Number`() throws {
    let store = try makeStore()

    #expect(store.set(Count(rawValue: 1 << 53), forKey: "exact"))
    #expect(!store.set(Count(rawValue: (1 << 53) + 1), forKey: "inexact"))

    #expect(store.value(forKey: "exact", as: Count.self) == Count(rawValue: 1 << 53))
    #expect(!store.contains("inexact"))
  }

  @Test func `The Integer Encoding Does Not Change Other Raw Values`() throws {
    let store = try makeStore()

    store.set(Theme.dark, forKey: "theme")

    #expect(store.value(forKey: "theme", as: String.self) == "dark")
    #expect(store.value(forKey: "theme", as: Theme.self) == .dark)
  }

  @Test func `A Reader And Writer Carry An Integer As A Number`() throws {
    let store = try makeStore()

    store.set(UserID(value: 42), forKey: "user")
    store.set(2.5, forKey: "fraction")

    #expect(store.value(forKey: "user", as: Double.self) == 42)
    #expect(store.value(forKey: "user", as: UserID.self) == UserID(value: 42))
    #expect(store.value(forKey: "fraction", as: UserID.self) == nil)
  }

  @Test func `A Typed Key Holds An Integer Stored As A Number`() throws {
    let store = try makeStore()
    let key = MMKVStore.Key<Priority>("priority")

    store[key] = .high

    #expect(store[key] == .high)
    #expect(store.value(forKey: "priority", as: Double.self) == 1)
  }
}

@Suite struct MMKVStoreKeyCodingValueTests {
  /// A type of the app's own, which stores itself as one string.
  struct Money: MMKVValue, Codable, Equatable {
    var cents: Int64

    init(cents: Int64) { self.cents = cents }

    init?(from reader: borrowing MMKVValueReader) {
      guard let string = reader.string(), let cents = Int64(string.dropLast(6)),
        string.hasSuffix(" cents")
      else { return nil }
      self.cents = cents
    }

    func write(to writer: inout MMKVValueWriter) -> Bool {
      writer.set("\(self.cents) cents")
    }
  }

  struct Order: Codable, Equatable {
    var total: Money
    var tip: Money?
    var priority: MMKVIntegerEncodingTests.Priority
    var nativePriority: MMKVIntegerEncodingTests.NativePriority
    var user: MMKVIntegerEncodingTests.UserID
    var tags: [String]
    var count: Int64
  }

  let order = Order(
    total: Money(cents: 1250),
    tip: nil,
    priority: .high,
    nativePriority: .high,
    user: .init(value: 42),
    tags: ["a", "b"],
    count: 3
  )

  @Test func `A Value Type Is Stored As It Is Stored Alone`() throws {
    let store = try makeStore()

    try store.encode(self.order, intoKeysUnder: "order", options: .init(arrays: .native))

    #expect(
      store.keys == [
        "order.total", "order.priority", "order.nativePriority", "order.user", "order.tags",
        "order.count"
      ]
    )
    #expect(store.value(forKey: "order.total", as: String.self) == "1250 cents")
    #expect(store.value(forKey: "order.total", as: Money.self) == self.order.total)
    #expect(store.value(forKey: "order.priority", as: Double.self) == 1)
    #expect(store.value(forKey: "order.nativePriority", as: Int64.self) == 1)
    #expect(store.value(forKey: "order.user", as: Double.self) == 42)
    #expect(store.value(forKey: "order.tags", as: [String].self) == ["a", "b"])
    #expect(store.value(forKey: "order.count", as: Double.self) == 3)
    #expect(
      try store.decode(Order.self, fromKeysUnder: "order", options: .init(arrays: .native))
        == self.order
    )
  }

  @Test func `Throws For A Value Type That Does Not Read`() throws {
    let store = try makeStore()
    try store.encode(self.order, intoKeysUnder: "order", options: .init(arrays: .native))
    store.set("free", forKey: "order.total")

    #expect {
      try store.decode(Order.self, fromKeysUnder: "order", options: .init(arrays: .native))
    } throws: { error in
      if case DecodingError.dataCorrupted = error { true } else { false }
    }
  }

  @Test func `Throws For A Value Type That Is Missing`() throws {
    let store = try makeStore()

    #expect {
      try store.decode(Money.self, fromKeysUnder: "total")
    } throws: { error in
      if case DecodingError.keyNotFound = error { true } else { false }
    }
    #expect(try store.decode(Money?.self, fromKeysUnder: "total") == nil)
  }

  @Test func `Reports A Value That Refuses To Be Stored`() throws {
    struct Wrapper: Codable {
      var count: MMKVIntegerEncodingTests.Count
      var name: String
    }
    let store = try makeStore()
    let wrapper = Wrapper(count: .init(rawValue: (1 << 53) + 1), name: "Blob")

    #expect(try !store.encode(wrapper, intoKeysUnder: "wrapper"))
    #expect(store.keys == ["wrapper.name"])
  }
}

extension MMKVIntegerEncodingTests.Count: Codable {}
