/// How ``MMKVStore/encode(_:intoKeysUnder:removingOtherKeys:expiry:options:)`` and
/// ``MMKVStore/decode(_:fromKeysUnder:options:)`` spread a value over the keys of a store.
///
/// The defaults store values the way a React Native app reads and writes them.
public struct MMKVKeyCodingOptions: Sendable {
  /// Joins the prefix and the names along the path to a property, to make its key. Starts as
  /// `"."`.
  ///
  /// A property name or dictionary key that contains the separator is not escaped, so it reads
  /// as a path of several names.
  public var separator: String

  /// How integers and `Float` are stored. Starts as ``Numbers/double``.
  public var numbers: Numbers

  /// How arrays are stored. Starts as JSON with the `Foundation` trait, and as
  /// ``Arrays/native`` without it.
  public var arrays: Arrays

  #if Foundation
    /// Creates options.
    ///
    /// - Parameters:
    ///   - separator: Joins the prefix and the names along the path to a property.
    ///   - numbers: How integers and `Float` are stored.
    ///   - arrays: How arrays are stored.
    public init(separator: String = ".", numbers: Numbers = .double, arrays: Arrays = .json) {
      self.separator = separator
      self.numbers = numbers
      self.arrays = arrays
    }
  #else
    /// Creates options.
    ///
    /// - Parameters:
    ///   - separator: Joins the prefix and the names along the path to a property.
    ///   - numbers: How integers and `Float` are stored.
    ///   - arrays: How arrays are stored.
    public init(separator: String = ".", numbers: Numbers = .double, arrays: Arrays = .native) {
      self.separator = separator
      self.numbers = numbers
      self.arrays = arrays
    }
  #endif
}

// MARK: - Numbers

extension MMKVKeyCodingOptions {
  /// How integers and `Float` are stored.
  ///
  /// MMKV does not record the type of a value, so both sides of a store must agree on one.
  public enum Numbers: Sendable, Hashable {
    /// Every number is stored as a `Double`, which is how JavaScript stores numbers.
    ///
    /// Encoding throws for an integer that a `Double` cannot hold exactly, which are some of
    /// those beyond 2^53. Decoding an integer throws if the stored number has a fraction or
    /// does not fit the integer's type.
    case double

    /// Each type is stored in its own form: integers of up to 32 bits as `Int32` or `UInt32`,
    /// wider ones, `Int` and `UInt` as `Int64` or `UInt64`, and `Float` as `Float`.
    case native
  }
}

// MARK: - Arrays

extension MMKVKeyCodingOptions {
  /// How arrays are stored. An array is always stored whole under one key, never with a key
  /// for each element.
  ///
  /// This applies to anything that encodes itself as a sequence of values, such as `Set`, and
  /// a `Dictionary` whose keys are neither strings nor integers. Bytes are not affected:
  /// `[UInt8]`, and `Data` with the `Foundation` trait, are always stored as bytes.
  public struct Arrays: Sendable {
    fileprivate let coding: KeyArrayCoding

    /// Arrays of strings use MMKV's own encoding, which React Native cannot read. Encoding or
    /// decoding any other array throws.
    public static var native: Arrays {
      Arrays(coding: .native)
    }

    /// Every array is encoded whole by `encoder`, and decoded by `decoder`.
    ///
    /// - Parameters:
    ///   - encoder: Encodes each array.
    ///   - decoder: Decodes each array from what `encoder` gave.
    public static func coded<Encoder, Decoder>(encoder: Encoder, decoder: Decoder) -> Arrays
    where
      Encoder: MMKVTopLevelEncoder & Sendable,
      Decoder: MMKVTopLevelDecoder & Sendable,
      Encoder.Output: MMKVValue,
      Decoder.Input == Encoder.Output
    {
      Arrays(coding: KeyArrayCoding(encoder: encoder, decoder: decoder))
    }
  }
}

extension KeyArrayCoding {
  init(_ arrays: MMKVKeyCodingOptions.Arrays) {
    self = arrays.coding
  }
}
