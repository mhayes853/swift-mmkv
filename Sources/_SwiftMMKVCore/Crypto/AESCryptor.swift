import CSwiftMMKVCrypto

/// Where a CFB-128 stream is: the 16-byte feedback register and how far into the current block
/// the stream has gone (MMKV's `AESCryptStatus`).
package struct CipherState: Equatable, Sendable {
  /// The register, kept inline so that copying a state allocates nothing.
  var register: (UInt64, UInt64) = (0, 0)
  package var number: UInt32

  package init(vector: [UInt8], number: UInt32) {
    self.number = number
    vector.prefix(16)
      .withUnsafeBytes { source in
        withUnsafeMutableBytes(of: &self.register) { $0.copyMemory(from: source) }
      }
  }

  /// A state whose register is the 16 bytes at `vector`.
  init(vector: UnsafeRawPointer, number: UInt32) {
    self.number = number
    withUnsafeMutableBytes(of: &self.register) {
      $0.copyMemory(from: UnsafeRawBufferPointer(start: vector, count: 16))
    }
  }

  package static func == (lhs: CipherState, rhs: CipherState) -> Bool {
    lhs.register == rhs.register && lhs.number == rhs.number
  }
}

/// AES in CFB-128 mode, encrypting and decrypting one continuous stream, as MMKV's `AESCrypt`
/// does. The cryptography is the C in `CSwiftMMKVCrypto`.
package struct AESCryptor: @unchecked Sendable {
  private static let ivLength = 16

  package let isAES256: Bool
  /// The key, cut to or padded with zeros to 16 or 32 bytes.
  package let key: [UInt8]
  private let schedule: KeySchedule
  package private(set) var state: CipherState
  /// The state at the start of the data.
  private var streamStart: CipherState

  /// A cryptor for `key`, starting a stream from `iv`, or from the key's first 16 bytes if `iv` is
  /// `nil` (`AESCrypt(key, keyLength, iv, ivLength, aes256)`).
  package init(key: [UInt8], isAES256: Bool, iv: [UInt8]? = nil) {
    self.isAES256 = isAES256
    let key = Self.padded(key, to: isAES256 ? 32 : 16)
    self.key = key
    self.schedule = KeySchedule(key: key)
    self.state = Self.startState(iv: iv, key: key)
    self.streamStart = self.state
  }

  /// `bytes` cut to or padded with zeros to `count` bytes.
  private static func padded(_ bytes: [UInt8], to count: Int) -> [UInt8] {
    Array(bytes.prefix(count)) + [UInt8](repeating: 0, count: max(0, count - bytes.count))
  }

  /// The state at the start of a stream from `iv`, or from the key's first 16 bytes.
  private static func startState(iv: [UInt8]?, key: [UInt8]) -> CipherState {
    CipherState(vector: Self.padded(iv ?? key, to: Self.ivLength), number: 0)
  }

  /// The key as MMKV's `cryptKey()` returns it: the padded key up to its first zero byte.
  package var keyUpToFirstZero: [UInt8] {
    Array(self.key.prefix { $0 != 0 })
  }

  /// Starts a new stream from `iv`, or from the key's first 16 bytes (`resetIV`).
  package mutating func resetIV(_ iv: [UInt8]? = nil) {
    self.state = Self.startState(iv: iv, key: self.key)
    self.streamStart = self.state
  }

  /// A copy of this cryptor at `state` (`cloneWithStatus`).
  package func cloned(at state: CipherState) -> AESCryptor {
    var copy = self
    copy.state = state
    return copy
  }

  package mutating func encrypt(
    _ input: UnsafeRawPointer,
    _ output: UnsafeMutableRawPointer,
    count: Int
  ) {
    self.crypt(input, output, count: count, encrypting: true)
  }

  package mutating func decrypt(
    _ input: UnsafeRawPointer,
    _ output: UnsafeMutableRawPointer,
    count: Int
  ) {
    self.crypt(input, output, count: count, encrypting: false)
  }

  /// Continues the stream over `count` bytes. CFB runs the cipher forwards in both directions, so
  /// both use the encryption schedule.
  @inline(__always)
  private mutating func crypt(
    _ input: UnsafeRawPointer,
    _ output: UnsafeMutableRawPointer,
    count: Int,
    encrypting: Bool
  ) {
    guard count > 0 else { return }
    let input = input.assumingMemoryBound(to: UInt8.self)
    let output = output.assumingMemoryBound(to: UInt8.self)
    let key = self.schedule.expanded
    var number = self.state.number
    withUnsafeMutableBytes(of: &self.state.register) { register in
      let register = register.baseAddress!.assumingMemoryBound(to: UInt8.self)
      if encrypting {
        swiftmmkv_aes_cfb128_encrypt(input, output, count, key, register, &number)
      } else {
        swiftmmkv_aes_cfb128_decrypt(input, output, count, key, register, &number)
      }
    }
    self.state.number = number
  }

  /// The state of the stream after `offset` bytes, computed from the stream's ciphertext.
  ///
  /// MMKV rolls its stream back to find this while decoding a file. The state after a whole
  /// number of blocks is the last ciphertext block. Part way into a block, the bytes already
  /// processed are ciphertext and the rest of the register is the block's keystream, the
  /// encryption of the previous ciphertext block.
  ///
  /// - Parameter ciphertext: The stream's bytes from its start, at least `offset` of them.
  package func state(atOffset offset: Int, in ciphertext: UnsafeRawBufferPointer) -> CipherState {
    let remainder = offset % Self.ivLength
    let blockStart = offset - remainder
    let previous =
      blockStart == 0
      ? self.streamStart
      : CipherState(vector: ciphertext.baseAddress! + blockStart - Self.ivLength, number: 0)
    if remainder == 0 {
      return previous
    }
    var state = previous
    state.number = UInt32(remainder)
    withUnsafeMutableBytes(of: &state.register) { register in
      let output = register.baseAddress!.assumingMemoryBound(to: UInt8.self)
      // The block's keystream, of which the bytes already processed are replaced by ciphertext.
      withUnsafeBytes(of: previous.register) { input in
        swiftmmkv_aes_encrypt(
          input.baseAddress!.assumingMemoryBound(to: UInt8.self),
          output,
          self.schedule.expanded
        )
      }
      register.baseAddress!
        .copyMemory(from: ciphertext.baseAddress! + blockStart, byteCount: remainder)
    }
    return state
  }

  /// A random IV (`fillRandomIV`).
  package static func randomIV() -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<Self.ivLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
  }
}

/// A key's expanded encryption schedule, the only one CFB uses. It never changes, so copies of a
/// cryptor share it, and it is wiped when the last copy goes away, as MMKV wipes its keys.
private final class KeySchedule: @unchecked Sendable {
  let expanded: UnsafeMutablePointer<swiftmmkv_aes_key>

  init(key: [UInt8]) {
    self.expanded = .allocate(capacity: 1)
    self.expanded.initialize(to: swiftmmkv_aes_key())
    _ = swiftmmkv_aes_set_encrypt_key(key, Int32(key.count * 8), self.expanded)
  }

  deinit {
    swiftmmkv_secure_wipe(self.expanded, MemoryLayout<swiftmmkv_aes_key>.size)
    self.expanded.deinitialize(count: 1)
    self.expanded.deallocate()
  }
}
