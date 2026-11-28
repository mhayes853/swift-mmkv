"""The store, and the functions that open one."""

from __future__ import annotations

import builtins
import os
import threading
import weakref
from collections.abc import AsyncIterator, Buffer, Callable, Iterable, Iterator, Mapping, Sequence
from contextlib import AbstractContextManager
from ctypes import byref, c_bool, c_size_t, c_void_p
from typing import Any, Self, final, overload

from . import _changes, _raw
from ._changes import ChangeBatch, Subscription, name_of
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
    expiry_bits,
    make_configuration_handle,
)
from ._converters import Reader, TypeSpec, Writer, converter_for_value, converter_of
from ._directory import Directory
from ._errors import check
from ._keys import MISSING, DefaultedKey, Key

#: The values a write stores without being told their type.
type Plain = bool | int | float | str | Buffer | Sequence[str]

# MARK: - Exclusive access, by thread
#
# The header forbids closing or suspending a store from inside its exclusive lock. The lock
# belongs to the store's files and not to a handle, so what a thread holds is counted by
# files, for every `Store` over them.

_thread = threading.local()


def _held(files: tuple[str, str]) -> int:
    """How many times the calling thread holds the exclusive lock of `files`."""
    depths: dict[tuple[str, str], int] | None = getattr(_thread, "depths", None)
    return 0 if depths is None else depths.get(files, 0)


def _hold(files: tuple[str, str], change: int) -> None:
    depths: dict[tuple[str, str], int] | None = getattr(_thread, "depths", None)
    if depths is None:
        depths = _thread.depths = {}
    depth = depths.get(files, 0) + change
    if depth > 0:
        depths[files] = depth
    else:
        depths.pop(files, None)


@final
class _Locked:
    """The context manager `Store.locked` returns."""

    __slots__ = ("_store", "_threads")

    def __init__(self, store: Store) -> None:
        self._store = store
        #: The thread of each time this was entered and not yet left.
        self._threads: list[int] = []

    def __enter__(self) -> None:
        store = self._store
        _raw.swiftmmkv_store_lock_exclusive(store._handle)
        _hold(store._files, 1)
        self._threads.append(threading.get_ident())

    def __exit__(self, *exc: object) -> None:
        store = self._store
        if not self._threads or self._threads[-1] != threading.get_ident():
            raise RuntimeError(
                "A store's exclusive lock must be given up on the thread that took it."
            )
        self._threads.pop()
        _hold(store._files, -1)
        # Listeners are told from inside this call, once the thread holds the lock no more.
        _raw.swiftmmkv_store_unlock_exclusive(store._handle)


