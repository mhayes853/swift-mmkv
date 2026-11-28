"""A directory of stores, and what can be done to its stores without opening them."""

from __future__ import annotations

import os
from ctypes import byref, c_bool, c_size_t
from typing import TYPE_CHECKING, Any, Self, final

from . import _raw
from ._configuration import (
    Configuration,
    Encryption,
    Expiry,
    ExpiryLike,
    FileProtection,
    Mode,
    Recovery,
    StoreID,
    StrPath,
)
from ._errors import check

if TYPE_CHECKING:
    from ._store import Store


def _c_path(path: StrPath) -> bytes:
    return _raw.c_string(os.fspath(path))


@final
class Directory(os.PathLike[str]):
    """A directory that holds the files of stores.

    Its methods work on the stores in it without opening them::

        directory = Directory("/var/lib/app/mmkv")
        directory.contains_store("session")   # False until the store is first opened
        directory.remove_store("session")

    A directory is a path and nothing more: making one touches no file, and two are equal
    when their paths are. It can be passed wherever a path is taken.

    A store that is open in this process cannot be removed, and a backup cannot be restored
    over it. A store is open from `swiftmmkv.open` until `Store.close`, even if every
    `Store` object over it has since been let go of.
    """

    __slots__ = ("_c_path", "_path")

    def __init__(self, path: StrPath, /) -> None:
        self._path = os.fspath(path)
        if not isinstance(self._path, str):
            raise TypeError("A directory's path is a str, or a path of one.")
        self._c_path = _raw.c_string(self._path)

    @classmethod
    def temporary(cls) -> Self:
        """A new directory inside the system's temporary directory, for stores that do not
        need to last. Every call names a different one."""
        return cls(Configuration.temporary().directory)

    @property
    def path(self) -> str:
        """The directory's path."""
        return self._path

    def __fspath__(self) -> str:
        return self._path

    def open(
        self,
        *,
        mode: Mode,
        id: StoreID | str = StoreID.DEFAULT,
        read_only: bool = False,
        encryption: Encryption | None = None,
        expected_capacity: int = 0,
        recovery: Recovery = Recovery.DISCARD,
        compare_before_set: bool = False,
        item_size_limit: int | None = None,
        file_protection: FileProtection = FileProtection.COMPLETE_UNTIL_FIRST_USER_AUTHENTICATION,
        default_expiry: ExpiryLike = Expiry.NEVER,
    ) -> Store:
        """Opens a store in this directory, as `swiftmmkv.open` does."""
        from ._store import open

        return open(
            self._path,
            mode=mode,
            id=id,
            read_only=read_only,
            encryption=encryption,
            expected_capacity=expected_capacity,
            recovery=recovery,
            compare_before_set=compare_before_set,
            item_size_limit=item_size_limit,
            file_protection=file_protection,
            default_expiry=default_expiry,
        )

    def contains_store(self, id: StoreID | str = StoreID.DEFAULT, /) -> bool:
        """Whether the directory holds a store with this identifier, which it does once the
        store has been opened."""
        contains: bool = _raw.swiftmmkv_directory_contains_store(self._c_path, _raw.c_string(id))
        return contains

    def is_store_valid(self, id: StoreID | str = StoreID.DEFAULT, /) -> bool:
        """Whether the store with this identifier has files whose contents match their
        checksum."""
        valid: bool = _raw.swiftmmkv_directory_is_store_valid(self._c_path, _raw.c_string(id))
        return valid

    def remove_store(self, id: StoreID | str = StoreID.DEFAULT, /) -> bool:
        """Deletes a store's files, and returns whether there were any.

        Raises `MMKVError` with `Status.STORE_IS_OPEN` if the store is open in this
        process. Close it first, or empty it with `Store.clear`.
        """
        removed = c_bool(False)
        check(
            _raw.swiftmmkv_directory_remove_store(self._c_path, _raw.c_string(id), byref(removed))
        )
        return removed.value

    def remove_all_stores(self) -> int:
        """Deletes the files of every store in the directory, and returns the number
        removed.

        Stores that are open in this process are left alone, and reported with an
        `MMKVError` with `Status.STORES_ARE_OPEN` once every other store has been removed.
        """
        count = c_size_t(0)
        check(_raw.swiftmmkv_directory_remove_all_stores(self._c_path, byref(count)))
        return count.value

    def back_up_store(self, id: StoreID | str, /, to: StrPath) -> bool:
        """Copies a store's files into the directory `to`, and returns whether there was a
        store to back up. Raises `MMKVError` if the files cannot be copied."""
        backed_up = c_bool(False)
        check(
            _raw.swiftmmkv_directory_back_up_store(
                self._c_path, _raw.c_string(id), _c_path(to), byref(backed_up)
            )
        )
        return backed_up.value

    def back_up_all_stores(self, to: StrPath, /) -> int:
        """Copies every store in the directory into the directory `to`, and returns the
        number backed up. Raises `MMKVError` with `Status.STORES_NOT_BACKED_UP` if some
        could not be, after the others were."""
        count = c_size_t(0)
        check(_raw.swiftmmkv_directory_back_up_all_stores(self._c_path, _c_path(to), byref(count)))
        return count.value

    def restore_store(self, id: StoreID | str, /, backup: StrPath) -> bool:
        """Overwrites a store with its copy in the directory `backup`, and returns whether
        `backup` held one. Raises `MMKVError` if the store cannot be overwritten, or with
        `Status.BACKUP_INVALID` if the copy does not match its checksum."""
        restored = c_bool(False)
        check(
            _raw.swiftmmkv_directory_restore_store(
                self._c_path, _raw.c_string(id), _c_path(backup), byref(restored)
            )
        )
        return restored.value

    def restore_all_stores(self, backup: StrPath, /) -> int:
        """Overwrites the stores in the directory with their copies in the directory
        `backup`, and returns the number restored. Raises `MMKVError` with
        `Status.STORES_NOT_RESTORED` if some could not be, after the others were."""
        count = c_size_t(0)
        check(
            _raw.swiftmmkv_directory_restore_all_stores(self._c_path, _c_path(backup), byref(count))
        )
        return count.value

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Directory):
            return NotImplemented
        return self._path == other._path

    def __hash__(self) -> int:
        return hash(self._path)

    def __repr__(self) -> str:
        return f"Directory({self._path!r})"

    def __reduce__(self) -> tuple[Any, ...]:
        return (Directory, (self._path,))
