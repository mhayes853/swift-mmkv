import SwiftMMKV
import Testing

extension MMKVStore.DefaultedKey where Value == Int.MMKVNumber {
  fileprivate static let launches = Self("launches", default: 0)
}

@Suite struct MMKVIntTests {
  enum Priority: Int, MMKVValue {
    case low, high
  }

  enum SharedPriority: Int, MMKVValue {
    case low, high
    static let integerEncoding = MMKVIntegerEncoding.number
  }

  @Test func `An Int Is Stored As A 64 Bit Integer`() throws {
    let store = try makeStore()

    #expect(store.set(Int.min, forKey: "min"))
    #expect(store.set(Int.max, forKey: "max"))

    #expect(store.value(forKey: "min", as: Int.self) == .min)
    #expect(store.value(forKey: "max", as: Int.self) == .max)
    #expect(store.value(forKey: "max", as: Int64.self) == Int64(Int.max))
    #expect(store.value(forKey: "missing", as: Int.self) == nil)
  }

  @Test func `A UInt Is Stored As An Unsigned 64 Bit Integer`() throws {
    let store = try makeStore()

    #expect(store.set(UInt.max, forKey: "max"))

    #expect(store.value(forKey: "max", as: UInt.self) == .max)
    #expect(store.value(forKey: "max", as: UInt64.self) == UInt64(UInt.max))
    #expect(store.value(forKey: "missing", as: UInt.self) == nil)
  }

  @Test func `An Integer Literal Is Stored As An Int`() throws {
    let store = try makeStore()

    store.set(5, forKey: "count")
    store.set(Int64(7), forKey: "other")

    #expect(store.value(forKey: "count", as: Int64.self) == 5)
    #expect(store.value(forKey: "other", as: Int.self) == 7)
  }

  @Test func `A Typed Key Holds An Int`() throws {
    let store = try makeStore()
    let key = MMKVStore.Key<Int>("count")

    store[key] = 3

    #expect(store[key] == 3)
    #expect(store.value(forKey: "count", as: Int64.self) == 3)
  }

  @Test func `An Enum With An Int Raw Value Conforms`() throws {
    let store = try makeStore()

    store.set(Priority.high, forKey: "native")
    store.set(SharedPriority.high, forKey: "shared")

    #expect(store.value(forKey: "native", as: Priority.self) == .high)
    #expect(store.value(forKey: "native", as: Int64.self) == 1)
    #expect(store.value(forKey: "shared", as: SharedPriority.self) == .high)
    #expect(store.value(forKey: "shared", as: Double.self) == 1)
  }
}

@Suite struct MMKVNumberTests {
  struct Profile: Codable, Equatable {
    var age: Int.MMKVNumber
    var visits: UInt32.MMKVNumber?
  }

  @Test func `A Number Is Stored As A Double`() throws {
    let store = try makeStore()

    #expect(store.set(Int.MMKVNumber(42), forKey: "count"))
    store.set(7.0, forKey: "javascript")

    #expect(store.value(forKey: "count", as: Double.self) == 42)
    #expect(store.value(forKey: "count", as: Int.MMKVNumber.self)?.value == 42)
    #expect(store.value(forKey: "javascript", as: Int.MMKVNumber.self)?.value == 7)
    #expect(store.value(forKey: "missing", as: Int.MMKVNumber.self) == nil)
  }

  @Test func `A Number That Does Not Fit The Integer Reads As Nil`() throws {
    let store = try makeStore()
    store.set(2.5, forKey: "fraction")
    store.set(-1.0, forKey: "negative")
    store.set(300.0, forKey: "large")

    #expect(store.value(forKey: "fraction", as: Int.MMKVNumber.self) == nil)
    #expect(store.value(forKey: "negative", as: UInt.MMKVNumber.self) == nil)
    #expect(store.value(forKey: "large", as: UInt8.MMKVNumber.self) == nil)
    #expect(store.value(forKey: "large", as: Int16.MMKVNumber.self)?.value == 300)
  }

  @Test func `An Integer A Double Cannot Hold Is Not Stored`() throws {
    let store = try makeStore()

    #expect(store.set(Int64.MMKVNumber(1 << 53), forKey: "exact"))
    #expect(!store.set(Int64.MMKVNumber((1 << 53) + 1), forKey: "inexact"))

    #expect(store.value(forKey: "exact", as: Int64.MMKVNumber.self)?.value == 1 << 53)
    #expect(!store.contains("inexact"))
  }

  @Test func `A Typed Key Holds A Number`() throws {
    let store = try makeStore()

    #expect(store[.launches] == 0)
    store[.launches] += 1

    #expect(store[.launches] == 1)
    #expect(store.value(forKey: "launches", as: Double.self) == 1)
  }

  @Test func `A Number Is A Binary Integer`() {
    let number: Int.MMKVNumber = 7

    #expect(number + 1 == 8)
    #expect(number * 2 - 4 == 10)
    #expect(number / 2 == 3 && number % 2 == 1)
    #expect(-number == -7 && number.magnitude == 7)
    #expect(number < 8 && number == 7)
    #expect(Int(number) == 7 && Int.MMKVNumber(UInt8(7)) == number)
    #expect(UInt8.MMKVNumber(exactly: 300) == nil)
    #expect(UInt8.MMKVNumber(clamping: 300) == 255)
    #expect(Int.MMKVNumber(exactly: 2.5) == nil)
    #expect(number << 1 == 14 && number & 3 == 3)
    #expect("\(number)" == "7")
    #expect(Int.MMKVNumber.isSigned && !UInt.MMKVNumber.isSigned)
    #expect((0..<number).count == 7)
  }

  @Test func `A Number Spread Over Keys Is A Double Whatever The Options`() throws {
    let store = try makeStore()
    let profile = Profile(age: 30, visits: 4)
    let options = MMKVKeyCodingOptions(numbers: .native)

    #expect(try store.encode(profile, intoKeysUnder: "profile", options: options))

    #expect(store.value(forKey: "profile.age", as: Double.self) == 30)
    #expect(store.value(forKey: "profile.visits", as: Double.self) == 4)
    #expect(try store.decode(Profile.self, fromKeysUnder: "profile", options: options) == profile)
  }

  #if Foundation
    @Test func `A Number Is Coded As The Integer Alone`() throws {
      let store = try makeStore()
      let profile = Profile(age: 30, visits: nil)

      #expect(try store.encode(profile, forKey: "profile"))

      #expect(store.value(forKey: "profile", as: String.self) == #"{"age":30}"#)
      #expect(try store.decode(Profile.self, forKey: "profile") == profile)
    }
  #endif
}