@final
class Store:
    """An open store: keys and their values, in a pair of memory-mapped files.

    `swiftmmkv.open` makes one::

        with swiftmmkv.open("/var/lib/app/mmkv", mode=Mode.SINGLE_PROCESS) as store:
            store.set("username", "blob")
            store.get("username", str)

    **Types.** The files record no types, so a value is read by naming the type it was
    written with: a type such as `str`, a converter such as `swiftmmkv.int32`, or a `Key`.
    A read of a key that has no value is `None`, which no stored value is.

    **Threads.** A store can be used from any thread at once, and so can every other object
    of this package. That holds under free-threaded Python too. The interpreter lock is
    given up for the length of each call into the library.

    **Processes.** A store that more than one process has open, such as one shared by the
    workers of `multiprocessing`, must be opened in `Mode.MULTI_PROCESS` by all of them. A
    child made by forking inherits its parent's stores, which makes two processes of one
    single-process store: open the store in the child instead.

    **Closing.** `close` releases the store's memory and its files, and `with` closes on
    the way out. A closed store stays usable: reads find nothing and writes do nothing,
    and nothing raises for being closed except what reports a status. Closing closes every
    `Store` over the same files in this process. Letting go of a store without closing it
    frees its handle and leaves the files open, which is what keeps other `Store` objects
    over them working.

    **Collections.** `len(store)`, `key in store` and `for key in store` count, test and
    list the keys. A subscript takes a typed key only, since a string cannot say what was
    stored under it: `store[VOLUME]`, and `store.get("volume", float)`.
    """

    __slots__ = ("__weakref__", "_configuration", "_files", "_handle")

    _handle: int
    _configuration: Configuration
    _files: tuple[str, str]

    def __init__(self) -> None:
        raise TypeError("A Store is made with swiftmmkv.open, and not by calling its class.")

    @classmethod
    def _make(cls, configuration: Configuration, handle: int) -> Store:
        self = object.__new__(cls)
        self._handle = handle
        self._configuration = configuration
        self._files = (os.path.realpath(configuration.directory), str(configuration.id))
        # Freeing the handle does not close the store: see `close`.
        weakref.finalize(self, _raw.swiftmmkv_store_destroy, handle)
        return self

    @property
    def configuration(self) -> Configuration:
        """What the store was opened with."""
        return self._configuration

    @property
    def directory(self) -> Directory:
        """The directory that holds the store's files."""
        return Directory(self._configuration.directory)

    @property
    def id(self) -> StoreID:
        """The store's identifier, which names its files inside its directory."""
        return StoreID(self._configuration.id)

    # MARK: - Lifetime

    def close(self) -> None:
        """Releases the store's memory and its files, for good.

        It turns new operations away, waits for those other threads have under way, and
        returns once the files are closed. Closing twice does nothing more. Afterwards
        reads find nothing, writes and removals do nothing, and what reports a status
        raises an `MMKVError` with `Status.STORE_IS_CLOSED`. To use the store again, open it
        again, which reads its files as they then are.

        An open store cannot be removed, and its directory cannot restore over it, which is
        what closing is for.

        Every `Store` over the same files in this process is closed with this one. Their
        listeners are told once more, of an external change, because every value now reads
        as `None`, and are told nothing after that.

        Raises `RuntimeError` inside a `locked` block of the store, which closing would
        have to wait for.
        """
        self._refuse_inside_lock("closed")
        _raw.swiftmmkv_store_close(self._handle)
        _changes.free_released()

    @property
    def closed(self) -> bool:
        """Whether the store has been closed, through this `Store` or another over its
        files."""
        closed: bool = _raw.swiftmmkv_store_is_closed(self._handle)
        return closed

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def _refuse_inside_lock(self, what: str) -> None:
        if _held(self._files):
            raise RuntimeError(
                f"A store cannot be {what} inside its own exclusive lock. Leave the "
                "`with store.locked():` block first."
            )

    # MARK: - Writes

    @overload
    def set[T](self, key: Key[T], value: T, /, *, expiry: ExpiryLike | None = None) -> bool: ...
    @overload
    def set(self, key: str, value: Plain, /, *, expiry: ExpiryLike | None = None) -> bool: ...
    @overload
    def set[T](
        self, key: str, value: T, type: TypeSpec[T], /, *, expiry: ExpiryLike | None = None
    ) -> bool: ...
    def set(
        self,
        key: Any,
        value: Any,
        type: Any = MISSING,
        /,
        *,
        expiry: ExpiryLike | None = None,
    ) -> bool:
        """Stores `value` under `key`, and returns whether the store took it.

        ::

            store.set("username", "blob")
            store.set("retries", 3, swiftmmkv.int32)
            store.set(VOLUME, 0.8)
            store.set("otp", "123456", expiry=timedelta(seconds=30))

        A typed key says how its value is stored. For a string key, `type` says so: a type
        or a converter. Without one the value's own type does: `bool`, `int` as a 64-bit
        integer, `float` as a 64-bit float, `str`, anything with a buffer as bytes, and a
        sequence of strings.

        An integer is stored in its own form, which JavaScript cannot read. For an integer
        that react-native-mmkv also reads, name `swiftmmkv.number`.

        `expiry` says how long the value is kept: an `Expiry`, a `timedelta`, or an aware
        `datetime`. Without one the value has the store's default expiry, which is to keep
        it until it is removed unless the store was opened with another. The first write
        that expires switches the store's file to a format react-native-mmkv has no option
        for.

        The result is `False` when the store turns the write away: the key is empty, the
        store is read-only, suspended or closed, or the pair is larger than the store's item
        size limit. Nothing is raised for those. A bad argument does raise: `TypeError` for
        a value that is not of the type named, `OverflowError` for a number the type cannot
        hold, and `ValueError` for a key that contains U+0000.
        """
        if isinstance(key, Key):
            if type is not MISSING:
                raise TypeError("A typed key already says how its value is stored.")
            name, c_key = key.name, key._c_name
            converter = key.converter
        else:
            name, c_key = name_of(key)
            converter = converter_for_value(value) if type is MISSING else converter_of(type)
        return bool(converter.write(Writer(self, name, c_key, expiry_bits(expiry)), value))

    # MARK: - Reads

    @overload
    def get[T](self, key: DefaultedKey[T], /) -> T: ...
    @overload
    def get[T](self, key: Key[T], /) -> T | None: ...
    @overload
    def get[T, D](self, key: Key[T], /, *, default: D) -> T | D: ...
    @overload
    def get[T](self, key: str, type: TypeSpec[T], /) -> T | None: ...
    @overload
    def get[T, D](self, key: str, type: TypeSpec[T], /, *, default: D) -> T | D: ...
    def get(self, key: Any, type: Any = MISSING, /, *, default: Any = MISSING) -> Any:
        """The value of `key`, or `None` if it has none.

        ::

            store.get("username", str)                # str | None
            store.get("retries", swiftmmkv.int32)     # int | None
            store.get("volume", float, default=1.0)   # float
            store.get(USERNAME)                       # the type the key names

        A string key is read as `type`, which is a type or a converter. A typed key names
        its own. `default` is returned in place of `None`, and a `DefaultedKey` has one
        already.

        A key has no value while the store is suspended, and once it is closed. An expired
        key has none either.

        The store records no types, so read a key as the type it was written as. Another
        type reads as a wrong value or as `None`, and not as an error. What a converter
        raises, such as `json.JSONDecodeError` from `swiftmmkv.JSON`, is raised from here.
        """
        return self._get(key, type, default)

    def _get(self, key: Any, type: Any, default: Any) -> Any:
        if isinstance(key, Key):
            if type is not MISSING:
                raise TypeError("A typed key already says how its value is read.")
            value = key.converter.read(Reader(self, key.name, key._c_name))
            if value is not None:
                return value
            if default is not MISSING:
                return default
            return key.default if isinstance(key, DefaultedKey) else None
        if type is MISSING:
            raise TypeError(
                "A read names the type of its value, as in store.get(key, str), because a "
                "store's file records no types."
            )
        name, c_key = name_of(key)
        value = converter_of(type).read(Reader(self, name, c_key))
        if value is None and default is not MISSING:
            return default
        return value

    def value_size(self, key: str | Key[Any], /) -> int | None:
        """The length in bytes of the string or bytes under `key`, without reading them, or
        `None` if the key has no value."""
        _, c_key = name_of(key)
        out = c_size_t()
        found = _raw.swiftmmkv_store_value_size(self._handle, c_key, byref(out))
        return out.value if found else None

    # MARK: - Subscripts

    @overload
    def __getitem__[T](self, key: DefaultedKey[T], /) -> T: ...
    @overload
    def __getitem__[T](self, key: Key[T], /) -> T: ...
    def __getitem__(self, key: Any, /) -> Any:
        """The value of a typed key. `KeyError` if it has none and the key has no default.

        A string is refused: it cannot say what was stored under it, so read it with
        `get(key, type)`.
        """
        if not isinstance(key, Key):
            raise TypeError(
                "A subscript takes a typed key, because a store's file records no types. "
                "Read a string key with store.get(key, type)."
            )
        value = self._get(key, MISSING, MISSING)
        if value is None:
            raise KeyError(key.name)
        return value

    def __setitem__[T](self, key: Key[T], value: T, /) -> None:
        """Stores the value of a typed key. Whether the store took it is not reported:
        `set` returns that."""
        if not isinstance(key, Key):
            raise TypeError(
                "A subscript takes a typed key. Write a string key with store.set(key, value)."
            )
        self.set(key, value)

    def __delitem__(self, key: str | Key[Any], /) -> None:
        """Removes `key`. Unlike a `dict`, a key that has no value is not an error."""
        self.remove(key)

    # MARK: - Keys

    def __contains__(self, key: object, /) -> bool:
        """Whether `key`, a string or a typed key, has a value."""
        if not isinstance(key, str | Key):
            return False
        try:
            _, c_key = name_of(key)
        except ValueError:
            # A name with U+0000 in it, which no key of a store has.
            return False
        contains: bool = _raw.swiftmmkv_store_contains(self._handle, c_key)
        return contains

    def __len__(self) -> int:
        """The number of keys in the store."""
        count: int = _raw.swiftmmkv_store_count(self._handle)
        return count

    def __iter__(self) -> Iterator[str]:
        """Iterates over the keys the store has now, in no particular order."""
        return iter(self.keys())

    def keys(self, *, under: str | None = None, separator: str = ".") -> frozenset[str]:
        """Every key in the store, or with `under`, a prefix and every key under it.

        A key is under a prefix when it starts with the prefix and then the separator, so
        `settings.theme` is under `settings`, and `settingsTheme` is not. An empty prefix
        has every key under it. The keys are whole keys, with the prefix. These are the
        keys `remove_under` removes.

        The result is a copy, which later changes to the store leave alone.
        """
        handle = self._handle
        if under is None:
            keys = _raw.read_packed(
                lambda buffer, capacity, size, count: (
                    _raw.swiftmmkv_store_keys(handle, buffer, capacity, size, count),
                    True,
                )[1]
            )
        else:
            c_under, c_separator = _raw.c_string(under), _raw.c_string(separator)
            keys = _raw.read_packed(
                lambda buffer, capacity, size, count: (
                    _raw.swiftmmkv_store_keys_under(
                        handle, c_under, c_separator, buffer, capacity, size, count
                    ),
                    True,
                )[1]
            )
        return frozenset(keys or ())

    # MARK: - Removal

    def remove(self, key: str | Key[Any], /) -> bool:
        """Removes `key` and its value, and returns whether there was a value to remove.

        The result is `False` for a key that had no value, and when the store turns the
        removal away, as it does a write."""
        _, c_key = name_of(key)
        removed: bool = _raw.swiftmmkv_store_remove(self._handle, c_key)
        return removed

    def remove_many(self, keys: Iterable[str | Key[Any]], /) -> None:
        """Removes the values of `keys`, all at once, as one operation."""
        if isinstance(keys, str | Key):
            raise TypeError("remove_many takes several keys. Remove one with remove.")
        packed = _raw.pack_strings(name_of(key)[0] for key in keys)
        _raw.swiftmmkv_store_remove_many(self._handle, packed, len(packed))

    def remove_under(self, prefix: str, /, *, separator: str = ".") -> None:
        """Removes `prefix` and every key under it, all at once, as `keys` lists them."""
        _raw.swiftmmkv_store_remove_under(
            self._handle, _raw.c_string(prefix), _raw.c_string(separator)
        )

    def clear(self, *, keep_capacity: bool = False) -> None:
        """Removes every key and value.

        With `keep_capacity` the store's file keeps its current size, which is faster and
        saves growing it again. Without, it shrinks back to its initial size.
        """
        _raw.swiftmmkv_store_remove_all(self._handle, bool(keep_capacity))

    def import_all(self, source: Store, /) -> int:
        """Copies every key and value of `source` into this store, replacing the keys this
        store already has, and returns the number of keys copied. The two stores may differ
        in mode and encryption."""
        if not isinstance(source, Store):
            raise TypeError(f"A Store was expected, and not {builtins.type(source).__name__!r}.")
        count: int = _raw.swiftmmkv_store_import_all(self._handle, source._handle)
        return count

    # MARK: - Exclusive access

    def locked(self) -> AbstractContextManager[None]:
        """A context manager that holds exclusive access to the store for its block.

        ::

            with store.locked():
                launches = store.get("launches", int, default=0)
                store.set("launches", launches + 1)

        Nothing else can read or write the store until the block is left: not another
        thread, and, for a multi-process store, not another process or another copy of
        MMKV in this process. Use it for a read-modify-write that must not be interleaved,
        and for batches, since the file lock is taken once however much the block does.

        Listeners are told about the keys the block changed once it is left, each key once,
        so they never see part of what it writes. What the block raises is raised from the
        `with` as usual, after the lock is given up, and the keys written by then stay
        written.

        The lock is recursive, so blocks can nest. A block must be left on the thread that
        entered it, so do not hold one across an `await` or a `yield`. Closing or suspending
        the store inside a block raises `RuntimeError`. While the store is suspended, and
        once it is closed, the block takes nothing and every operation in it is turned away.
        """
        return _Locked(self)

    # MARK: - Batches

    @overload
    def set_many(
        self, values: Mapping[str, Plain], /, *, expiry: ExpiryLike | None = None
    ) -> bool: ...
    @overload
    def set_many[T](
        self,
        values: Mapping[str, T],
        type: TypeSpec[T],
        /,
        *,
        expiry: ExpiryLike | None = None,
    ) -> bool: ...
    def set_many(
        self,
        values: Mapping[str, Any],
        type: Any = MISSING,
        /,
        *,
        expiry: ExpiryLike | None = None,
    ) -> bool:
        """Stores several values under one lock, and returns whether the store took all of
        them.

        ::

            store.set_many({"score.1": 10.0, "score.2": 12.5})

        The store is locked once for the whole batch, and listeners are told after every
        value is written, as one operation. With `type` every value is stored as that. A
        batch is not atomic if the process is killed during it: the values written by then
        are kept.
        """
        stored = True
        with self.locked():
            for key, value in values.items():
                if type is MISSING:
                    stored = self.set(key, value, expiry=expiry) and stored
                else:
                    stored = self.set(key, value, type, expiry=expiry) and stored
        return stored

    def get_many[T](self, keys: Iterable[str], type: TypeSpec[T], /) -> dict[str, T]:
        """The values of several keys of one type, read under one lock. A key with no value
        is left out.

        ::

            store.get_many(["score.1", "score.2"], float)   # {"score.1": 10.0, ...}
        """
        values: dict[str, T] = {}
        with self.locked():
            for key in keys:
                value = self.get(key, type)
                if value is not None:
                    values[key] = value
        return values

    # MARK: - Changes

    def subscribe(
        self,
        on_change: Callable[[ChangeBatch], object],
        /,
        *,
        key: str | Key[Any] | None = None,
        under: str | None = None,
        separator: str = ".",
    ) -> Subscription:
        """Calls `on_change` once for each operation that changes the store, until the
        subscription is cancelled or the store is closed.

        ::

            def on_change(batch: ChangeBatch) -> None:
                for key in batch.keys:
                    print("changed:", key, batch.get(key, str))
                if batch.is_external:
                    print("changed by another process")

            subscription = store.subscribe(on_change)

        With `key` the listener hears only of the operations that may have changed that
        key, and with `under` of those that may have changed a prefix or a key under it,
        with the batch's keys narrowed to those. That is each operation that sets or
        removes such a key, and each external change, since such a change does not say
        which keys it touched.

        The listener is shared with every `Store` over the same files in this process. It
        runs on the thread that made or noticed the change, after the operation has
        returned, and may read and write the store. A change from another process is only
        noticed when the store is next used, or by `check_for_external_changes`.

        An error the listener raises does not reach the code that changed the store. It is
        handed to `sys.unraisablehook`, and the listener is called again for the next
        change.
        """
        return _changes.subscribe_to_changes(self, on_change, key, under, separator)

    @overload
    def observe[T](
        self,
        key: DefaultedKey[T],
        on_value: Callable[[T], object],
        /,
        *,
        on_error: Callable[[Exception], object] | None = None,
    ) -> Subscription: ...
    @overload
    def observe[T](
        self,
        key: Key[T],
        on_value: Callable[[T | None], object],
        /,
        *,
        on_error: Callable[[Exception], object] | None = None,
    ) -> Subscription: ...
    @overload
    def observe[T](
        self,
        key: str,
        type: TypeSpec[T],
        on_value: Callable[[T | None], object],
        /,
        *,
        on_error: Callable[[Exception], object] | None = None,
    ) -> Subscription: ...
    def observe(
        self,
        key: Any,
        *arguments: Any,
        on_error: Callable[[Exception], object] | None = None,
    ) -> Subscription:
        """Follows the value of one key: calls `on_value` with the value the store holds
        now, before this returns, and again after each operation that may have changed it.

        ::

            store.observe("volume", float, lambda volume: player.set_volume(volume or 1.0))
            store.observe(VOLUME, player.set_volume)

        A missing value is `None`, or the default of a `DefaultedKey`. The listener is
        called whenever the key is written, even with the value it had, and on every
        external change, so it can be given the value it was last given.

        A value its converter cannot read goes to `on_error`, and the listener carries on
        with the next change. Without `on_error`, the error of the first read is raised
        from here and nothing is subscribed, and the error of a later one is handed to
        `sys.unraisablehook`.
        """
        if isinstance(key, Key):
            if len(arguments) != 1:
                raise TypeError("observe takes a typed key and a listener.")
            (on_value,) = arguments
            converter = key.converter
            default = key.default if isinstance(key, DefaultedKey) else None
        else:
            if len(arguments) != 2:
                raise TypeError("observe takes a key, the type of its value, and a listener.")
            type, on_value = arguments
            converter = converter_of(type)
            default = None
        if not callable(on_value):
            raise TypeError("A listener must be callable.")
        name, c_key = name_of(key)

        def deliver() -> None:
            try:
                value = converter.read(Reader(self, name, c_key))
            except Exception as error:
                if on_error is None:
                    raise
                on_error(error)
                return
            on_value(default if value is None else value)

        subscription = self.subscribe(lambda batch: deliver(), key=key)
        try:
            deliver()
        except BaseException:
            subscription.cancel()
            raise
        return subscription

    def changes(
        self,
        *,
        key: str | Key[Any] | None = None,
        under: str | None = None,
        separator: str = ".",
    ) -> AsyncIterator[ChangeBatch]:
        """The batches `subscribe` gives a listener, as an async iterator.

        ::

            async for batch in store.changes():
                print("changed:", batch.keys)

        A consumer that falls behind misses no key, but receives the batches that are
        waiting as one, with each key once. The iteration ends when the store is closed,
        after the batch that says so.

        The store is followed from this call, and not from the first `await`, so nothing
        that happens in between is missed. It is followed until the iterator is let go of,
        or its `aclose` is awaited. One task at a time can wait on an iterator.
        """
        return _changes.Changes(self, key, under, separator)

    @overload
    def values[T](self, key: DefaultedKey[T], /) -> AsyncIterator[T]: ...
    @overload
    def values[T](self, key: Key[T], /) -> AsyncIterator[T | None]: ...
    @overload
    def values[T](self, key: str, type: TypeSpec[T], /) -> AsyncIterator[T | None]: ...
    def values(self, key: Any, type: Any = MISSING, /) -> AsyncIterator[Any]:
        """The values of one key over time, as an async iterator: the value the store holds
        now, and then its value after each operation that may have changed it.

        ::

            async for volume in store.values(VOLUME):
                player.set_volume(volume)

        A missing value is `None`, or the default of a `DefaultedKey`. A consumer that falls
        behind skips to the newest value. An element is produced whenever the key is
        written, even with the value it had, and on every external change.

        A value its converter cannot read is raised from the iteration, which ends it. The
        iteration also ends when the store is closed. While the store is suspended nothing
        is produced, and the store's value is produced again when it resumes.

        The key is followed until the iterator is let go of, or its `aclose` is awaited.
        """
        if isinstance(key, Key):
            if type is not MISSING:
                raise TypeError("A typed key already says how its value is read.")
            converter = key.converter
            default = key.default if isinstance(key, DefaultedKey) else MISSING
        else:
            if type is MISSING:
                raise TypeError("values takes a key and the type of its value.")
            converter = converter_of(type)
            default = MISSING
        name, c_key = name_of(key)
        return _changes.Values(
            self, key, lambda: converter.read(Reader(self, name, c_key)), default
        )

    def check_for_external_changes(self) -> None:
        """Checks whether another process, or another copy of MMKV, changed the store,
        reloading it and telling listeners if so. Reads and writes make the same check, so
        this is only needed while the store is otherwise idle."""
        _raw.swiftmmkv_store_check_for_external_changes(self._handle)

    # MARK: - Suspension

    def suspend(self) -> None:
        """Stops a multi-process store from taking its file lock, until `resume`.

        It turns new operations away, waits for those under way, and returns once nothing
        holds the lock. While a store is suspended, reads find nothing, writes and removals
        do nothing, and what reports a status raises an `MMKVError` with
        `Status.STORE_IS_SUSPENDED`. A single-process store takes no file lock, so
        suspending one does nothing.

        This is for iOS, which ends an app that is suspended while it holds a lock on a
        file it shares with other processes. It is here because the C interface has it.

        Raises `RuntimeError` inside a `locked` block of the store.
        """
        self._refuse_inside_lock("suspended")
        _raw.swiftmmkv_store_suspend(self._handle)

    def resume(self) -> None:
        """Lets a suspended store take its file lock again, and tells listeners of an
        external change."""
        _raw.swiftmmkv_store_resume(self._handle)

    @property
    def suspended(self) -> bool:
        """Whether the store is suspended. A closed store is not."""
        suspended: bool = _raw.swiftmmkv_store_is_suspended(self._handle)
        return suspended

    # MARK: - Maintenance

    @property
    def byte_size(self) -> int:
        """The size of the store's file in bytes. The file grows as values are written, and
        removing a value does not shrink it: see `trim`."""
        size: int = _raw.swiftmmkv_store_byte_size(self._handle)
        return size

    @property
    def used_byte_size(self) -> int:
        """The number of bytes of the store's file that hold data."""
        size: int = _raw.swiftmmkv_store_used_byte_size(self._handle)
        return size

    def trim(self) -> None:
        """Rewrites the store's file without the space that removed and overwritten values
        left behind."""
        _raw.swiftmmkv_store_trim(self._handle)

    def release_memory(self) -> None:
        """Lets go of the memory the store holds: its copy of its contents, and its mapping
        of its file. Nothing is lost, and the next read or write loads the file again, which
        costs as much as opening the store did. Listeners are told nothing."""
        _raw.swiftmmkv_store_release_memory(self._handle)

    def sync(self) -> None:
        """Blocks until the store's contents are flushed to disk. The operating system
        flushes a memory-mapped file by itself, even if the process crashes, so this only
        matters when the machine may lose power."""
        _raw.swiftmmkv_store_sync(self._handle)

    @property
    def expiry_enabled(self) -> bool:
        """Whether the store's file records when each key expires, which it does from the
        first write that expires until `disable_expiry`. A suspended store answers
        `False`."""
        enabled: bool = _raw.swiftmmkv_store_is_expiry_enabled(self._handle)
        return enabled

    def disable_expiry(self) -> None:
        """Rewrites the store's file in the format it had before its first expiring write,
        which is the format react-native-mmkv reads.

        Keys that have expired are dropped, and every other key is kept until it is removed,
        whatever expiry it was written with. The next write that expires switches the file
        back. Raises `MMKVError` if the file cannot be rewritten, for example because the
        store is read-only.
        """
        check(_raw.swiftmmkv_store_disable_expiry(self._handle))

    def rekey(self, encryption: Encryption | None, /) -> None:
        """Re-encrypts the store with `encryption`, or decrypts it with `None`. Raises
        `MMKVError` if it cannot, for example because the store is read-only."""
        if encryption is None:
            check(_raw.swiftmmkv_store_rekey(self._handle, _raw.SWIFTMMKV_ENCRYPTION_NONE, None, 0))
        else:
            key = encryption.key
            check(_raw.swiftmmkv_store_rekey(self._handle, int(encryption.cipher), key, len(key)))

    def back_up(self, to: StrPath, /) -> None:
        """Copies the store's files into the directory `to`, replacing a copy already
        there. The store's locks are held while its files are copied, so the backup holds
        every write that returned before it began. Raises `MMKVError` if it cannot."""
        check(_raw.swiftmmkv_store_back_up(self._handle, _raw.c_string(os.fspath(to))))

    def restore(self, backup: StrPath, /) -> bool:
        """Replaces the store's contents with those of its copy in the directory `backup`,
        and returns whether `backup` held one. Listeners are told of an external change.
        Raises `MMKVError` if it cannot, for example because the copy does not match its
        checksum."""
        restored = c_bool(False)
        check(
            _raw.swiftmmkv_store_restore(
                self._handle, _raw.c_string(os.fspath(backup)), byref(restored)
            )
        )
        return restored.value

    def __repr__(self) -> str:
        state = " closed" if self.closed else ""
        directory = os.fspath(self._configuration.directory)
        return f"<swiftmmkv.Store {str(self._configuration.id)!r} in {directory!r}{state}>"


