// A C interface to SwiftMMKV, for bindings in other languages.
//
// Conventions
//
// - Strings are NUL-terminated UTF-8. Those passed in are borrowed for the call, and those
//   passed to a callback are only valid inside the callback.
// - Bytes are a pointer and a count.
// - Values returned through an `out_` parameter are owned by the caller. Release strings and
//   bytes with `swiftmmkv_free`, and handles with their own destroy, free, close, or cancel
//   function. Nothing is written through an `out_` parameter when a function fails or finds
//   nothing.
// - Every function may be called from any thread unless it says otherwise.
// - A callback's context must be safe to use from any thread.

#ifndef SWIFTMMKV_H
#define SWIFTMMKV_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Nullability annotations are a Clang extension, which Clang itself warns about when it is
// asked to be pedantic.
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-extension"
#else
#if !defined(_Nullable)
#define _Nullable
#endif
#if !defined(_Nonnull)
#define _Nonnull
#endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Version

/// The version of this interface. It changes when a function or constant is removed or changes
/// meaning, and not when one is added.
#define SWIFTMMKV_ABI_VERSION 1

/// The `SWIFTMMKV_ABI_VERSION` of the library that is linked, to compare with that of the
/// header a binding was built against.
uint32_t swiftmmkv_abi_version(void);

// MARK: - Memory

/// Releases a string or a run of bytes that was returned through an `out_` parameter. NULL is
/// ignored.
void swiftmmkv_free(void *_Nullable pointer);

/// A list of strings, owned by the caller.
typedef struct swiftmmkv_string_list swiftmmkv_string_list;

size_t swiftmmkv_string_list_count(const swiftmmkv_string_list *_Nonnull list);
/// The string at `index`, which must be less than the list's count. The string belongs to the
/// list and is valid until the list is freed.
const char *_Nonnull swiftmmkv_string_list_get(
  const swiftmmkv_string_list *_Nonnull list, size_t index);
/// Frees the list and its strings. NULL is ignored.
void swiftmmkv_string_list_free(swiftmmkv_string_list *_Nullable list);

// MARK: - Status

/// Whether a function succeeded, and why not if it did not.
typedef int32_t swiftmmkv_status;
enum {
  SWIFTMMKV_OK = 0,
  /// The store could not be opened, for example because its identifier or its directory's path
  /// is empty.
  SWIFTMMKV_OPEN_FAILED = 1,
  /// The encryption key is empty or longer than its cipher allows.
  SWIFTMMKV_INVALID_ENCRYPTION_KEY = 2,
  /// The store could not be re-encrypted, for example because it is read-only.
  SWIFTMMKV_REKEY_FAILED = 3,
  /// The store is open in this process, so its files cannot be removed or replaced.
  SWIFTMMKV_STORE_IS_OPEN = 4,
  /// Some stores are open in this process, so they were left alone while the rest of their
  /// directory's stores were dealt with.
  SWIFTMMKV_STORES_ARE_OPEN = 5,
  /// The directory exists but its contents cannot be listed.
  SWIFTMMKV_DIRECTORY_UNREADABLE = 6,
  /// The store is suspended, so it turned the operation away. Try again once it is resumed.
  SWIFTMMKV_STORE_IS_SUSPENDED = 7,
  /// An argument is a value this version of the interface does not know, such as a mode that
  /// is not one of the `SWIFTMMKV_MODE_` constants.
  SWIFTMMKV_INVALID_ARGUMENT = 8,
  /// The store's files could not be copied into the backup directory.
  SWIFTMMKV_BACKUP_FAILED = 9,
  /// The store could not be overwritten with its copy in the backup directory, for example
  /// because it is open as read-only.
  SWIFTMMKV_RESTORE_FAILED = 10,
  /// Some stores could not be copied into the backup directory. The others were.
  SWIFTMMKV_STORES_NOT_BACKED_UP = 11,
  /// Some stores could not be overwritten with their copies in the backup directory. The
  /// others were.
  SWIFTMMKV_STORES_NOT_RESTORED = 12,
  /// The store's copy in the backup directory does not match its checksum, so nothing was
  /// restored from it.
  SWIFTMMKV_BACKUP_INVALID = 13,
  /// The backup directory is the directory the stores are in.
  SWIFTMMKV_BACKUP_IS_STORE_DIRECTORY = 14,
  /// The store did not accept a write.
  SWIFTMMKV_WRITE_FAILED = 15,
  /// The app group has no container this process can reach.
  SWIFTMMKV_APP_GROUP_CONTAINER_UNAVAILABLE = 16,
};

