// A C interface to SwiftMMKV, for bindings in other languages.
//
// Conventions
//
// - Strings are NUL-terminated UTF-8. Those passed in are borrowed for the call, and those
//   passed to a callback are only valid inside the callback.
// - Bytes are a pointer and a count.
// - A list of strings is packed: its strings lie end to end, each followed by a NUL. It is a
//   pointer and a size in bytes, which counts the terminators. A packed list cannot hold a
//   string that contains U+0000. A list that is passed in may leave out its last terminator.
// - A string, a run of bytes, or a list that a function returns is copied into a buffer the
//   caller owns: see "Buffers" below. The interface allocates nothing for the caller to free.
// - Handles are owned by the caller, and are released with their own destroy, close, or cancel
//   function.
// - Nothing is written through an `out_` parameter when a function fails or finds nothing.
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

// MARK: - Buffers
//
// A function that reads a value of no fixed size takes a `buffer` and its `capacity` in bytes,
// and reports the size of the value through an `out_` parameter.
//
// - The value is copied to the start of the buffer only if all of it fits. Nothing is copied
//   in part, so when the size reported is more than the capacity, the buffer is as it was.
//   Read again with a buffer of the size reported.
// - A NULL buffer copies nothing and reports the size, whatever the capacity.
//
// Another thread or process can change the value between two reads, so check the size that
// the second read reports as well.

// MARK: - Status

/// Whether a function succeeded, and why not if it did not.
typedef int32_t swiftmmkv_status;
#define SWIFTMMKV_OK 0
/// The store could not be opened, for example because its identifier or its directory's path
/// is empty.
#define SWIFTMMKV_OPEN_FAILED 1
/// The encryption key is empty or longer than its cipher allows.
#define SWIFTMMKV_INVALID_ENCRYPTION_KEY 2
/// The store could not be re-encrypted, for example because it is read-only.
#define SWIFTMMKV_REKEY_FAILED 3
/// The store is open in this process, so its files cannot be removed or replaced.
#define SWIFTMMKV_STORE_IS_OPEN 4
/// Some stores are open in this process, so they were left alone while the rest of their
/// directory's stores were dealt with.
#define SWIFTMMKV_STORES_ARE_OPEN 5
/// The directory exists but its contents cannot be listed.
#define SWIFTMMKV_DIRECTORY_UNREADABLE 6
/// The store is suspended, so it turned the operation away. Try again once it is resumed.
#define SWIFTMMKV_STORE_IS_SUSPENDED 7
/// An argument is a value this version of the interface does not know, such as a mode that
/// is not one of the `SWIFTMMKV_MODE_` constants.
#define SWIFTMMKV_INVALID_ARGUMENT 8
/// The store's files could not be copied into the backup directory.
#define SWIFTMMKV_BACKUP_FAILED 9
/// The store could not be overwritten with its copy in the backup directory, for example
/// because it is open as read-only.
#define SWIFTMMKV_RESTORE_FAILED 10
/// Some stores could not be copied into the backup directory. The others were.
#define SWIFTMMKV_STORES_NOT_BACKED_UP 11
/// Some stores could not be overwritten with their copies in the backup directory. The
/// others were.
#define SWIFTMMKV_STORES_NOT_RESTORED 12
/// The store's copy in the backup directory does not match its checksum, so nothing was
/// restored from it.
#define SWIFTMMKV_BACKUP_INVALID 13
/// The backup directory is the directory the stores are in.
#define SWIFTMMKV_BACKUP_IS_STORE_DIRECTORY 14
/// The store did not accept a write.
#define SWIFTMMKV_WRITE_FAILED 15
/// The app group has no container this process can reach.
#define SWIFTMMKV_APP_GROUP_CONTAINER_UNAVAILABLE 16
/// The store's file could not be rewritten without its expiries, for example because it is
/// read-only.
#define SWIFTMMKV_DISABLE_EXPIRY_FAILED 17
/// The operation failed in a way this version of the interface has no status for.
#define SWIFTMMKV_UNKNOWN_ERROR 18
/// The store is closed, so it turns every operation away. Open the store again to use it.
#define SWIFTMMKV_STORE_IS_CLOSED 19

