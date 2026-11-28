"""The one error the package raises of its own, and the statuses it carries."""

from __future__ import annotations

import enum
from typing import Final

from . import _raw


class Status(enum.IntEnum):
    """Why an operation failed. The values are those of `swiftmmkv_status` in the C interface."""

    OK = _raw.SWIFTMMKV_OK
    #: The store could not be opened, for example because its identifier or its directory's
    #: path is empty.
    OPEN_FAILED = _raw.SWIFTMMKV_OPEN_FAILED
    #: The encryption key is empty or longer than its cipher allows.
    INVALID_ENCRYPTION_KEY = _raw.SWIFTMMKV_INVALID_ENCRYPTION_KEY
    #: The store could not be re-encrypted, for example because it is read-only.
    REKEY_FAILED = _raw.SWIFTMMKV_REKEY_FAILED
    #: The store is open in this process, so its files cannot be removed or replaced.
    STORE_IS_OPEN = _raw.SWIFTMMKV_STORE_IS_OPEN
    #: Some stores are open in this process, so they were left alone while the rest of their
    #: directory's stores were dealt with.
    STORES_ARE_OPEN = _raw.SWIFTMMKV_STORES_ARE_OPEN
    #: The directory exists but its contents cannot be listed.
    DIRECTORY_UNREADABLE = _raw.SWIFTMMKV_DIRECTORY_UNREADABLE
    #: The store is suspended, so it turned the operation away. Try again once it is resumed.
    STORE_IS_SUSPENDED = _raw.SWIFTMMKV_STORE_IS_SUSPENDED
    #: An argument is a value the library does not know, such as a mode that is not a `Mode`.
    INVALID_ARGUMENT = _raw.SWIFTMMKV_INVALID_ARGUMENT
    #: The store's files could not be copied into the backup directory.
    BACKUP_FAILED = _raw.SWIFTMMKV_BACKUP_FAILED
    #: The store could not be overwritten with its copy in the backup directory, for example
    #: because it is open as read-only.
    RESTORE_FAILED = _raw.SWIFTMMKV_RESTORE_FAILED
    #: Some stores could not be copied into the backup directory. The others were.
    STORES_NOT_BACKED_UP = _raw.SWIFTMMKV_STORES_NOT_BACKED_UP
    #: Some stores could not be overwritten with their copies in the backup directory. The
    #: others were.
    STORES_NOT_RESTORED = _raw.SWIFTMMKV_STORES_NOT_RESTORED
    #: The store's copy in the backup directory does not match its checksum, so nothing was
    #: restored from it.
    BACKUP_INVALID = _raw.SWIFTMMKV_BACKUP_INVALID
    #: The backup directory is the directory the stores are in.
    BACKUP_IS_STORE_DIRECTORY = _raw.SWIFTMMKV_BACKUP_IS_STORE_DIRECTORY
    #: The store did not accept a write.
    WRITE_FAILED = _raw.SWIFTMMKV_WRITE_FAILED
    #: The app group has no container this process can reach.
    APP_GROUP_CONTAINER_UNAVAILABLE = _raw.SWIFTMMKV_APP_GROUP_CONTAINER_UNAVAILABLE
    #: The store's file could not be rewritten without its expiries, for example because it is
    #: read-only.
    DISABLE_EXPIRY_FAILED = _raw.SWIFTMMKV_DISABLE_EXPIRY_FAILED
    #: The operation failed in a way the library has no status for.
    UNKNOWN_ERROR = _raw.SWIFTMMKV_UNKNOWN_ERROR
    #: The store is closed, so it turns every operation away. Open the store again to use it.
    STORE_IS_CLOSED = _raw.SWIFTMMKV_STORE_IS_CLOSED


class MMKVError(Exception):
    """An operation that reports a status reported one other than `Status.OK`.

    Tell errors apart by `status`::

        try:
            directory.remove_store("session")
        except MMKVError as error:
            if error.status is not Status.STORE_IS_OPEN:
                raise

    A later version of the library can report a status this version has no name for. That
    one is `Status.UNKNOWN_ERROR` here, and `code` still holds the number it reported.
    """

    #: Why the operation failed.
    status: Final[Status]
    #: The number the library reported, which is `status` unless this version does not know it.
    code: Final[int]
    #: A description of `status` in English.
    message: Final[str]

    def __init__(self, code: int) -> None:
        self.status = Status(code) if code in Status else Status.UNKNOWN_ERROR
        self.code = code
        self.message = _raw.swiftmmkv_status_message(code).decode("utf-8")
        super().__init__(self.message)

    def __reduce__(self) -> tuple[type[MMKVError], tuple[int]]:
        return (type(self), (self.code,))


def check(status: int) -> None:
    """Raises the error of `status`, unless it is `Status.OK`."""
    if status != _raw.SWIFTMMKV_OK:
        raise MMKVError(status)