/// A description of `status` in English. The string is static and must not be freed.
const char *_Nonnull swiftmmkv_status_message(swiftmmkv_status status);

// MARK: - Configuration

/// Whether anything other than this copy of MMKV may have a store's files open. Every opener
/// of a file must agree on the mode, because the wrong choice loses writes.
typedef int32_t swiftmmkv_mode;
enum {
  /// Nothing else has the store's files open, so reads and writes take no file lock.
  SWIFTMMKV_MODE_SINGLE_PROCESS = 0,
  /// Another process, or another copy of MMKV in this process, may have the store's files
  /// open. Every operation takes a file lock and picks up the other side's changes.
  SWIFTMMKV_MODE_MULTI_PROCESS = 1,
};

/// The cipher a store's contents are encrypted with.
typedef int32_t swiftmmkv_encryption;
enum {
  SWIFTMMKV_ENCRYPTION_NONE = 0,
  /// AES-128 in CFB mode, with a key of 1 to 16 bytes.
  SWIFTMMKV_ENCRYPTION_AES128 = 1,
  /// AES-256 in CFB mode, with a key of 1 to 32 bytes.
  SWIFTMMKV_ENCRYPTION_AES256 = 2,
};

/// What to do when a store's file fails its integrity check, which can happen after the
/// process is killed in the middle of a write.
typedef int32_t swiftmmkv_recovery;
enum {
  /// Discard the file's contents and start empty.
  SWIFTMMKV_RECOVERY_DISCARD = 0,
  /// Keep whatever key-value pairs can still be read.
  SWIFTMMKV_RECOVERY_RECOVER = 1,
};

/// Which store to open and how to open it. A configuration is not thread-safe: use it from one
/// thread at a time.
typedef struct swiftmmkv_configuration swiftmmkv_configuration;

/// Creates a configuration for the store "mmkv.default" in `directory`, which is created when
/// the store is opened if it does not exist. The store is writable and unencrypted until the
/// setters below say otherwise.
///
/// The mode has no default because the wrong choice corrupts data: see `swiftmmkv_mode`.
swiftmmkv_configuration *_Nonnull swiftmmkv_configuration_create(
  const char *_Nonnull directory, swiftmmkv_mode mode);
/// Creates a configuration for a single-process store in a new directory inside the system's
/// temporary directory, for stores that do not need to last, such as those of tests.
swiftmmkv_configuration *_Nonnull swiftmmkv_configuration_create_temporary(void);
/// Destroys a configuration. NULL is ignored.
void swiftmmkv_configuration_destroy(swiftmmkv_configuration *_Nullable configuration);

/// Sets the store's identifier, which names its files inside its directory.
void swiftmmkv_configuration_set_id(
  swiftmmkv_configuration *_Nonnull configuration, const char *_Nonnull id);
void swiftmmkv_configuration_set_directory(
  swiftmmkv_configuration *_Nonnull configuration, const char *_Nonnull directory);
void swiftmmkv_configuration_set_mode(
  swiftmmkv_configuration *_Nonnull configuration, swiftmmkv_mode mode);
/// Sets whether writes are rejected.
void swiftmmkv_configuration_set_read_only(
  swiftmmkv_configuration *_Nonnull configuration, bool read_only);
/// Sets the cipher and key the store's contents are encrypted with. The key is copied, and is
/// ignored for `SWIFTMMKV_ENCRYPTION_NONE`.
void swiftmmkv_configuration_set_encryption(
  swiftmmkv_configuration *_Nonnull configuration, swiftmmkv_encryption encryption,
  const void *_Nullable key, size_t key_count);
/// Sets the size in bytes to create the store's file with. Zero uses one memory page.
void swiftmmkv_configuration_set_expected_capacity(
  swiftmmkv_configuration *_Nonnull configuration, size_t bytes);
void swiftmmkv_configuration_set_recovery(
  swiftmmkv_configuration *_Nonnull configuration, swiftmmkv_recovery recovery);
