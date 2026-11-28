"""The raw layer: `swiftmmkv.h`, name for name.

Every function, constant and type of the header is here under the header's own name, and the
header documents each of them. `tests/test_raw_parity.py` fails when the two disagree. Nothing
here is public: the rest of the package is what users write against.

Conventions, which are the header's:

- A string is passed as NUL-terminated UTF-8, which is `bytes` for a `c_char_p`. `c_string`
  makes one from a `str`, and refuses a string that contains U+0000.
- A handle is a pointer to an opaque type, which is a `c_void_p`: an `int`, or `None` for NULL.
- A value of no fixed size is copied into a buffer the caller owns. `read_sized` and
  `read_packed` make the read, and make it again with the size that was reported.
- A list of strings is packed: `pack_strings` and `unpack_strings`.
"""

from __future__ import annotations

import ctypes
import os
import sys
from collections.abc import Callable, Iterable
from ctypes import (
    CFUNCTYPE,
    POINTER,
    c_bool,
    c_char_p,
    c_double,
    c_float,
    c_int32,
    c_int64,
    c_size_t,
    c_uint32,
    c_uint64,
    c_void_p,
)
from pathlib import Path
from typing import Any

# MARK: - Version

SWIFTMMKV_ABI_VERSION = 1

# MARK: - Status

swiftmmkv_status = c_int32
SWIFTMMKV_OK = 0
SWIFTMMKV_OPEN_FAILED = 1
SWIFTMMKV_INVALID_ENCRYPTION_KEY = 2
SWIFTMMKV_REKEY_FAILED = 3
SWIFTMMKV_STORE_IS_OPEN = 4
SWIFTMMKV_STORES_ARE_OPEN = 5
SWIFTMMKV_DIRECTORY_UNREADABLE = 6
SWIFTMMKV_STORE_IS_SUSPENDED = 7
SWIFTMMKV_INVALID_ARGUMENT = 8
SWIFTMMKV_BACKUP_FAILED = 9
SWIFTMMKV_RESTORE_FAILED = 10
SWIFTMMKV_STORES_NOT_BACKED_UP = 11
SWIFTMMKV_STORES_NOT_RESTORED = 12
SWIFTMMKV_BACKUP_INVALID = 13
SWIFTMMKV_BACKUP_IS_STORE_DIRECTORY = 14
SWIFTMMKV_WRITE_FAILED = 15
SWIFTMMKV_APP_GROUP_CONTAINER_UNAVAILABLE = 16
SWIFTMMKV_DISABLE_EXPIRY_FAILED = 17
SWIFTMMKV_UNKNOWN_ERROR = 18
SWIFTMMKV_STORE_IS_CLOSED = 19

# MARK: - Expiry

swiftmmkv_expiry = c_uint64
SWIFTMMKV_EXPIRY_DEFAULT = 0

# MARK: - Configuration

swiftmmkv_mode = c_int32
SWIFTMMKV_MODE_SINGLE_PROCESS = 0
SWIFTMMKV_MODE_MULTI_PROCESS = 1

swiftmmkv_encryption = c_int32
SWIFTMMKV_ENCRYPTION_NONE = 0
SWIFTMMKV_ENCRYPTION_AES128 = 1
SWIFTMMKV_ENCRYPTION_AES256 = 2

swiftmmkv_recovery = c_int32
SWIFTMMKV_RECOVERY_DISCARD = 0
SWIFTMMKV_RECOVERY_RECOVER = 1

swiftmmkv_file_protection = c_int32
SWIFTMMKV_FILE_PROTECTION_COMPLETE_UNTIL_FIRST_USER_AUTHENTICATION = 0
SWIFTMMKV_FILE_PROTECTION_NONE = 1
SWIFTMMKV_FILE_PROTECTION_UNCHANGED = 2

# MARK: - Logging

swiftmmkv_log_level = c_int32
SWIFTMMKV_LOG_INFO = 1
SWIFTMMKV_LOG_WARNING = 2
SWIFTMMKV_LOG_ERROR = 3
SWIFTMMKV_LOG_NONE = 4

# MARK: - Integrity Failures

swiftmmkv_integrity_failure_kind = c_int32
SWIFTMMKV_INTEGRITY_FAILURE_CHECKSUM = 0
SWIFTMMKV_INTEGRITY_FAILURE_FILE_LENGTH = 1