/// A description of `status` in English. The string is static and must not be freed.
const char *_Nonnull swiftmmkv_status_message(swiftmmkv_status status);

// MARK: - Expiry

/// How long a store keeps a value.
///
/// Make one with the functions below. Its bits are private to the library and can change from
/// one version to the next, so never build one by hand or keep one outside the process. It is
/// a plain value: there is nothing to release, and it can be copied, kept, and used from any
/// thread.
///
/// An expired key reads as if it had been removed, and is left out of the store's keys and
/// count. Nothing reports the moment a key expires, so a change listener hears nothing until
/// the key is next written or removed.
///
/// MMKV records the second a key expires at, by the device's clock, so changing the clock moves
/// every expiry with it. Seconds are rounded up to a whole one, so that a value is never kept
/// for less time than was asked for, and the shortest a value is kept for is one second. A
/// number of seconds that is not a number makes an expiry that no function accepts.
typedef uint64_t swiftmmkv_expiry;

/// The expiry of the store that is written to: see `swiftmmkv_configuration_set_default_expiry`.
/// Zero is always this expiry.
#define SWIFTMMKV_EXPIRY_DEFAULT 0ULL

/// The value is kept until it is removed.
swiftmmkv_expiry swiftmmkv_expiry_never(void);
/// The value is kept for `seconds` from the moment it is written.
swiftmmkv_expiry swiftmmkv_expiry_after(double seconds);
/// The value is kept until `seconds_since_1970` seconds after the start of 1970 in UTC, which
/// is how a token's `exp` claim counts. A value written after that moment is kept for one
/// second, and a moment later than MMKV can record, which is in 2106, means never.
swiftmmkv_expiry swiftmmkv_expiry_at(double seconds_since_1970);

// MARK: - Configuration

/// Whether anything other than this copy of MMKV may have a store's files open. Every opener
/// of a file must agree on the mode, because the wrong choice loses writes.
typedef int32_t swiftmmkv_mode;
/// Nothing else has the store's files open, so reads and writes take no file lock.
#define SWIFTMMKV_MODE_SINGLE_PROCESS 0
/// Another process, or another copy of MMKV in this process, may have the store's files
/// open. Every operation takes a file lock and picks up the other side's changes.
#define SWIFTMMKV_MODE_MULTI_PROCESS 1

/// The cipher a store's contents are encrypted with.
typedef int32_t swiftmmkv_encryption;
#define SWIFTMMKV_ENCRYPTION_NONE 0
/// AES-128 in CFB mode, with a key of 1 to 16 bytes.
#define SWIFTMMKV_ENCRYPTION_AES128 1
/// AES-256 in CFB mode, with a key of 1 to 32 bytes.
#define SWIFTMMKV_ENCRYPTION_AES256 2

/// What to do when a store's file fails its integrity check, which can happen after the
/// process is killed in the middle of a write.
typedef int32_t swiftmmkv_recovery;
/// Discard the file's contents and start empty.
#define SWIFTMMKV_RECOVERY_DISCARD 0
/// Keep whatever key-value pairs can still be read.
#define SWIFTMMKV_RECOVERY_RECOVER 1