/// Sets whether a write is skipped when the key already holds an identical value, which keeps
/// the file from growing. MMKV ignores this for encrypted stores and stores with expiring keys.
void swiftmmkv_configuration_set_compare_before_set(
  swiftmmkv_configuration *_Nonnull configuration, bool enabled);
/// Sets the largest key-value pair the store accepts, in bytes. Zero means no limit.
void swiftmmkv_configuration_set_item_size_limit(
  swiftmmkv_configuration *_Nonnull configuration, size_t bytes);

// MARK: - Stores

/// An open store. Handles opened over the same files share their contents and their
/// listeners, and the configuration of the first to be opened wins.
typedef struct swiftmmkv_store swiftmmkv_store;

/// Opens a store. The configuration is copied, so it can be destroyed or changed afterwards.
///
/// An option that was set to something invalid is reported here: a mode, cipher, or recovery
/// that is not one of its constants as `SWIFTMMKV_INVALID_ARGUMENT`, and a key of the wrong
/// length as `SWIFTMMKV_INVALID_ENCRYPTION_KEY`.
swiftmmkv_status swiftmmkv_store_open(
  const swiftmmkv_configuration *_Nonnull configuration,
  swiftmmkv_store *_Nullable *_Nonnull out_store);
/// Releases a handle, which must not be used afterwards. NULL is ignored.
///
/// MMKV keeps the store's files open for the rest of the process, so this does not make the
/// store removable.
void swiftmmkv_store_close(swiftmmkv_store *_Nullable store);

// MARK: - Writes
//
// Each returns whether the value was stored. A write fails when the key is empty, the store is
// read-only or suspended, or the pair exceeds the store's item size limit.
//
// An `expires_in_seconds` of zero never expires.

bool swiftmmkv_store_set_bool(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, bool value,
  uint32_t expires_in_seconds);
bool swiftmmkv_store_set_int32(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, int32_t value,
  uint32_t expires_in_seconds);
bool swiftmmkv_store_set_uint32(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, uint32_t value,
  uint32_t expires_in_seconds);
bool swiftmmkv_store_set_int64(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, int64_t value,
  uint32_t expires_in_seconds);
bool swiftmmkv_store_set_uint64(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, uint64_t value,
  uint32_t expires_in_seconds);
bool swiftmmkv_store_set_float(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, float value,
  uint32_t expires_in_seconds);
bool swiftmmkv_store_set_double(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, double value,
  uint32_t expires_in_seconds);
bool swiftmmkv_store_set_string(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, const char *_Nonnull value,
  uint32_t expires_in_seconds);
/// MMKV copies the bytes before this returns. `bytes` may be NULL when `count` is zero.
bool swiftmmkv_store_set_bytes(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, const void *_Nullable bytes,
  size_t count, uint32_t expires_in_seconds);
/// `values` may be NULL when `count` is zero.
bool swiftmmkv_store_set_strings(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key,
  const char *_Nonnull const *_Nullable values, size_t count, uint32_t expires_in_seconds);

// MARK: - Reads
//
// Each returns whether the key has a value, and only then writes through its `out_`
// parameters. Nothing has a value while the store is suspended.
//
// MMKV does not record a value's type, so read a key as the type it was written as.

bool swiftmmkv_store_get_bool(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, bool *_Nonnull out_value);
bool swiftmmkv_store_get_int32(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, int32_t *_Nonnull out_value);
bool swiftmmkv_store_get_uint32(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, uint32_t *_Nonnull out_value);
bool swiftmmkv_store_get_int64(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, int64_t *_Nonnull out_value);
bool swiftmmkv_store_get_uint64(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, uint64_t *_Nonnull out_value);
bool swiftmmkv_store_get_float(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, float *_Nonnull out_value);
bool swiftmmkv_store_get_double(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, double *_Nonnull out_value);
/// Release the string with `swiftmmkv_free`.
///
/// `out_length` receives the string's length in bytes, without its terminator. That is more
/// than `strlen` reports when another writer stored a string that contains U+0000.
bool swiftmmkv_store_get_string(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key,
  char *_Nullable *_Nonnull out_value, size_t *_Nullable out_length);
