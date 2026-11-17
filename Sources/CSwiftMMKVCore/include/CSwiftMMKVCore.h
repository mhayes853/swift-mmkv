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

// React Native apps link their own copy of MMKV, and other libraries are free to pick the same
// short names used here. Each function therefore links under a `swiftmmkv_` symbol, whatever it
// is called in source.
#define CSWIFTMMKV_STRINGIFY_(x) #x
#define CSWIFTMMKV_STRINGIFY(x) CSWIFTMMKV_STRINGIFY_(x)
#define CSWIFTMMKV_SYMBOL(name) \
  __asm__(CSWIFTMMKV_STRINGIFY(__USER_LABEL_PREFIX__) "swiftmmkv_" #name)

/// An MMKV instance. Instances are owned by the core and live for the rest of the process.
typedef struct mmkv_store mmkv_store;

/// A run of bytes that is only valid for the duration of the call it is passed to.
typedef struct {
  const void *_Nullable bytes;
  size_t count;
} mmkv_bytes;

enum {
  MMKV_ENCRYPTION_NONE = 0,
  MMKV_ENCRYPTION_AES128 = 1,
  MMKV_ENCRYPTION_AES256 = 2,
};

typedef struct {
  mmkv_bytes id;
  mmkv_bytes root_directory;
  bool multi_process;
  bool read_only;
  int32_t encryption;
  mmkv_bytes encryption_key;
  size_t expected_capacity;
  bool recover_on_error;
  bool compare_before_set;
  uint32_t item_size_limit;
} mmkv_configuration;

/// Receives a run of bytes read from a store.
typedef void (*mmkv_bytes_callback)(void *_Nullable context, mmkv_bytes bytes);

/// Called when a store notices that another process, or another copy of MMKV in this process,
/// changed its file. The store's locks are held, so the callback must not call back into it.
typedef void (*mmkv_content_changed_callback)(mmkv_bytes id);

/// Installs the process-wide callback for content changes. Safe to call more than once.
void mmkv_set_content_changed_callback(mmkv_content_changed_callback _Nullable callback)
  CSWIFTMMKV_SYMBOL(set_content_changed_callback);

/// Opens the store described by `configuration`, or returns the instance already open for its
/// root directory and identifier. Returns NULL if the store could not be opened.
mmkv_store *_Nullable mmkv_open(const mmkv_configuration *_Nonnull configuration)
  CSWIFTMMKV_SYMBOL(open);

// Stores on disk.

enum {
  /// The store had no files to remove.
  MMKV_REMOVE_STORAGE_MISSING = 0,
  MMKV_REMOVE_STORAGE_REMOVED = 1,
  /// The store is open in this process, so nothing was removed.
  MMKV_REMOVE_STORAGE_OPEN = 2,
};

/// Whether both of a store's files exist. Does not open the store.
bool mmkv_storage_exists(mmkv_bytes id, mmkv_bytes root_directory)
  CSWIFTMMKV_SYMBOL(storage_exists);
/// Deletes a store's files while holding its file lock, unless `mmkv_open` has returned an
/// instance for it. Returns one of the `MMKV_REMOVE_STORAGE` values.
int32_t mmkv_remove_storage(mmkv_bytes id, mmkv_bytes root_directory)
  CSWIFTMMKV_SYMBOL(remove_storage);

// Writes. Each returns whether the value was stored. A `expires_in_seconds` of zero never expires.

bool mmkv_set_bool(
  mmkv_store *_Nonnull store, mmkv_bytes key, bool value, uint32_t expires_in_seconds)
  CSWIFTMMKV_SYMBOL(set_bool);
bool mmkv_set_int32(
  mmkv_store *_Nonnull store, mmkv_bytes key, int32_t value, uint32_t expires_in_seconds)
  CSWIFTMMKV_SYMBOL(set_int32);
bool mmkv_set_uint32(
  mmkv_store *_Nonnull store, mmkv_bytes key, uint32_t value,
  uint32_t expires_in_seconds)
  CSWIFTMMKV_SYMBOL(set_uint32);
bool mmkv_set_int64(
  mmkv_store *_Nonnull store, mmkv_bytes key, int64_t value, uint32_t expires_in_seconds)
  CSWIFTMMKV_SYMBOL(set_int64);
bool mmkv_set_uint64(
  mmkv_store *_Nonnull store, mmkv_bytes key, uint64_t value,
  uint32_t expires_in_seconds)
  CSWIFTMMKV_SYMBOL(set_uint64);
bool mmkv_set_float(
  mmkv_store *_Nonnull store, mmkv_bytes key, float value, uint32_t expires_in_seconds)
  CSWIFTMMKV_SYMBOL(set_float);
bool mmkv_set_double(
  mmkv_store *_Nonnull store, mmkv_bytes key, double value, uint32_t expires_in_seconds)
  CSWIFTMMKV_SYMBOL(set_double);
bool mmkv_set_string(
  mmkv_store *_Nonnull store, mmkv_bytes key, mmkv_bytes value,
  uint32_t expires_in_seconds)
  CSWIFTMMKV_SYMBOL(set_string);
bool mmkv_set_bytes(
  mmkv_store *_Nonnull store, mmkv_bytes key, mmkv_bytes value,
  uint32_t expires_in_seconds)
  CSWIFTMMKV_SYMBOL(set_bytes);
bool mmkv_set_strings(
  mmkv_store *_Nonnull store, mmkv_bytes key, const mmkv_bytes *_Nullable values,
  size_t count, uint32_t expires_in_seconds)
  CSWIFTMMKV_SYMBOL(set_strings);

// Reads. Each returns whether the key has a value, and only then writes to `value` or calls
// `callback`.

bool mmkv_get_bool(mmkv_store *_Nonnull store, mmkv_bytes key, bool *_Nonnull value)
  CSWIFTMMKV_SYMBOL(get_bool);
bool mmkv_get_int32(
  mmkv_store *_Nonnull store, mmkv_bytes key, int32_t *_Nonnull value)
  CSWIFTMMKV_SYMBOL(get_int32);
bool mmkv_get_uint32(
  mmkv_store *_Nonnull store, mmkv_bytes key, uint32_t *_Nonnull value)
  CSWIFTMMKV_SYMBOL(get_uint32);
bool mmkv_get_int64(
  mmkv_store *_Nonnull store, mmkv_bytes key, int64_t *_Nonnull value)
  CSWIFTMMKV_SYMBOL(get_int64);
bool mmkv_get_uint64(
  mmkv_store *_Nonnull store, mmkv_bytes key, uint64_t *_Nonnull value)
  CSWIFTMMKV_SYMBOL(get_uint64);
bool mmkv_get_float(
  mmkv_store *_Nonnull store, mmkv_bytes key, float *_Nonnull value)
  CSWIFTMMKV_SYMBOL(get_float);
bool mmkv_get_double(
  mmkv_store *_Nonnull store, mmkv_bytes key, double *_Nonnull value)
  CSWIFTMMKV_SYMBOL(get_double);
bool mmkv_get_string(
  mmkv_store *_Nonnull store, mmkv_bytes key, void *_Nullable context,
  mmkv_bytes_callback _Nonnull callback)
  CSWIFTMMKV_SYMBOL(get_string);
bool mmkv_get_bytes(
  mmkv_store *_Nonnull store, mmkv_bytes key, void *_Nullable context,
  mmkv_bytes_callback _Nonnull callback)
  CSWIFTMMKV_SYMBOL(get_bytes);
/// Calls `callback` once per string, in order.
bool mmkv_get_strings(
  mmkv_store *_Nonnull store, mmkv_bytes key, void *_Nullable context,
  mmkv_bytes_callback _Nonnull callback)
  CSWIFTMMKV_SYMBOL(get_strings);

// Keys.

bool mmkv_contains(mmkv_store *_Nonnull store, mmkv_bytes key)
  CSWIFTMMKV_SYMBOL(contains);
size_t mmkv_count(mmkv_store *_Nonnull store)
  CSWIFTMMKV_SYMBOL(count);
/// Calls `callback` once per key, in no particular order.
void mmkv_keys(
  mmkv_store *_Nonnull store, void *_Nullable context,
  mmkv_bytes_callback _Nonnull callback)
  CSWIFTMMKV_SYMBOL(keys);

// Removal.

bool mmkv_remove(mmkv_store *_Nonnull store, mmkv_bytes key)
  CSWIFTMMKV_SYMBOL(remove);
bool mmkv_remove_many(
  mmkv_store *_Nonnull store, const mmkv_bytes *_Nullable keys, size_t count)
  CSWIFTMMKV_SYMBOL(remove_many);
void mmkv_remove_all(mmkv_store *_Nonnull store, bool keep_capacity)
  CSWIFTMMKV_SYMBOL(remove_all);

// Locking. The lock excludes other threads in this process and, for a multi-process store, other
// processes and other copies of MMKV. It is recursive on the thread that holds it.

void mmkv_lock(mmkv_store *_Nonnull store)
  CSWIFTMMKV_SYMBOL(lock);
void mmkv_unlock(mmkv_store *_Nonnull store)
  CSWIFTMMKV_SYMBOL(unlock);

// Maintenance.

void mmkv_trim(mmkv_store *_Nonnull store)
  CSWIFTMMKV_SYMBOL(trim);
void mmkv_sync(mmkv_store *_Nonnull store)
  CSWIFTMMKV_SYMBOL(sync);
void mmkv_check_content_changed(mmkv_store *_Nonnull store)
  CSWIFTMMKV_SYMBOL(check_content_changed);
bool mmkv_rekey(
  mmkv_store *_Nonnull store, int32_t encryption, mmkv_bytes encryption_key)
  CSWIFTMMKV_SYMBOL(rekey);

#ifdef __cplusplus
}
#endif

#endif