/// The data protection a store's files are given, which decides when iOS lets them be read.
///
/// A store's file is mapped into memory, and iOS ends a process that touches a mapped file
/// the device's lock has made unreadable. The classes that make a file unreadable while the
/// device is locked are therefore not offered.
typedef int32_t swiftmmkv_file_protection;
/// The files can be read once the device has been unlocked for the first time since it
/// started, which is what iOS gives an app's files by default.
#define SWIFTMMKV_FILE_PROTECTION_COMPLETE_UNTIL_FIRST_USER_AUTHENTICATION 0
/// The files can always be read, even before the device is first unlocked.
#define SWIFTMMKV_FILE_PROTECTION_NONE 1
/// The files keep whatever protection they have.
#define SWIFTMMKV_FILE_PROTECTION_UNCHANGED 2

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
/// Sets the data protection the store's files are given each time the store is opened, which
/// is `SWIFTMMKV_FILE_PROTECTION_COMPLETE_UNTIL_FIRST_USER_AUTHENTICATION` unless this says
/// otherwise.
///
/// A read-only store's files are left as they are, and nothing happens on a platform without
/// data protection. A file whose protection cannot be set is logged and does not fail the open.
void swiftmmkv_configuration_set_file_protection(
  swiftmmkv_configuration *_Nonnull configuration, swiftmmkv_file_protection protection);
/// Sets whether a write is skipped when the key already holds an identical value, which keeps
/// the file from growing. MMKV ignores this for encrypted stores and stores with expiring keys.
void swiftmmkv_configuration_set_compare_before_set(
  swiftmmkv_configuration *_Nonnull configuration, bool enabled);
/// Sets the largest key-value pair the store accepts, in bytes. Zero means no limit.
void swiftmmkv_configuration_set_item_size_limit(
  swiftmmkv_configuration *_Nonnull configuration, size_t bytes);
/// Sets how long the store keeps a value written with `SWIFTMMKV_EXPIRY_DEFAULT`, which is
/// until it is removed unless this says otherwise. `SWIFTMMKV_EXPIRY_DEFAULT` is not an expiry
/// a store can have, and fails the open.
///
/// This belongs to the store that is opened and not to its files, so it applies to that
/// store's writes alone. Values that are already stored keep the expiry they were written
/// with.
void swiftmmkv_configuration_set_default_expiry(
  swiftmmkv_configuration *_Nonnull configuration, swiftmmkv_expiry expiry);

// MARK: - Stores

/// An open store. Handles opened over the same files share their contents and their
/// listeners, and the configuration of the first to be opened wins.
typedef struct swiftmmkv_store swiftmmkv_store;

/// Opens a store. The configuration is copied, so it can be destroyed or changed afterwards.
///
/// An option that was set to something invalid is reported here: a mode, cipher, recovery, or
/// file protection that is not one of its constants as `SWIFTMMKV_INVALID_ARGUMENT`, and a key
/// of the wrong length as `SWIFTMMKV_INVALID_ENCRYPTION_KEY`.
swiftmmkv_status swiftmmkv_store_open(
  const swiftmmkv_configuration *_Nonnull configuration,
  swiftmmkv_store *_Nullable *_Nonnull out_store);
/// Releases a handle, which must not be used afterwards. NULL is ignored.
///
/// This does not close the store: its files stay open, and its other handles work as before.
/// To make the store removable, call `swiftmmkv_store_close` first.
void swiftmmkv_store_destroy(swiftmmkv_store *_Nullable store);

// MARK: - Writes
//
// Each returns whether the value was stored. A write fails when the key is empty, the store is
// read-only or suspended, the pair exceeds the store's item size limit, or `expiry` is not one
// that the functions of "Expiry" made.
//
// The first write that expires switches the store's file to a format that react-native-mmkv
// has no option for, so avoid one on a store shared with JavaScript.
// `swiftmmkv_store_disable_expiry` switches it back.

bool swiftmmkv_store_set_bool(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, bool value,
  swiftmmkv_expiry expiry);
bool swiftmmkv_store_set_int32(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, int32_t value,
  swiftmmkv_expiry expiry);
bool swiftmmkv_store_set_uint32(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, uint32_t value,
  swiftmmkv_expiry expiry);
bool swiftmmkv_store_set_int64(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, int64_t value,
  swiftmmkv_expiry expiry);
bool swiftmmkv_store_set_uint64(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, uint64_t value,
  swiftmmkv_expiry expiry);
bool swiftmmkv_store_set_float(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, float value,
  swiftmmkv_expiry expiry);
