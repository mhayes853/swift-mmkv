/*
 * Copyright 2008-2016 The OpenSSL Project Authors. All Rights Reserved.
 *
 * Licensed under the OpenSSL license (the "License").  You may not use
 * this file except in compliance with the License.  You can obtain a copy
 * in the file LICENSE in the source distribution or at
 * https://www.openssl.org/source/license.html
 */

/*
 * CFB-128 encryption and decryption, ported to C for swift-mmkv from MMKV v2.4.3
 * (Core/aes/openssl/openssl_cfb128.cpp), and the rollback of a decryption, from MMKV's
 * `Rollback_cfb_decrypt` in Core/aes/AESCrypt.cpp (Tencent, BSD 3-Clause). The word-at-a-time
 * loops, which read through unaligned `size_t` pointers, are byte loops here; the results are
 * identical. See README.md.
 */

#include "aes_internal.h"

void swiftmmkv_aes_cfb128_encrypt(
  const uint8_t *in, uint8_t *out, size_t len, const swiftmmkv_aes_key *key, uint8_t *ivec,
  uint32_t *num) {
  if (!in || !out || len == 0) {
    return;
  }
  uint32_t n = *num;

  while (n && len) {
    *(out++) = ivec[n] ^= *(in++);
    --len;
    n = (n + 1) % 16;
  }
  while (len >= 16) {
    swiftmmkv_aes_encrypt(ivec, ivec, key);
    for (; n < 16; ++n) {
      out[n] = ivec[n] ^= in[n];
    }
    len -= 16;
    out += 16;
    in += 16;
    n = 0;
  }
  if (len) {
    swiftmmkv_aes_encrypt(ivec, ivec, key);
    while (len--) {
      out[n] = ivec[n] ^= in[n];
      ++n;
    }
  }

  *num = n;
}

void swiftmmkv_aes_cfb128_decrypt(
  const uint8_t *in, uint8_t *out, size_t len, const swiftmmkv_aes_key *key, uint8_t *ivec,
  uint32_t *num) {
  if (!in || !out || len == 0) {
    return;
  }
  uint32_t n = *num;

  while (n && len) {
    uint8_t c = *(in++);
    *(out++) = ivec[n] ^ c;
    ivec[n] = c;
    --len;
    n = (n + 1) % 16;
  }
  while (len >= 16) {
    swiftmmkv_aes_encrypt(ivec, ivec, key);
    for (; n < 16; ++n) {
      uint8_t c = in[n];
      out[n] = ivec[n] ^ c;
      ivec[n] = c;
    }
    len -= 16;
    out += 16;
    in += 16;
    n = 0;
  }
  if (len) {
    swiftmmkv_aes_encrypt(ivec, ivec, key);
    while (len--) {
      uint8_t c = in[n];
      out[n] = ivec[n] ^ c;
      ivec[n] = c;
      ++n;
    }
  }

  *num = n;
}

void swiftmmkv_aes_cfb128_rollback(
  const uint8_t *input, const uint8_t *output, size_t len, const swiftmmkv_aes_key *key,
  uint8_t *ivec, uint32_t *num) {
  if (len == 0) {
    return;
  }
  uint32_t original = *num;
  uint32_t n = original;

  while (n && len) {
    uint8_t c = *(--output);
    ivec[--n] = *(--input) ^ c;
    len--;
  }
  if (n == 0 && original != 0) {
    swiftmmkv_aes_decrypt(ivec, ivec, key);
  }
  while (len >= 16) {
    len -= 16;
    output -= 16;
    input -= 16;
    for (; n < 16; ++n) {
      ivec[n] = input[n] ^ output[n];
    }
    n = 0;
    swiftmmkv_aes_decrypt(ivec, ivec, key);
  }
  if (len) {
    n = 16;
    do {
      uint8_t c = *(--output);
      ivec[--n] = *(--input) ^ c;
      len--;
    } while (len);
  }
  *num = n;
}

void swiftmmkv_secure_wipe(void *pointer, size_t length) {
  if (!pointer || length == 0) {
    return;
  }
  // Volatile writes cannot be removed as dead stores.
  volatile unsigned char *bytes = (volatile unsigned char *)pointer;
  while (length > 0) {
    *bytes++ = 0;
    --length;
  }
}