# MARK: - Handles

# The header only ever passes these by pointer, and that pointer is what each name stands for
# here. Nothing can be read through one.
swiftmmkv_configuration = c_void_p
swiftmmkv_store = c_void_p
swiftmmkv_subscription = c_void_p

# MARK: - Changes


class swiftmmkv_change_batch(ctypes.Structure):  # noqa: N801
    """What one operation changed. Only read through the pointer a callback is given."""

    _fields_ = [
        ("keys", POINTER(c_char_p)),
        ("key_count", c_size_t),
        ("is_external", c_bool),
    ]


# MARK: - Callbacks

swiftmmkv_locked_callback = CFUNCTYPE(None, c_void_p, swiftmmkv_store)
swiftmmkv_change_callback = CFUNCTYPE(None, c_void_p, POINTER(swiftmmkv_change_batch))
swiftmmkv_context_release = CFUNCTYPE(None, c_void_p)
swiftmmkv_log_callback = CFUNCTYPE(
    None, c_void_p, swiftmmkv_log_level, c_char_p, c_char_p, c_char_p, c_int32
)
swiftmmkv_integrity_failure_callback = CFUNCTYPE(
    None, c_void_p, c_char_p, swiftmmkv_integrity_failure_kind
)

# MARK: - The library


def _library_path() -> str:
    """Where the library is: `SWIFTMMKV_LIBRARY` if it is set, and inside the package if not."""
    override = os.environ.get("SWIFTMMKV_LIBRARY")
    if override:
        return override
    name = "libswiftmmkv.dylib" if sys.platform == "darwin" else "libswiftmmkv.so"
    path = Path(__file__).parent / "_lib" / name
    if not path.is_file():
        raise ImportError(
            f"swiftmmkv has no library at {path}. In a checkout, build it with "
            "`python hatch_build.py`, or set SWIFTMMKV_LIBRARY to the path of one."
        )
    return str(path)


try:
    # `CDLL` gives up the interpreter lock for the length of each call, and a callback takes
    # it back before it runs.
    lib = ctypes.CDLL(_library_path())
except OSError as error:
    raise ImportError(f"swiftmmkv could not load its library: {error}") from error


def _bind(name: str, restype: Any, *argtypes: Any) -> Any:
    try:
        function = getattr(lib, name)
    except AttributeError as error:
        raise ImportError(
            f"The swiftmmkv library has no function {name}, so it is older than this package."
        ) from error
    function.restype = restype
    function.argtypes = argtypes
    return function


_size_out = POINTER(c_size_t)
_bool_out = POINTER(c_bool)

# MARK: - Version

swiftmmkv_abi_version = _bind("swiftmmkv_abi_version", c_uint32)

# MARK: - Status

swiftmmkv_status_message = _bind("swiftmmkv_status_message", c_char_p, swiftmmkv_status)

# MARK: - Expiry

swiftmmkv_expiry_never = _bind("swiftmmkv_expiry_never", swiftmmkv_expiry)
swiftmmkv_expiry_after = _bind("swiftmmkv_expiry_after", swiftmmkv_expiry, c_double)
swiftmmkv_expiry_at = _bind("swiftmmkv_expiry_at", swiftmmkv_expiry, c_double)

# MARK: - Configuration

