// The CRC-32 MMKV checksums its data with, computed as MMKV v2.4.3 does (`crc32/Checksum.h` and
// `crc32_armv8.cpp`): with the ARMv8 CRC32 instructions when the CPU has them, and with zlib's
// `crc32` otherwise.
//
// MMKV uses the instructions only on 64-bit ARM Linux and Android, and zlib on Apple platforms.
// Here they are used on 64-bit ARM Apple platforms too: Apple's zlib takes longer to set up a
// call than the instructions take over a typical record of a few dozen bytes. Both compute the
// same function, and the tests check that they agree.

#include "CSwiftMMKVCrypto.h"

#include <limits.h>
#include <zlib.h>

static uint32_t zlibChecksum(uint32_t crc, const uint8_t *buf, size_t length) {
  uLong value = crc;
  // zlib takes an `unsigned int` length.
  while (length > 0) {
    uInt chunk = length > UINT_MAX ? UINT_MAX : (uInt)length;
    value = crc32(value, buf, chunk);
    buf += chunk;
    length -= chunk;
  }
  return (uint32_t)value;
}

#if defined(__aarch64__) && (defined(__linux__) || defined(__APPLE__))
#  include <stdatomic.h>
#  include <string.h>
#  if defined(__linux__)
#    include <sys/auxv.h>
#    ifndef HWCAP_CRC32
#      define HWCAP_CRC32 (1 << 7)
#    endif
#  else
#    include <sys/sysctl.h>
#  endif

#  define TARGET_CRC __attribute__((target("crc")))

TARGET_CRC static inline uint32_t armv8Small(uint32_t crc, const uint8_t *buf, size_t length) {
  if (length >= 4) {
    uint32_t word;
    memcpy(&word, buf, 4);
    crc = __builtin_arm_crc32w(crc, word);
    buf += 4;
    length -= 4;
  }
  if (length >= 2) {
    uint16_t half;
    memcpy(&half, buf, 2);
    crc = __builtin_arm_crc32h(crc, half);
    buf += 2;
    length -= 2;
  }
  if (length >= 1) {
    crc = __builtin_arm_crc32b(crc, *buf);
  }
  return crc;
}

TARGET_CRC static uint32_t armv8Checksum(uint32_t crc, const uint8_t *buf, size_t length) {
  crc = ~crc;
  // Up to an 8-byte boundary, then eight bytes at a time.
  size_t misalignment = (size_t)(-(uintptr_t)buf) & 7;
  size_t head = length < misalignment ? length : misalignment;
  crc = armv8Small(crc, buf, head);
  buf += head;
  length -= head;
  for (; length >= 64; length -= 64, buf += 64) {
    uint64_t words[8];
    memcpy(words, buf, 64);
    crc = __builtin_arm_crc32d(crc, words[0]);
    crc = __builtin_arm_crc32d(crc, words[1]);
    crc = __builtin_arm_crc32d(crc, words[2]);
    crc = __builtin_arm_crc32d(crc, words[3]);
    crc = __builtin_arm_crc32d(crc, words[4]);
    crc = __builtin_arm_crc32d(crc, words[5]);
    crc = __builtin_arm_crc32d(crc, words[6]);
    crc = __builtin_arm_crc32d(crc, words[7]);
  }
  for (; length >= 8; length -= 8, buf += 8) {
    uint64_t word;
    memcpy(&word, buf, 8);
    crc = __builtin_arm_crc32d(crc, word);
  }
  crc = armv8Small(crc, buf, length);
  return ~crc;
}

// 0 until checked, then 1 for the instructions or 2 for zlib. Checking twice is harmless, so the
// race to store it is too.
static _Atomic int hardwareState = 0;

static bool checkHardware(void) {
#  if defined(__linux__)
  return (getauxval(AT_HWCAP) & HWCAP_CRC32) != 0;
#  elif defined(__ARM_FEATURE_CRC32)
  // The target's baseline CPU has them, as every Apple silicon Mac does.
  return true;
#  else
  int value = 0;
  size_t size = sizeof(value);
  return sysctlbyname("hw.optional.armv8_crc32", &value, &size, NULL, 0) == 0 && value != 0;
#  endif
}

static bool hasHardware(void) {
  int state = atomic_load_explicit(&hardwareState, memory_order_relaxed);
  if (state == 0) {
    state = checkHardware() ? 1 : 2;
    atomic_store_explicit(&hardwareState, state, memory_order_relaxed);
  }
  return state == 1;
}

uint32_t swiftmmkv_crc32(uint32_t crc, const uint8_t *buf, size_t length) {
  if (length == 0) {
    return crc;
  }
  return hasHardware() ? armv8Checksum(crc, buf, length) : zlibChecksum(crc, buf, length);
}

bool swiftmmkv_crc32_uses_hardware(void) { return hasHardware(); }

uint32_t swiftmmkv_crc32_zlib(uint32_t crc, const uint8_t *buf, size_t length) {
  return length == 0 ? crc : zlibChecksum(crc, buf, length);
}

#else

uint32_t swiftmmkv_crc32(uint32_t crc, const uint8_t *buf, size_t length) {
  return length == 0 ? crc : zlibChecksum(crc, buf, length);
}

bool swiftmmkv_crc32_uses_hardware(void) { return false; }

uint32_t swiftmmkv_crc32_zlib(uint32_t crc, const uint8_t *buf, size_t length) {
  return swiftmmkv_crc32(crc, buf, length);
}

#endif
