// A C interface over MMKV's C++ core, sized for the Swift wrapper.
//
// Keys, strings, and byte values are passed as a pointer and a length, never as NUL-terminated
// strings, and values are read through callbacks so the Swift side can decode them without an
// intermediate allocation.

#ifndef CSWIFTMMKVCORE_H
#define CSWIFTMMKVCORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// An MMKV instance. Instances are owned by the core and live for the rest of the process.
typedef struct swiftmmkv_store swiftmmkv_store;

/// A run of bytes that is only valid for the duration of the call it is passed to.
typedef struct {
  const void *_Nullable bytes;
  size_t count;
} swiftmmkv_bytes;

enum {
  SWIFTMMKV_ENCRYPTION_NONE = 0,
  SWIFTMMKV_ENCRYPTION_AES128 = 1,
  SWIFTMMKV_ENCRYPTION_AES256 = 2,
};

typedef struct {
  swiftmmkv_bytes id;
  swiftmmkv_bytes root_directory;
  bool multi_process;
  bool read_only;
  int32_t encryption;
  swiftmmkv_bytes encryption_key;
  size_t expected_capacity;
  bool recover_on_error;
  bool compare_before_set;
  uint32_t item_size_limit;
} swiftmmkv_configuration;

/// Receives a run of bytes read from a store.
typedef void (*swiftmmkv_bytes_callback)(void *_Nullable context, swiftmmkv_bytes bytes);

/// Called when a store notices that another process, or another copy of MMKV in this process,
/// changed its file. The store's locks are held, so the callback must not call back into it.
typedef void (*swiftmmkv_content_changed_callback)(swiftmmkv_bytes id);

/// Installs the process-wide callback for content changes. Safe to call more than once.
void swiftmmkv_set_content_changed_callback(swiftmmkv_content_changed_callback _Nullable callback);

/// Opens the store described by `configuration`, or returns the instance already open for its
/// root directory and identifier. Returns NULL if the store could not be opened.
swiftmmkv_store *_Nullable swiftmmkv_open(const swiftmmkv_configuration *_Nonnull configuration);

// Writes. Each returns whether the value was stored. A `expires_in_seconds` of zero never expires.

bool swiftmmkv_set_bool(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, bool value, uint32_t expires_in_seconds);
bool swiftmmkv_set_int32(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, int32_t value, uint32_t expires_in_seconds);
bool swiftmmkv_set_uint32(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, uint32_t value,
  uint32_t expires_in_seconds);
bool swiftmmkv_set_int64(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, int64_t value, uint32_t expires_in_seconds);
bool swiftmmkv_set_uint64(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, uint64_t value,
  uint32_t expires_in_seconds);
bool swiftmmkv_set_float(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, float value, uint32_t expires_in_seconds);
bool swiftmmkv_set_double(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, double value, uint32_t expires_in_seconds);
bool swiftmmkv_set_string(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, swiftmmkv_bytes value,
  uint32_t expires_in_seconds);
bool swiftmmkv_set_bytes(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, swiftmmkv_bytes value,
  uint32_t expires_in_seconds);
bool swiftmmkv_set_strings(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, const swiftmmkv_bytes *_Nullable values,
  size_t count, uint32_t expires_in_seconds);

// Reads. Each returns whether the key has a value, and only then writes to `value` or calls
// `callback`.

bool swiftmmkv_get_bool(swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, bool *_Nonnull value);
bool swiftmmkv_get_int32(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, int32_t *_Nonnull value);
bool swiftmmkv_get_uint32(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, uint32_t *_Nonnull value);
bool swiftmmkv_get_int64(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, int64_t *_Nonnull value);
bool swiftmmkv_get_uint64(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, uint64_t *_Nonnull value);
bool swiftmmkv_get_float(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, float *_Nonnull value);
bool swiftmmkv_get_double(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, double *_Nonnull value);
bool swiftmmkv_get_string(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, void *_Nullable context,
  swiftmmkv_bytes_callback _Nonnull callback);
bool swiftmmkv_get_bytes(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, void *_Nullable context,
  swiftmmkv_bytes_callback _Nonnull callback);
/// Calls `callback` once per string, in order.
bool swiftmmkv_get_strings(
  swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key, void *_Nullable context,
  swiftmmkv_bytes_callback _Nonnull callback);

// Keys.

bool swiftmmkv_contains(swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key);
size_t swiftmmkv_count(swiftmmkv_store *_Nonnull store);
/// Calls `callback` once per key, in no particular order.
void swiftmmkv_keys(
  swiftmmkv_store *_Nonnull store, void *_Nullable context,
  swiftmmkv_bytes_callback _Nonnull callback);

// Removal.

bool swiftmmkv_remove(swiftmmkv_store *_Nonnull store, swiftmmkv_bytes key);
bool swiftmmkv_remove_many(
  swiftmmkv_store *_Nonnull store, const swiftmmkv_bytes *_Nullable keys, size_t count);
void swiftmmkv_remove_all(swiftmmkv_store *_Nonnull store, bool keep_capacity);

// Locking. The lock excludes other threads in this process and, for a multi-process store, other
// processes and other copies of MMKV. It is recursive on the thread that holds it.

void swiftmmkv_lock(swiftmmkv_store *_Nonnull store);
void swiftmmkv_unlock(swiftmmkv_store *_Nonnull store);

// Maintenance.

void swiftmmkv_trim(swiftmmkv_store *_Nonnull store);
void swiftmmkv_sync(swiftmmkv_store *_Nonnull store);
void swiftmmkv_check_content_changed(swiftmmkv_store *_Nonnull store);
bool swiftmmkv_rekey(
  swiftmmkv_store *_Nonnull store, int32_t encryption, swiftmmkv_bytes encryption_key);

#ifdef __cplusplus
}
#endif

#endif