# MARK: - Opening


@overload
def open(configuration: Configuration, /) -> Store: ...
@overload
def open(
    directory: StrPath,
    /,
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
) -> Store: ...
def open(directory: Configuration | StrPath, /, **options: Any) -> Store:
    """Opens a store.

    ::

        store = swiftmmkv.open("/var/lib/app/mmkv", mode=Mode.SINGLE_PROCESS)
        store = swiftmmkv.open(directory, mode=Mode.MULTI_PROCESS, id="session")
        store = swiftmmkv.open(configuration)

    The keyword arguments are the fields of `Configuration`, which documents each of them,
    and a `Configuration` can be passed in their place. `mode` has no default, because the
    wrong choice loses writes: see `Mode`. The directory is created if it does not exist.

    Raises `MMKVError` if the store cannot be opened: `Status.OPEN_FAILED` for an empty
    identifier or directory, `Status.INVALID_ENCRYPTION_KEY` for a key of the wrong length,
    and `Status.INVALID_ARGUMENT` for an option that is not one of its values.

    Opening the same files twice in one process gives two `Store` objects over one
    underlying store. They share their contents and their listeners, and the
    configuration of the first to be opened wins.
    """
    if isinstance(directory, Configuration):
        if options:
            raise TypeError("open takes a Configuration or keyword arguments, and not both.")
        configuration = directory
    else:
        configuration = Configuration(directory=directory, **options)
    handle = make_configuration_handle(configuration)
    try:
        store = c_void_p()
        check(_raw.swiftmmkv_store_open(handle, byref(store)))
    finally:
        _raw.swiftmmkv_configuration_destroy(handle)
    assert store.value is not None
    return Store._make(configuration, store.value)


def open_temporary(*, id: StoreID | str = StoreID.DEFAULT) -> Store:
    """Opens a single-process store in a new temporary directory, for a store that does not
    need to last, such as a test's.

    Every call uses a different directory, so the store starts empty. To change anything
    else about the store, open a `Configuration.temporary()` that `dataclasses.replace` has
    changed.
    """
    return open(Configuration.temporary(id=id))
