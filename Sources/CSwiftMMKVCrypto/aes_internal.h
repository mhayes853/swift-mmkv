// Shared by the AES sources of this target. Adapted from MMKV v2.4.3's
// Core/aes/openssl/openssl_aes_locl.h (OpenSSL); see README.md.

#ifndef SWIFTMMKV_AES_INTERNAL_H
#define SWIFTMMKV_AES_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

#include "CSwiftMMKVCrypto.h"

#define GETU32(pt) \
  (((u32)(pt)[0] << 24) ^ ((u32)(pt)[1] << 16) ^ ((u32)(pt)[2] << 8) ^ ((u32)(pt)[3]))
#define PUTU32(ct, st) \
  { \
    (ct)[0] = (u8)((st) >> 24); \
    (ct)[1] = (u8)((st) >> 16); \
    (ct)[2] = (u8)((st) >> 8); \
    (ct)[3] = (u8)(st); \
  }

typedef uint32_t u32;
typedef uint16_t u16;
typedef uint8_t u8;

#define AES_MAXNR 14

// The ARMv8 assembly in aesv8-armx.S, which only exists on 64-bit ARM.
#if defined(__aarch64__)
#  define SWIFTMMKV_HAS_ARMV8_AES 1
int swiftmmkv_aes_armv8_set_encrypt_key(const uint8_t *user_key, int bits, void *key);
int swiftmmkv_aes_armv8_set_decrypt_key(const uint8_t *user_key, int bits, void *key);
void swiftmmkv_aes_armv8_encrypt(const uint8_t *in, uint8_t *out, const void *key);
void swiftmmkv_aes_armv8_decrypt(const uint8_t *in, uint8_t *out, const void *key);
#endif

#endif