swiftmmkv_configuration_create = _bind(
    "swiftmmkv_configuration_create", swiftmmkv_configuration, c_char_p, swiftmmkv_mode
)
swiftmmkv_configuration_create_temporary = _bind(
    "swiftmmkv_configuration_create_temporary", swiftmmkv_configuration
)
swiftmmkv_configuration_destroy = _bind(
    "swiftmmkv_configuration_destroy", None, swiftmmkv_configuration
)
swiftmmkv_configuration_set_id = _bind(
    "swiftmmkv_configuration_set_id", None, swiftmmkv_configuration, c_char_p
)
swiftmmkv_configuration_set_directory = _bind(
    "swiftmmkv_configuration_set_directory", None, swiftmmkv_configuration, c_char_p
)
swiftmmkv_configuration_directory = _bind(
    "swiftmmkv_configuration_directory",
    None,
    swiftmmkv_configuration,
    c_void_p,
    c_size_t,
    _size_out,
)
swiftmmkv_configuration_set_mode = _bind(
    "swiftmmkv_configuration_set_mode", None, swiftmmkv_configuration, swiftmmkv_mode
)
swiftmmkv_configuration_set_read_only = _bind(
    "swiftmmkv_configuration_set_read_only", None, swiftmmkv_configuration, c_bool
)
swiftmmkv_configuration_set_encryption = _bind(
    "swiftmmkv_configuration_set_encryption",
    None,
    swiftmmkv_configuration,
    swiftmmkv_encryption,
    c_void_p,
    c_size_t,
)
swiftmmkv_configuration_set_expected_capacity = _bind(
    "swiftmmkv_configuration_set_expected_capacity", None, swiftmmkv_configuration, c_size_t
)
swiftmmkv_configuration_set_recovery = _bind(
    "swiftmmkv_configuration_set_recovery", None, swiftmmkv_configuration, swiftmmkv_recovery
)
swiftmmkv_configuration_set_file_protection = _bind(
    "swiftmmkv_configuration_set_file_protection",
    None,
    swiftmmkv_configuration,
    swiftmmkv_file_protection,
)
swiftmmkv_configuration_set_compare_before_set = _bind(
    "swiftmmkv_configuration_set_compare_before_set", None, swiftmmkv_configuration, c_bool
)
swiftmmkv_configuration_set_item_size_limit = _bind(
    "swiftmmkv_configuration_set_item_size_limit", None, swiftmmkv_configuration, c_size_t
)
swiftmmkv_configuration_set_default_expiry = _bind(
    "swiftmmkv_configuration_set_default_expiry",
    None,
    swiftmmkv_configuration,
    swiftmmkv_expiry,
)

# MARK: - Stores

swiftmmkv_store_open = _bind(
    "swiftmmkv_store_open", swiftmmkv_status, swiftmmkv_configuration, POINTER(swiftmmkv_store)
)
swiftmmkv_store_destroy = _bind("swiftmmkv_store_destroy", None, swiftmmkv_store)

# MARK: - Writes

swiftmmkv_store_set_bool = _bind(
    "swiftmmkv_store_set_bool", c_bool, swiftmmkv_store, c_char_p, c_bool, swiftmmkv_expiry
)
swiftmmkv_store_set_int32 = _bind(
    "swiftmmkv_store_set_int32", c_bool, swiftmmkv_store, c_char_p, c_int32, swiftmmkv_expiry
)
swiftmmkv_store_set_uint32 = _bind(
    "swiftmmkv_store_set_uint32", c_bool, swiftmmkv_store, c_char_p, c_uint32, swiftmmkv_expiry
)
swiftmmkv_store_set_int64 = _bind(
    "swiftmmkv_store_set_int64", c_bool, swiftmmkv_store, c_char_p, c_int64, swiftmmkv_expiry
)
swiftmmkv_store_set_uint64 = _bind(
    "swiftmmkv_store_set_uint64", c_bool, swiftmmkv_store, c_char_p, c_uint64, swiftmmkv_expiry
)
swiftmmkv_store_set_float = _bind(
    "swiftmmkv_store_set_float", c_bool, swiftmmkv_store, c_char_p, c_float, swiftmmkv_expiry
)
swiftmmkv_store_set_double = _bind(
    "swiftmmkv_store_set_double", c_bool, swiftmmkv_store, c_char_p, c_double, swiftmmkv_expiry
)
swiftmmkv_store_set_string = _bind(
    "swiftmmkv_store_set_string", c_bool, swiftmmkv_store, c_char_p, c_char_p, swiftmmkv_expiry
)
swiftmmkv_store_set_bytes = _bind(
    "swiftmmkv_store_set_bytes",
    c_bool,
    swiftmmkv_store,
    c_char_p,
    c_void_p,
    c_size_t,
    swiftmmkv_expiry,
)
swiftmmkv_store_set_strings = _bind(
    "swiftmmkv_store_set_strings",
    c_bool,
    swiftmmkv_store,
    c_char_p,
    c_char_p,
    c_size_t,
    swiftmmkv_expiry,
)

# MARK: - Reads