/// Release the bytes with `swiftmmkv_free`, including those of an empty value, which has a
/// count of zero.
bool swiftmmkv_store_get_bytes(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key,
  uint8_t *_Nullable *_Nonnull out_bytes, size_t *_Nonnull out_count);
/// Release the list with `swiftmmkv_string_list_free`.
bool swiftmmkv_store_get_strings(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key,
  swiftmmkv_string_list *_Nullable *_Nonnull out_values);

// MARK: - Keys

bool swiftmmkv_store_contains(swiftmmkv_store *_Nonnull store, const char *_Nonnull key);
/// The number of keys in the store.
size_t swiftmmkv_store_count(swiftmmkv_store *_Nonnull store);
/// Every key in the store, in no particular order. Release the list with
/// `swiftmmkv_string_list_free`.
swiftmmkv_string_list *_Nonnull swiftmmkv_store_keys(swiftmmkv_store *_Nonnull store);

// MARK: - Removal

/// Removes `key` and its value, and returns whether the store accepted the removal. MMKV also
/// reports success for a key that had no value.
bool swiftmmkv_store_remove(swiftmmkv_store *_Nonnull store, const char *_Nonnull key);
/// Removes the values of several keys at once. `keys` may be NULL when `count` is zero.
void swiftmmkv_store_remove_many(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull const *_Nullable keys, size_t count);
/// Removes every key and value. With `keeping_capacity` the store's file keeps its current
/// size, which is faster and saves growing it again. Without, it shrinks back to its initial
/// size.
void swiftmmkv_store_remove_all(swiftmmkv_store *_Nonnull store, bool keeping_capacity);

/// Copies every key and value of `source` into `store`, replacing the keys `store` already
/// has, and returns the number of keys copied.
size_t swiftmmkv_store_import_all(
  swiftmmkv_store *_Nonnull store, swiftmmkv_store *_Nonnull source);

// MARK: - Exclusive Access

typedef void (*swiftmmkv_locked_callback)(
  void *_Nullable context, swiftmmkv_store *_Nonnull store);

/// Calls `body` once, before returning, with exclusive access to the store.
///
/// Nothing else can read or write the store until `body` returns: not another thread, and, for
/// a multi-process store, not another process or another copy of MMKV in this process. Use it
/// for a read-modify-write that must not be interleaved, and for batches. The lock is
/// recursive, so `body` may call any function on the store it is given, including this one.
///
/// Listeners are told about the keys `body` changed once it returns, each key once.
void swiftmmkv_store_with_exclusive_lock(
  swiftmmkv_store *_Nonnull store, void *_Nullable context,
  swiftmmkv_locked_callback _Nonnull body);

// MARK: - Changes

typedef int32_t swiftmmkv_change_kind;
enum {
  /// The value of a key was set or removed through this package, in this process.
  SWIFTMMKV_CHANGE_KEY = 0,
  /// Another process, or another copy of MMKV in this process, changed the store. Which keys
  /// changed is not known.
  SWIFTMMKV_CHANGE_EXTERNAL = 1,
};

/// Receives a change to a store. `key` is the key that changed, or NULL for an external
/// change.
///
/// It runs on the thread that made or noticed the change, after the operation has returned,
/// and may read and write the store.
typedef void (*swiftmmkv_change_callback)(
  void *_Nullable context, swiftmmkv_change_kind kind, const char *_Nullable key);

/// Called once with a callback's context, when the callback will not be called again.
typedef void (*swiftmmkv_context_release)(void *_Nullable context);

/// A registration of a callback.
typedef struct swiftmmkv_subscription swiftmmkv_subscription;

/// Stops a subscription's callback from being called, and frees the subscription. NULL is
/// ignored.
///
/// A call that another thread already has under way may still finish afterwards. The
/// context's release function runs once no call can be.
void swiftmmkv_subscription_cancel(swiftmmkv_subscription *_Nullable subscription);

/// Calls `on_change` whenever the store's contents change, until the subscription is
/// cancelled.
swiftmmkv_subscription *_Nonnull swiftmmkv_store_subscribe(
  swiftmmkv_store *_Nonnull store, void *_Nullable context,
  swiftmmkv_change_callback _Nonnull on_change, swiftmmkv_context_release _Nullable release);
