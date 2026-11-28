"""Change listeners: subscriptions, the batches they are given, and the async iterators over
them."""

from __future__ import annotations

import asyncio
import threading
import weakref
from collections import deque
from collections.abc import Callable
from typing import TYPE_CHECKING, Any, Final, Self, final, overload

from . import _raw
from ._converters import TypeSpec
from ._keys import MISSING, DefaultedKey, Key

if TYPE_CHECKING:
    from ._store import Store


# MARK: - Callbacks
#
# A callback's context is a number that names a subscription here, and not a pointer to a
# Python object, so the library holds nothing that Python could free under it. A
# subscription stays in `_contexts` until the library says, through `_on_release`, that the
# callback will not be called again. That can be after the subscription is cancelled, when
# another thread is in the middle of a call.

_contexts: dict[int, Subscription] = {}
_contexts_lock = threading.Lock()
_last_context = 0

#: The subscriptions the library has finished with, whose handles are still to be freed.
#: They are not freed from `_release`, which the library can call from inside a cancel.
_released: deque[Subscription] = deque()


def _register(subscription: Subscription) -> int:
    global _last_context
    with _contexts_lock:
        _last_context += 1
        _contexts[_last_context] = subscription
        return _last_context


def free_released() -> None:
    """Frees the handles of the subscriptions the library has finished with."""
    while True:
        try:
            subscription = _released.popleft()
        except IndexError:
            return
        subscription._free()


def _change(context: int | None, batch: Any) -> None:
    # An error that is raised here does not cross into the library: `ctypes` hands it to
    # `sys.unraisablehook`.
    subscription = _contexts.get(context or 0)
    if subscription is None or subscription._cancelled:
        return
    # The batch and its keys are only valid until this returns, so both are copied.
    contents = batch.contents
    keys = tuple(
        contents.keys[index].decode("utf-8", "replace") for index in range(contents.key_count)
    )
    subscription._deliver(keys, bool(contents.is_external))


def _integrity_failure(context: int | None, id: bytes, kind: int) -> None:
    subscription = _contexts.get(context or 0)
    if subscription is None or subscription._cancelled:
        return
    subscription._deliver(id.decode("utf-8", "replace"), kind)


def _release(context: int | None) -> None:
    subscription = _contexts.pop(context or 0, None)
    if subscription is not None:
        _released.append(subscription)


# The function pointers the library is given. They live as long as the module does, which is
# longer than anything the library could call them for.
_on_change: Final = _raw.swiftmmkv_change_callback(_change)
_on_integrity_failure: Final = _raw.swiftmmkv_integrity_failure_callback(_integrity_failure)
_on_release: Final = _raw.swiftmmkv_context_release(_release)


@final
class Subscription:
    """A registration of a listener, which `cancel` ends.

    ::

        subscription = store.subscribe(on_change)
        ...
        subscription.cancel()

    It is also a context manager, which cancels on the way out::

        with store.subscribe(on_change):
            ...

    A subscription runs until it is cancelled or its store is closed. Letting go of it does
    not cancel it, so a listener that is meant to last for the life of the store needs no
    one to hold its subscription.
    """

    __slots__ = ("_cancelled", "_deliver", "_handle", "_lock")

    def __init__(self) -> None:
        raise TypeError("A Subscription is made by subscribing, and not by calling its class.")

    @classmethod
    def _make(cls, deliver: Callable[..., object]) -> Subscription:
        self = object.__new__(cls)
        self._deliver = deliver
        self._handle = None
        self._cancelled = False
        # Reentrant, because a cancel can run where the garbage collector chooses to.
        self._lock = threading.RLock()
        return self

    _deliver: Callable[..., object]
    _handle: int | None
    _cancelled: bool
    _lock: threading.RLock

    def _attach(self, handle: int) -> None:
        """Gives the subscription the handle the library made for it."""
        with self._lock:
            self._handle = handle
            is_cancelled = self._cancelled
        if is_cancelled:
            # Cancelled from its own listener, before subscribing had returned.
            self._free()

    def cancel(self) -> None:
        """Stops the listener from being called. Cancelling twice does nothing more.

        A call that another thread already has under way may still finish afterwards.
        """
        with self._lock:
            self._cancelled = True
        self._free()

    def _free(self) -> None:
        """Gives the handle back to the library, which is how the library cancels."""
        with self._lock:
            handle, self._handle = self._handle, None
        if handle is not None:
            _raw.swiftmmkv_subscription_cancel(handle)

    @property
    def cancelled(self) -> bool:
        """Whether the subscription has been cancelled.

        A subscription that its store's closing ended is not cancelled, though its listener
        is no longer called either.
        """
        return self._cancelled

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *exc: object) -> None:
        self.cancel()

    def __repr__(self) -> str:
        return f"<swiftmmkv.Subscription{' cancelled' if self._cancelled else ''}>"