bool swiftmmkv_store_set_double(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, double value,
  swiftmmkv_expiry expiry);
bool swiftmmkv_store_set_string(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, const char *_Nonnull value,
  swiftmmkv_expiry expiry);
/// MMKV copies the bytes before this returns. `bytes` may be NULL when `count` is zero.
bool swiftmmkv_store_set_bytes(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, const void *_Nullable bytes,
  size_t count, swiftmmkv_expiry expiry);
/// Stores the strings of a packed list of `size` bytes. `values` may be NULL when `size` is
/// zero, which stores an empty list.
bool swiftmmkv_store_set_strings(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, const char *_Nullable values,
  size_t size, swiftmmkv_expiry expiry);

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
/// The length in bytes of the string or bytes stored under `key`, without reading them. It is
/// what `swiftmmkv_store_get_string` and `swiftmmkv_store_get_bytes` report.
bool swiftmmkv_store_value_size(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, size_t *_Nonnull out_size);
/// Copies the string's UTF-8 and a terminator into `buffer`, as "Buffers" describes.
///
/// `out_length` receives the string's length in bytes without its terminator, so the string
/// was copied if the length is less than `capacity`. That length is more than `strlen` reports
/// when another writer stored a string that contains U+0000.
bool swiftmmkv_store_get_string(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, char *_Nullable buffer,
  size_t capacity, size_t *_Nonnull out_length);
/// Copies the bytes into `buffer`, as "Buffers" describes. They were copied if `out_count` is
/// no more than `capacity`. A string is read as its UTF-8, without a terminator.
bool swiftmmkv_store_get_bytes(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, void *_Nullable buffer,
  size_t capacity, size_t *_Nonnull out_count);
/// Copies the strings into `buffer` as a packed list, as "Buffers" describes. `out_size`
/// receives the list's size in bytes and `out_count` the number of strings in it. The list was
/// copied if its size is no more than `capacity`.
bool swiftmmkv_store_get_strings(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull key, char *_Nullable buffer,
  size_t capacity, size_t *_Nonnull out_size, size_t *_Nonnull out_count);

// MARK: - Keys

bool swiftmmkv_store_contains(swiftmmkv_store *_Nonnull store, const char *_Nonnull key);
/// The number of keys in the store.
size_t swiftmmkv_store_count(swiftmmkv_store *_Nonnull store);
/// Copies every key in the store into `buffer` as a packed list, in no particular order, as
/// "Buffers" describes. `out_size` receives the list's size in bytes and `out_count` the
/// number of keys in it. The list was copied if its size is no more than `capacity`.
void swiftmmkv_store_keys(
  swiftmmkv_store *_Nonnull store, char *_Nullable buffer, size_t capacity,
  size_t *_Nonnull out_size, size_t *_Nonnull out_count);
/// Copies `prefix`, if it has a value, and every key under it into `buffer`, as
/// `swiftmmkv_store_keys` does. These are the keys `swiftmmkv_store_remove_under` removes.
///
/// A key is under `prefix` when it starts with `prefix` and then `separator`, so
/// "settings.theme" is under "settings" with the separator ".", and "settingsTheme" is not. An
/// empty `prefix` has every key under it. A NULL `separator` is ".". The keys are whole keys,
/// with the prefix. This reads every key in the store.
void swiftmmkv_store_keys_under(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull prefix,
  const char *_Nullable separator, char *_Nullable buffer, size_t capacity,
  size_t *_Nonnull out_size, size_t *_Nonnull out_count);

// MARK: - Removal

/// Removes `key` and its value, and returns whether the store accepted the removal. MMKV also
/// reports success for a key that had no value.
bool swiftmmkv_store_remove(swiftmmkv_store *_Nonnull store, const char *_Nonnull key);
/// Removes the values of the keys in a packed list of `size` bytes, all at once. `keys` may be
/// NULL when `size` is zero. What `swiftmmkv_store_keys` wrote can be passed straight back.
void swiftmmkv_store_remove_many(
  swiftmmkv_store *_Nonnull store, const char *_Nullable keys, size_t size);