/// Calls `on_change` whenever the value of `key` may have changed, until the subscription is
/// cancelled. That is whenever `key` is set or removed, and on every external change, since
/// such a change does not say which keys it touched.
swiftmmkv_subscription *_Nonnull swiftmmkv_store_subscribe_key(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, void *_Nullable context,
  swiftmmkv_change_callback _Nonnull on_change, swiftmmkv_context_release _Nullable release);

/// Checks whether another process, or another copy of MMKV, changed the store, reloading it
/// and notifying listeners if so. Reads and writes make the same check, so this is only needed
/// while the store is otherwise idle.
void swiftmmkv_store_check_for_external_changes(swiftmmkv_store *_Nonnull store);

// MARK: - Suspension
//
// iOS terminates an app that is suspended while it holds a lock on a file in a container it
// shares with other processes. A multi-process store takes such a lock for every read and
// write, so suspend it when the app is about to stop running and resume it afterwards.
//
// While a store is suspended, reads find nothing, writes and removals do nothing, and
// functions that return a status return `SWIFTMMKV_STORE_IS_SUSPENDED`. A single-process store
// takes no file lock, so suspending one does nothing.

bool swiftmmkv_store_is_suspended(swiftmmkv_store *_Nonnull store);
/// Turns new operations away, waits for those under way, and returns once nothing holds the
/// store's file lock. Do not call this from inside `swiftmmkv_store_with_exclusive_lock`.
void swiftmmkv_store_suspend(swiftmmkv_store *_Nonnull store);
/// Lets the store take its file lock again, and tells listeners of an external change.
void swiftmmkv_store_resume(swiftmmkv_store *_Nonnull store);

// MARK: - Maintenance

/// The size of the store's file in bytes.
size_t swiftmmkv_store_byte_size(swiftmmkv_store *_Nonnull store);
/// The number of bytes of the store's file that hold data.
size_t swiftmmkv_store_used_byte_size(swiftmmkv_store *_Nonnull store);
/// Rewrites the store's file without the space left behind by removed and overwritten values.
void swiftmmkv_store_trim(swiftmmkv_store *_Nonnull store);
/// Blocks until the store's contents are flushed to disk. The operating system flushes a
/// memory-mapped file by itself, even if the process crashes, so this only matters when the
/// device may lose power.
void swiftmmkv_store_sync(swiftmmkv_store *_Nonnull store);
/// Re-encrypts the store with `encryption` and `key`, or decrypts it with
/// `SWIFTMMKV_ENCRYPTION_NONE`.
swiftmmkv_status swiftmmkv_store_rekey(
  swiftmmkv_store *_Nonnull store, swiftmmkv_encryption encryption,
  const void *_Nullable key, size_t key_count);

/// Copies the store's files into the directory `backup`, replacing a copy already there.
swiftmmkv_status swiftmmkv_store_back_up(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull backup);
/// Replaces the store's contents with those of its copy in the directory `backup`.
/// `out_restored` receives whether `backup` held a copy of the store.
swiftmmkv_status swiftmmkv_store_restore(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull backup, bool *_Nullable out_restored);

// MARK: - Directories
//
// These work on the stores in a directory without opening them.

/// Whether `directory` holds a store with this identifier, which it does once the store has
/// been opened.
bool swiftmmkv_directory_contains_store(
  const char *_Nonnull directory, const char *_Nonnull id);
/// Whether the store with this identifier has files whose contents match their checksum.
bool swiftmmkv_directory_is_store_valid(
  const char *_Nonnull directory, const char *_Nonnull id);
/// Deletes a store's files. `out_removed` receives whether there were any.
///
/// Fails with `SWIFTMMKV_STORE_IS_OPEN` if the store has been opened in this process, even if
/// its handles have since been closed.
swiftmmkv_status swiftmmkv_directory_remove_store(
  const char *_Nonnull directory, const char *_Nonnull id, bool *_Nullable out_removed);
/// Deletes the files of every store in `directory`. `out_count` receives the number removed.
///
/// Stores that are open in this process are left alone, and reported with
/// `SWIFTMMKV_STORES_ARE_OPEN` once every other store has been removed.
swiftmmkv_status swiftmmkv_directory_remove_all_stores(
  const char *_Nonnull directory, size_t *_Nullable out_count);