swiftmmkv_store_get_bool = _bind(
    "swiftmmkv_store_get_bool", c_bool, swiftmmkv_store, c_char_p, _bool_out
)
swiftmmkv_store_get_int32 = _bind(
    "swiftmmkv_store_get_int32", c_bool, swiftmmkv_store, c_char_p, POINTER(c_int32)
)
swiftmmkv_store_get_uint32 = _bind(
    "swiftmmkv_store_get_uint32", c_bool, swiftmmkv_store, c_char_p, POINTER(c_uint32)
)
swiftmmkv_store_get_int64 = _bind(
    "swiftmmkv_store_get_int64", c_bool, swiftmmkv_store, c_char_p, POINTER(c_int64)
)
swiftmmkv_store_get_uint64 = _bind(
    "swiftmmkv_store_get_uint64", c_bool, swiftmmkv_store, c_char_p, POINTER(c_uint64)
)
swiftmmkv_store_get_float = _bind(
    "swiftmmkv_store_get_float", c_bool, swiftmmkv_store, c_char_p, POINTER(c_float)
)
swiftmmkv_store_get_double = _bind(
    "swiftmmkv_store_get_double", c_bool, swiftmmkv_store, c_char_p, POINTER(c_double)
)
swiftmmkv_store_value_size = _bind(
    "swiftmmkv_store_value_size", c_bool, swiftmmkv_store, c_char_p, _size_out
)
swiftmmkv_store_get_string = _bind(
    "swiftmmkv_store_get_string", c_bool, swiftmmkv_store, c_char_p, c_void_p, c_size_t, _size_out
)
swiftmmkv_store_get_bytes = _bind(
    "swiftmmkv_store_get_bytes", c_bool, swiftmmkv_store, c_char_p, c_void_p, c_size_t, _size_out
)
swiftmmkv_store_get_strings = _bind(
    "swiftmmkv_store_get_strings",
    c_bool,
    swiftmmkv_store,
    c_char_p,
    c_void_p,
    c_size_t,
    _size_out,
    _size_out,
)

# MARK: - Keys

swiftmmkv_store_contains = _bind("swiftmmkv_store_contains", c_bool, swiftmmkv_store, c_char_p)
swiftmmkv_store_count = _bind("swiftmmkv_store_count", c_size_t, swiftmmkv_store)
swiftmmkv_store_keys = _bind(
    "swiftmmkv_store_keys", None, swiftmmkv_store, c_void_p, c_size_t, _size_out, _size_out
)
swiftmmkv_store_keys_under = _bind(
    "swiftmmkv_store_keys_under",
    None,
    swiftmmkv_store,
    c_char_p,
    c_char_p,
    c_void_p,
    c_size_t,
    _size_out,
    _size_out,
)

# MARK: - Removal

swiftmmkv_store_remove = _bind("swiftmmkv_store_remove", c_bool, swiftmmkv_store, c_char_p)
swiftmmkv_store_remove_many = _bind(
    "swiftmmkv_store_remove_many", None, swiftmmkv_store, c_char_p, c_size_t
)
swiftmmkv_store_remove_under = _bind(
    "swiftmmkv_store_remove_under", None, swiftmmkv_store, c_char_p, c_char_p
)
swiftmmkv_store_remove_all = _bind("swiftmmkv_store_remove_all", None, swiftmmkv_store, c_bool)
swiftmmkv_store_import_all = _bind(
    "swiftmmkv_store_import_all", c_size_t, swiftmmkv_store, swiftmmkv_store
)

# MARK: - Exclusive Access

swiftmmkv_store_with_exclusive_lock = _bind(
    "swiftmmkv_store_with_exclusive_lock",
    None,
    swiftmmkv_store,
    c_void_p,
    swiftmmkv_locked_callback,
)
swiftmmkv_store_lock_exclusive = _bind("swiftmmkv_store_lock_exclusive", None, swiftmmkv_store)
swiftmmkv_store_unlock_exclusive = _bind(
    "swiftmmkv_store_unlock_exclusive", None, swiftmmkv_store
)

# MARK: - Changes