/// Removes `prefix` and every key under it, all at once, as `swiftmmkv_store_keys_under`
/// describes. A NULL `separator` is ".".
void swiftmmkv_store_remove_under(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull prefix,
  const char *_Nullable separator);
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
/// The value of a key was set or removed through this package, in this process.
#define SWIFTMMKV_CHANGE_KEY 0
/// Another process, or another copy of MMKV in this process, changed the store. Which keys
/// changed is not known.
#define SWIFTMMKV_CHANGE_EXTERNAL 1

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
/// Calls `on_change` whenever `prefix` or a key under it may have changed, until the
/// subscription is cancelled, which makes a value spread over several keys observable as one.
/// That is whenever such a key is set or removed, and on every external change.
/// `swiftmmkv_store_keys_under` says which keys are under `prefix`, and a NULL `separator` is
/// ".".
swiftmmkv_subscription *_Nonnull swiftmmkv_store_subscribe_under(
  swiftmmkv_store *_Nonnull store, const char *_Nonnull prefix,
  const char *_Nullable separator, void *_Nullable context,
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

// MARK: - Closing
//
// An open store cannot be removed, and its directory cannot restore over it. Closing a store
// releases its memory and its files for good, so that both can be done.
//
// A closed store stays closed: reads find nothing, writes and removals do nothing, and
// functions that return a status return `SWIFTMMKV_STORE_IS_CLOSED`. Its handle is still
// valid, and is still released with `swiftmmkv_store_destroy`. To use the store again, open it
// again, which reads its files as they then are.

bool swiftmmkv_store_is_closed(swiftmmkv_store *_Nonnull store);
/// Turns new operations away, waits for those under way, and returns once the store's files
/// are closed. Closing twice does nothing more.
///
/// Every handle that was opened over the same files is closed with this one, since they share
/// the open files. Listeners are told once more, of an external change, because every value
/// now reads as missing, and are told nothing after that, so each listener's context is
/// released then. Their subscriptions are still released with `swiftmmkv_subscription_cancel`.
///
/// Do not call this from inside `swiftmmkv_store_with_exclusive_lock`.
void swiftmmkv_store_close(swiftmmkv_store *_Nonnull store);

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
/// Whether the store's file records when each key expires, which it does from the first write
/// that expires until `swiftmmkv_store_disable_expiry`. A suspended store answers false.
bool swiftmmkv_store_is_expiry_enabled(swiftmmkv_store *_Nonnull store);
/// Rewrites the store's file in the format it had before its first expiring write, which is
/// the format react-native-mmkv reads.
///
/// Keys that have expired are dropped, and every other key is kept until it is removed,
/// whatever expiry it was written with. The next write that expires switches the file back.
swiftmmkv_status swiftmmkv_store_disable_expiry(swiftmmkv_store *_Nonnull store);
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
/// Fails with `SWIFTMMKV_STORE_IS_OPEN` if the store is open in this process, which it is
/// from `swiftmmkv_store_open` until `swiftmmkv_store_close`, even if its handles have since
/// been destroyed.
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
/// What MMKV is doing, such as loading a file or growing one.
#define SWIFTMMKV_LOG_INFO 1
/// Something unexpected that MMKV carried on from.
#define SWIFTMMKV_LOG_WARNING 2
/// A failure, such as a file that cannot be opened or that fails its integrity check.
#define SWIFTMMKV_LOG_ERROR 3
/// As a minimum level, logs nothing. No message has this level.
#define SWIFTMMKV_LOG_NONE 4

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
/// The file's contents do not match their checksum.
#define SWIFTMMKV_INTEGRITY_FAILURE_CHECKSUM 0
/// The file is not as long as it records itself to be.
#define SWIFTMMKV_INTEGRITY_FAILURE_FILE_LENGTH 1

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
