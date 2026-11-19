// The cryptography MMKV's core needs: AES-128 and AES-256 in CFB-128 mode, and MD5. Also the
// CRC-32 it checksums its data with.
//
// This is the OpenSSL-derived code MMKV ships, ported out of its C++ namespace into C. Every
// symbol starts with `swiftmmkv_`, so it cannot collide with the copy of MMKV that
// react-native-mmkv links into the same app. See README.md beside this directory.

#ifndef CSWIFTMMKVCRYPTO_H
#define CSWIFTMMKVCRYPTO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// An expanded AES key. Its layout is shared by the portable C implementation and the ARMv8
/// assembly, but a key expanded by one must only be used with the same one.
typedef struct swiftmmkv_aes_key {
  uint32_t rd_key[60];
  int32_t rounds;
} swiftmmkv_aes_key;

/// Expands `user_key`, of `bits` bits (128, 192, or 256), for encryption.
///
/// - Returns: 0 on success, -1 for a null argument, -2 for an unsupported size.
int swiftmmkv_aes_set_encrypt_key(
  const uint8_t *_Nonnull user_key, int bits, swiftmmkv_aes_key *_Nonnull key);

/// Encrypts one 16-byte block. `in` and `out` may be the same.
void swiftmmkv_aes_encrypt(
  const uint8_t *_Nonnull in, uint8_t *_Nonnull out, const swiftmmkv_aes_key *_Nonnull key);

/// Whether the functions above use the ARMv8 AES instructions rather than the portable C
/// implementation.
bool swiftmmkv_aes_uses_hardware(void);

// The portable C implementation, always available, so tests can compare it with the assembly.

int swiftmmkv_aes_portable_set_encrypt_key(
  const uint8_t *_Nonnull user_key, int bits, swiftmmkv_aes_key *_Nonnull key);
void swiftmmkv_aes_portable_encrypt(
  const uint8_t *_Nonnull in, uint8_t *_Nonnull out, const swiftmmkv_aes_key *_Nonnull key);

/// Encrypts `length` bytes in CFB-128 mode, continuing the stream described by `ivec` and `num`.
///
/// `ivec` is 16 bytes and `num` is how far into the current block the stream is (0 to 15). Both
/// are updated, so successive calls encrypt one continuous stream. `in` and `out` may be the
/// same. This is OpenSSL's `AES_cfb128_encrypt`.
void swiftmmkv_aes_cfb128_encrypt(
  const uint8_t *_Nullable in, uint8_t *_Nullable out, size_t length,
  const swiftmmkv_aes_key *_Nonnull key, uint8_t *_Nonnull ivec, uint32_t *_Nonnull num);

/// Decrypts `length` bytes in CFB-128 mode, continuing the stream described by `ivec` and `num`.
void swiftmmkv_aes_cfb128_decrypt(
  const uint8_t *_Nullable in, uint8_t *_Nullable out, size_t length,
  const swiftmmkv_aes_key *_Nonnull key, uint8_t *_Nonnull ivec, uint32_t *_Nonnull num);

/// Overwrites `length` bytes at `pointer` with zeros in a way the compiler cannot remove, for
/// wiping keys. This is MMKV's `secureWipe` (in `AESCrypt.cpp`).
void swiftmmkv_secure_wipe(void *_Nullable pointer, size_t length);

/// Writes the 16-byte MD5 digest of `length` bytes at `data` to `digest`.
void swiftmmkv_md5_digest(
  const uint8_t *_Nullable data, size_t length, uint8_t *_Nonnull digest);

/// Continues the CRC-32 `crc` over `length` bytes at `data`, as zlib's `crc32` does. Start from 0.
///
/// This uses the ARMv8 CRC32 instructions on 64-bit ARM when the CPU has them, and zlib's `crc32`
/// everywhere else.
uint32_t swiftmmkv_crc32(uint32_t crc, const uint8_t *_Nullable data, size_t length);

/// Whether ``swiftmmkv_crc32`` uses the ARMv8 CRC32 instructions rather than zlib.
bool swiftmmkv_crc32_uses_hardware(void);

/// ``swiftmmkv_crc32`` computed with zlib only, so tests can compare it with the instructions.
uint32_t swiftmmkv_crc32_zlib(uint32_t crc, const uint8_t *_Nullable data, size_t length);

#ifdef __cplusplus
}
#endif

#endif