swiftmmkv_subscription_cancel = _bind(
    "swiftmmkv_subscription_cancel", None, swiftmmkv_subscription
)
swiftmmkv_store_subscribe = _bind(
    "swiftmmkv_store_subscribe",
    swiftmmkv_subscription,
    swiftmmkv_store,
    c_void_p,
    swiftmmkv_change_callback,
    swiftmmkv_context_release,
)
swiftmmkv_store_subscribe_key = _bind(
    "swiftmmkv_store_subscribe_key",
    swiftmmkv_subscription,
    swiftmmkv_store,
    c_char_p,
    c_void_p,
    swiftmmkv_change_callback,
    swiftmmkv_context_release,
)
swiftmmkv_store_subscribe_under = _bind(
    "swiftmmkv_store_subscribe_under",
    swiftmmkv_subscription,
    swiftmmkv_store,
    c_char_p,
    c_char_p,
    c_void_p,
    swiftmmkv_change_callback,
    swiftmmkv_context_release,
)
swiftmmkv_store_check_for_external_changes = _bind(
    "swiftmmkv_store_check_for_external_changes", None, swiftmmkv_store
)

# MARK: - Suspension

swiftmmkv_store_is_suspended = _bind("swiftmmkv_store_is_suspended", c_bool, swiftmmkv_store)
swiftmmkv_store_suspend = _bind("swiftmmkv_store_suspend", None, swiftmmkv_store)
swiftmmkv_store_resume = _bind("swiftmmkv_store_resume", None, swiftmmkv_store)

# MARK: - Closing

swiftmmkv_store_is_closed = _bind("swiftmmkv_store_is_closed", c_bool, swiftmmkv_store)
swiftmmkv_store_close = _bind("swiftmmkv_store_close", None, swiftmmkv_store)

# MARK: - Maintenance

swiftmmkv_store_byte_size = _bind("swiftmmkv_store_byte_size", c_size_t, swiftmmkv_store)
swiftmmkv_store_used_byte_size = _bind(
    "swiftmmkv_store_used_byte_size", c_size_t, swiftmmkv_store
)
swiftmmkv_store_trim = _bind("swiftmmkv_store_trim", None, swiftmmkv_store)
swiftmmkv_store_release_memory = _bind("swiftmmkv_store_release_memory", None, swiftmmkv_store)
swiftmmkv_store_sync = _bind("swiftmmkv_store_sync", None, swiftmmkv_store)
swiftmmkv_store_is_expiry_enabled = _bind(
    "swiftmmkv_store_is_expiry_enabled", c_bool, swiftmmkv_store
)
swiftmmkv_store_disable_expiry = _bind(
    "swiftmmkv_store_disable_expiry", swiftmmkv_status, swiftmmkv_store
)
swiftmmkv_store_rekey = _bind(
    "swiftmmkv_store_rekey",
    swiftmmkv_status,
    swiftmmkv_store,
    swiftmmkv_encryption,
    c_void_p,
    c_size_t,
)
swiftmmkv_store_back_up = _bind(
    "swiftmmkv_store_back_up", swiftmmkv_status, swiftmmkv_store, c_char_p
)
swiftmmkv_store_restore = _bind(
    "swiftmmkv_store_restore", swiftmmkv_status, swiftmmkv_store, c_char_p, _bool_out
)

# MARK: - Directories

swiftmmkv_directory_contains_store = _bind(
    "swiftmmkv_directory_contains_store", c_bool, c_char_p, c_char_p
)
swiftmmkv_directory_is_store_valid = _bind(
    "swiftmmkv_directory_is_store_valid", c_bool, c_char_p, c_char_p
)
swiftmmkv_directory_remove_store = _bind(
    "swiftmmkv_directory_remove_store", swiftmmkv_status, c_char_p, c_char_p, _bool_out
)
swiftmmkv_directory_remove_all_stores = _bind(
    "swiftmmkv_directory_remove_all_stores", swiftmmkv_status, c_char_p, _size_out
)
swiftmmkv_directory_back_up_store = _bind(
    "swiftmmkv_directory_back_up_store",
    swiftmmkv_status,
    c_char_p,
    c_char_p,
    c_char_p,
    _bool_out,
)
swiftmmkv_directory_back_up_all_stores = _bind(
    "swiftmmkv_directory_back_up_all_stores", swiftmmkv_status, c_char_p, c_char_p, _size_out
)
swiftmmkv_directory_restore_store = _bind(
    "swiftmmkv_directory_restore_store",
    swiftmmkv_status,
    c_char_p,
    c_char_p,
    c_char_p,
    _bool_out,
)
swiftmmkv_directory_restore_all_stores = _bind(
    "swiftmmkv_directory_restore_all_stores", swiftmmkv_status, c_char_p, c_char_p, _size_out
)