/// Copies a store's files into the directory `backup`. `out_backed_up` receives whether there
/// was a store to back up.
swiftmmkv_status swiftmmkv_directory_back_up_store(
  const char *_Nonnull directory, const char *_Nonnull id, const char *_Nonnull backup,
  bool *_Nullable out_backed_up);
/// Copies every store in `directory` into the directory `backup`. `out_count` receives the
/// number backed up.
swiftmmkv_status swiftmmkv_directory_back_up_all_stores(
  const char *_Nonnull directory, const char *_Nonnull backup, size_t *_Nullable out_count);
/// Overwrites a store with its copy in the directory `backup`. `out_restored` receives whether
/// `backup` held a copy of the store.
swiftmmkv_status swiftmmkv_directory_restore_store(
  const char *_Nonnull directory, const char *_Nonnull id, const char *_Nonnull backup,
  bool *_Nullable out_restored);
/// Overwrites the stores in `directory` with their copies in the directory `backup`.
/// `out_count` receives the number restored.
swiftmmkv_status swiftmmkv_directory_restore_all_stores(
  const char *_Nonnull directory, const char *_Nonnull backup, size_t *_Nullable out_count);

// MARK: - Logging
//
// Logging is shared by every store in the process: there is one minimum level and one
// destination. By default, warnings and errors are printed to standard error, or to the system
// log on Android.

typedef int32_t swiftmmkv_log_level;
enum {
  /// What MMKV is doing, such as loading a file or growing one.
  SWIFTMMKV_LOG_INFO = 1,
  /// Something unexpected that MMKV carried on from.
  SWIFTMMKV_LOG_WARNING = 2,
  /// A failure, such as a file that cannot be opened or that fails its integrity check.
  SWIFTMMKV_LOG_ERROR = 3,
  /// As a minimum level, logs nothing. No message has this level.
  SWIFTMMKV_LOG_NONE = 4,
};

/// The least severe level that is logged, which starts as `SWIFTMMKV_LOG_WARNING`.
swiftmmkv_log_level swiftmmkv_log_minimum_level(void);
/// Sets the least severe level that is logged. A value that is not a level is ignored.
void swiftmmkv_log_set_minimum_level(swiftmmkv_log_level level);

/// Receives a message MMKV logged, with the MMKV source file, function, and line that logged
/// it.
///
/// It runs on the thread that logged the message, usually while MMKV holds the lock of the
/// store the message is about. It must not read or write a store.
typedef void (*swiftmmkv_log_callback)(
  void *_Nullable context, swiftmmkv_log_level level, const char *_Nonnull text,
  const char *_Nonnull file, const char *_Nonnull function, int32_t line);

/// Sends every message to `handler` instead of where messages go by default, or with a NULL
/// handler sends them there again. The context of the handler this replaces is released.
void swiftmmkv_log_set_handler(
  void *_Nullable context, swiftmmkv_log_callback _Nullable handler,
  swiftmmkv_context_release _Nullable release);

// MARK: - Integrity Failures

/// The check a store's file failed as it was loaded.
typedef int32_t swiftmmkv_integrity_failure_kind;
enum {
  /// The file's contents do not match their checksum.
  SWIFTMMKV_INTEGRITY_FAILURE_CHECKSUM = 0,
  /// The file is not as long as it records itself to be.
  SWIFTMMKV_INTEGRITY_FAILURE_FILE_LENGTH = 1,
};

/// Receives the identifier of a store whose file failed its integrity check. MMKV reports the
/// identifier alone, so stores with the same identifier in different directories cannot be
/// told apart.
///
/// It runs on the thread that was loading the file, while MMKV holds the store's lock. It must
/// not read or write a store.
typedef void (*swiftmmkv_integrity_failure_callback)(
  void *_Nullable context, const char *_Nonnull id, swiftmmkv_integrity_failure_kind kind);

/// Calls `on_failure` whenever the file of any store in this process fails its integrity
/// check, until the subscription is cancelled. Subscribe before using the stores to be told
/// about.
swiftmmkv_subscription *_Nonnull swiftmmkv_subscribe_to_integrity_failures(
  void *_Nullable context, swiftmmkv_integrity_failure_callback _Nonnull on_failure,
  swiftmmkv_context_release _Nullable release);

#ifdef __cplusplus
}
#endif

#if defined(__clang__)
#pragma clang diagnostic pop
#endif

#endif