def subscribe(deliver: Callable[..., object], attach: Callable[[int], int]) -> Subscription:
    """Makes a subscription whose listener is `deliver`.

    `attach` is given the context to subscribe with, and returns the handle of what it
    subscribed.
    """
    free_released()
    subscription = Subscription._make(deliver)
    context = _register(subscription)
    try:
        handle = attach(context)
    except BaseException:
        with _contexts_lock:
            _contexts.pop(context, None)
        raise
    subscription._attach(handle)
    return subscription


def subscribe_to_changes(
    store: Store,
    on_change: Callable[[ChangeBatch], object],
    key: str | Key[Any] | None,
    under: str | None,
    separator: str,
) -> Subscription:
    if not callable(on_change):
        raise TypeError("A listener must be callable.")
    if key is not None and under is not None:
        raise TypeError("A subscription follows a key or the keys under a prefix, and not both.")
    c_key = None if key is None else name_of(key)[1]
    c_under = None if under is None else _raw.c_string(under)
    c_separator = _raw.c_string(separator)

    def deliver(keys: tuple[str, ...], is_external: bool) -> None:
        on_change(ChangeBatch._make(store, keys, is_external))

    def attach(context: int) -> int:
        handle: int
        if c_key is not None:
            handle = _raw.swiftmmkv_store_subscribe_key(
                store._handle, c_key, context, _on_change, _on_release
            )
        elif c_under is not None:
            handle = _raw.swiftmmkv_store_subscribe_under(
                store._handle, c_under, c_separator, context, _on_change, _on_release
            )
        else:
            handle = _raw.swiftmmkv_store_subscribe(store._handle, context, _on_change, _on_release)
        return handle

    return subscribe(deliver, attach)


def subscribe_to_integrity_failures(deliver: Callable[[str, int], object]) -> Subscription:
    def attach(context: int) -> int:
        handle: int = _raw.swiftmmkv_subscribe_to_integrity_failures(
            context, _on_integrity_failure, _on_release
        )
        return handle

    return subscribe(deliver, attach)


def name_of(key: str | Key[Any]) -> tuple[str, bytes]:
    """The name of a string key or a typed one, as a `str` and as the library takes it."""
    if isinstance(key, Key):
        return key.name, key._c_name
    if isinstance(key, str):
        return key, _raw.c_string(key)
    raise TypeError(f"A key is a str or a Key, and not {type(key).__name__!r}.")


# MARK: - Batches


@final
class ChangeBatch:
    """What one operation changed in a store.

    An operation is one call, such as `Store.remove_under`, or everything a `Store.locked`
    block does, so a block that writes three keys is one batch of three, delivered after
    all three are written.

    A batch is a copy, so it can be kept after the listener returns. It holds no values:
    `get` reads the store, and gives what the store holds when it is called, which is what
    the operation wrote unless something has written since.
    """

    __slots__ = ("_is_external", "_keys", "_store")

    _store: Store
    _keys: tuple[str, ...]
    _is_external: bool

    def __init__(self) -> None:
        raise TypeError("A ChangeBatch is given to a listener, and not made by calling its class.")

    @classmethod
    def _make(cls, store: Store, keys: tuple[str, ...], is_external: bool) -> ChangeBatch:
        self = object.__new__(cls)
        self._store = store
        self._keys = keys
        self._is_external = is_external
        return self

    @property
    def store(self) -> Store:
        """The store that changed."""
        return self._store

    @property
    def keys(self) -> tuple[str, ...]:
        """The keys that were set or removed through this package, in this process, each
        once. For a subscription to a key or a prefix, only the keys it follows."""
        return self._keys

    @property
    def is_external(self) -> bool:
        """Whether another process, or another copy of MMKV in this process, changed the
        store. Which keys it changed is not known, so any key may have changed, and not
        only `keys`."""
        return self._is_external

    def __contains__(self, key: object, /) -> bool:
        """Whether `key`, a string or a typed key, is among `keys`."""
        if isinstance(key, Key):
            return key.name in self._keys
        return key in self._keys

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
        """Reads a value from the store the batch came from, as `Store.get` does."""
        return self._store._get(key, type, default)

    def __repr__(self) -> str:
        external = ", is_external=True" if self._is_external else ""
        return f"<swiftmmkv.ChangeBatch keys={self._keys!r}{external}>"


# MARK: - Async iterators


def _finish(future: asyncio.Future[None]) -> None:
    if not future.done():
        future.set_result(None)