# MARK: - Logging

swiftmmkv_log_minimum_level = _bind("swiftmmkv_log_minimum_level", swiftmmkv_log_level)
swiftmmkv_log_set_minimum_level = _bind(
    "swiftmmkv_log_set_minimum_level", None, swiftmmkv_log_level
)
swiftmmkv_log_set_handler = _bind(
    "swiftmmkv_log_set_handler",
    None,
    c_void_p,
    swiftmmkv_log_callback,
    swiftmmkv_context_release,
)

# MARK: - Integrity Failures

swiftmmkv_subscribe_to_integrity_failures = _bind(
    "swiftmmkv_subscribe_to_integrity_failures",
    swiftmmkv_subscription,
    c_void_p,
    swiftmmkv_integrity_failure_callback,
    swiftmmkv_context_release,
)

# The header asks a binding to refuse to load against a library of another version.
if swiftmmkv_abi_version() != SWIFTMMKV_ABI_VERSION:
    raise ImportError(
        f"The swiftmmkv library has version {swiftmmkv_abi_version()} of its interface, and "
        f"this package was written for version {SWIFTMMKV_ABI_VERSION}."
    )

# MARK: - Conventions

#: The size of the buffer a read is first made with, which holds most values in one call.
FIRST_CAPACITY = 256


def c_string(text: str) -> bytes:
    """`text` as the header takes a string. The terminator is added by `ctypes`."""
    encoded = text.encode("utf-8")
    if b"\0" in encoded:
        raise ValueError(f"{text!r} contains U+0000, which a C string cannot hold.")
    return encoded


def read_sized(
    read: Callable[[Any, int, Any], bool], *, terminated: bool = False
) -> bytes | None:
    """Makes a read of no fixed size, as "Buffers" in the header describes.

    `read` is given a buffer, its capacity, and where to report the size of the value, and
    returns whether there is a value. Nothing is copied into a buffer that is too small, so
    the read is made again with the size that was reported. Another thread or process can
    change the value in between, so the size of every read is checked, and not only the first.

    `terminated` is for a string, which is copied with a terminator its size does not count.
    """
    size = c_size_t()
    capacity = FIRST_CAPACITY
    while True:
        buffer = ctypes.create_string_buffer(capacity)
        if not read(buffer, capacity, ctypes.byref(size)):
            return None
        needed = size.value + 1 if terminated else size.value
        if needed <= capacity:
            return ctypes.string_at(buffer, size.value)
        capacity = needed


def read_packed(read: Callable[[Any, int, Any, Any], bool]) -> list[str] | None:
    """Reads a packed list of strings, as `read_sized` reads a value.

    `read` is also given where to report the number of strings.
    """
    size = c_size_t()
    count = c_size_t()
    capacity = FIRST_CAPACITY
    while True:
        buffer = ctypes.create_string_buffer(capacity)
        if not read(buffer, capacity, ctypes.byref(size), ctypes.byref(count)):
            return None
        if size.value <= capacity:
            return unpack_strings(ctypes.string_at(buffer, size.value))
        capacity = size.value


def pack_strings(strings: Iterable[str]) -> bytes:
    """`strings` end to end, each followed by a NUL, which is how the header takes a list."""
    if isinstance(strings, str):
        raise TypeError("A list of strings was expected, and not one string.")
    packed = bytearray()
    for string in strings:
        if not isinstance(string, str):
            raise TypeError(f"A list of strings cannot hold {type(string).__name__!r}.")
        packed += c_string(string)
        packed.append(0)
    return bytes(packed)


def unpack_strings(packed: bytes) -> list[str]:
    """The strings of a packed list."""
    if not packed:
        return []
    # Each string ends with a NUL, so the split leaves an empty piece after the last.
    return [piece.decode("utf-8", "replace") for piece in packed.split(b"\0")[:-1]]
