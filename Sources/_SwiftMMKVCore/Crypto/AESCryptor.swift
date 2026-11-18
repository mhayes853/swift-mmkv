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

  package var vector: [UInt8] {
    withUnsafeBytes(of: self.register) { Array($0) }
  }

  package static func == (lhs: CipherState, rhs: CipherState) -> Bool {
    lhs.register == rhs.register && lhs.number == rhs.number
  }
}

/// AES in CFB-128 mode, encrypting and decrypting one continuous stream, as MMKV's `AESCrypt`
/// does. The cryptography is the C in `CSwiftMMKVCrypto`.
package struct AESCryptor: @unchecked Sendable {
  package static let ivLength = 16

  package let isAES256: Bool
  /// The key, cut to or padded with zeros to 16 or 32 bytes.
  package let key: [UInt8]
  private let schedules: KeySchedules
  package private(set) var state: CipherState
  /// The IV the stream started from, at the start of the data.
  package var streamIV: [UInt8] {
    self.streamStart.vector
  }
  /// The state at the start of the data.
  private var streamStart: CipherState

  /// A cryptor for `key`, starting a stream from `iv`, or from the key's first 16 bytes if `iv` is
  /// `nil` (`AESCrypt(key, keyLength, iv, ivLength, aes256)`).
  package init(key: [UInt8], isAES256: Bool, iv: [UInt8]? = nil) {
    self.isAES256 = isAES256
    let maxKeyLength = isAES256 ? 32 : 16
    var padded = Array(key.prefix(maxKeyLength))
    padded += [UInt8](repeating: 0, count: maxKeyLength - padded.count)
    self.key = padded
    self.schedules = KeySchedules(key: padded)
    let start = iv.map { Self.fit($0) } ?? Array(padded.prefix(Self.ivLength))
    self.state = CipherState(vector: start, number: 0)
    self.streamStart = self.state
  }

  private static func fit(_ iv: [UInt8]) -> [UInt8] {
    var fitted = Array(iv.prefix(Self.ivLength))
    fitted += [UInt8](repeating: 0, count: Self.ivLength - fitted.count)
    return fitted
  }

  /// The key as MMKV's `cryptKey()` returns it: the padded key up to its first zero byte.
  package var keyUpToFirstZero: [UInt8] {
    Array(self.key.prefix { $0 != 0 })
  }

  /// Starts a new stream from `iv`, or from the key's first 16 bytes (`resetIV`).
  package mutating func resetIV(_ iv: [UInt8]? = nil) {
    let start = iv.map { Self.fit($0) } ?? Array(self.key.prefix(Self.ivLength))
    self.state = CipherState(vector: start, number: 0)
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
    guard count > 0 else { return }
    var number = self.state.number
    withUnsafeMutableBytes(of: &self.state.register) { register in
      swiftmmkv_aes_cfb128_encrypt(
        input.assumingMemoryBound(to: UInt8.self),
        output.assumingMemoryBound(to: UInt8.self),
        count,
        self.schedules.encrypt,
        register.baseAddress!.assumingMemoryBound(to: UInt8.self),
        &number
      )
    }
    self.state.number = number
  }

  package mutating func decrypt(
    _ input: UnsafeRawPointer,
    _ output: UnsafeMutableRawPointer,
    count: Int
  ) {
    guard count > 0 else { return }
    var number = self.state.number
    withUnsafeMutableBytes(of: &self.state.register) { register in
      swiftmmkv_aes_cfb128_decrypt(
        input.assumingMemoryBound(to: UInt8.self),
        output.assumingMemoryBound(to: UInt8.self),
        count,
        self.schedules.encrypt,
        register.baseAddress!.assumingMemoryBound(to: UInt8.self),
        &number
      )
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
    var previous =
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
      withUnsafeBytes(of: &previous.register) { input in
        swiftmmkv_aes_encrypt(
          input.baseAddress!.assumingMemoryBound(to: UInt8.self),
          output,
          self.schedules.encrypt
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

/// A key's expanded encryption and decryption schedules. They never change, so copies of a cryptor
/// share them, and they are wiped when the last copy goes away, as MMKV wipes its keys.
private final class KeySchedules: @unchecked Sendable {
  let encrypt: UnsafeMutablePointer<swiftmmkv_aes_key>
  let decrypt: UnsafeMutablePointer<swiftmmkv_aes_key>

  init(key: [UInt8]) {
    self.encrypt = .allocate(capacity: 1)
    self.decrypt = .allocate(capacity: 1)
    self.encrypt.initialize(to: swiftmmkv_aes_key())
    self.decrypt.initialize(to: swiftmmkv_aes_key())
    _ = swiftmmkv_aes_set_encrypt_key(key, Int32(key.count * 8), self.encrypt)
    _ = swiftmmkv_aes_set_decrypt_key(key, Int32(key.count * 8), self.decrypt)
  }

  deinit {
    for schedule in [self.encrypt, self.decrypt] {
      swiftmmkv_secure_wipe(schedule, MemoryLayout<swiftmmkv_aes_key>.size)
      schedule.deinitialize(count: 1)
      schedule.deallocate()
    }
  }
}