class _Wakeup:
    """Lets any thread wake the one task that waits here.

    A wake-up that comes while nothing waits is kept for the next wait, and several are
    kept as one.
    """

    __slots__ = ("_is_set", "_lock", "_waiting")

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._is_set = False
        self._waiting: tuple[asyncio.AbstractEventLoop, asyncio.Future[None]] | None = None

    def set(self) -> None:
        with self._lock:
            self._is_set = True
            waiting, self._waiting = self._waiting, None
        if waiting is not None:
            loop, future = waiting
            try:
                loop.call_soon_threadsafe(_finish, future)
            except RuntimeError:
                pass  # The loop has closed, so nothing is waiting any more.

    async def wait(self) -> None:
        while True:
            with self._lock:
                if self._is_set:
                    self._is_set = False
                    return
                if self._waiting is not None:
                    raise RuntimeError("Another task is already waiting on this iterator.")
                loop = asyncio.get_running_loop()
                future = loop.create_future()
                self._waiting = (loop, future)
            try:
                await future
            finally:
                with self._lock:
                    if self._waiting is not None and self._waiting[1] is future:
                        self._waiting = None


class Changes:
    """The async iterator `Store.changes` returns."""

    __slots__ = (
        "__weakref__",
        "_has_ended",
        "_is_external",
        "_keys",
        "_lock",
        "_store",
        "_subscription",
        "_wakeup",
    )

    def __init__(
        self, store: Store, key: str | Key[Any] | None, under: str | None, separator: str
    ) -> None:
        self._store = store
        self._lock = threading.Lock()
        # A dict for the keys, which keeps each once and in the order it first changed.
        self._keys: dict[str, None] = {}
        self._is_external = False
        self._has_ended = False
        self._wakeup = _Wakeup()
        # The subscription must not keep the iterator alive, so that letting go of the
        # iterator is enough to stop following.
        weak = weakref.ref(self)

        def on_change(batch: ChangeBatch) -> None:
            iterator = weak()
            if iterator is not None:
                iterator._add(batch)

        self._subscription = subscribe_to_changes(store, on_change, key, under, separator)
        weakref.finalize(self, self._subscription.cancel)
        if store.closed:
            self._has_ended = True

    def _add(self, batch: ChangeBatch) -> None:
        # A closed store tells its listeners so once, and nothing after that.
        has_ended = self._store.closed
        with self._lock:
            for key in batch.keys:
                self._keys.setdefault(key)
            self._is_external = self._is_external or batch.is_external
            self._has_ended = self._has_ended or has_ended
        self._wakeup.set()

    def __aiter__(self) -> Self:
        return self

    async def __anext__(self) -> ChangeBatch:
        while True:
            with self._lock:
                keys, self._keys = tuple(self._keys), {}
                is_external, self._is_external = self._is_external, False
                has_ended = self._has_ended
            if keys or is_external:
                return ChangeBatch._make(self._store, keys, is_external)
            if has_ended:
                self._subscription.cancel()
                raise StopAsyncIteration
            await self._wakeup.wait()

    async def aclose(self) -> None:
        """Stops following the store, and ends the iteration."""
        with self._lock:
            self._has_ended = True
            self._keys = {}
            self._is_external = False
        self._subscription.cancel()
        self._wakeup.set()


class Values[T]:
    """The async iterator `Store.values` returns."""

    __slots__ = (
        "__weakref__",
        "_default",
        "_has_ended",
        "_read",
        "_store",
        "_subscription",
        "_wakeup",
    )

    def __init__(
        self, store: Store, key: str | Key[Any], read: Callable[[], T | None], default: Any
    ) -> None:
        self._store = store
        self._read = read
        #: What a missing value is produced as, or `MISSING` to produce `None`.
        self._default = default
        self._has_ended = False
        self._wakeup = _Wakeup()
        weak = weakref.ref(self)

        def on_change(batch: ChangeBatch) -> None:
            iterator = weak()
            if iterator is not None:
                iterator._wakeup.set()

        self._subscription = subscribe_to_changes(store, on_change, key, None, ".")
        weakref.finalize(self, self._subscription.cancel)
        # The first element is the value the store holds now.
        self._wakeup.set()

    def __aiter__(self) -> Self:
        return self

    async def __anext__(self) -> T:
        while True:
            if self._has_ended:
                raise StopAsyncIteration
            await self._wakeup.wait()
            if self._has_ended:
                raise StopAsyncIteration
            if self._store.closed:
                self._end()
                raise StopAsyncIteration
            try:
                value = self._read()
            except BaseException:
                # A value that cannot be read ends the sequence, as it does an iteration.
                self._end()
                raise
            if value is None and self._store.suspended:
                # Nothing can be read while the store is suspended. Resuming wakes this.
                continue
            if value is None and self._default is not MISSING:
                return self._default  # type: ignore[no-any-return]
            return value  # type: ignore[return-value]

    def _end(self) -> None:
        self._has_ended = True
        self._subscription.cancel()

    async def aclose(self) -> None:
        """Stops following the key, and ends the iteration."""
        self._end()
        self._wakeup.set()
