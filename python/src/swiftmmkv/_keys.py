"""Typed keys: a key's name and the type of its value, written once."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any, Final, Protocol, Self, overload

from . import _raw
from ._converters import Converter, TypeSpec, converter_of

if TYPE_CHECKING:
    from ._store import Store

_MISSING: Final = object()


class HasStore(Protocol):
    """An object whose `Key` attributes read and write `store`."""

    @property
    def store(self) -> Store: ...


class Key[T]:
    """A key's name and the type of its value, so that every use of the key agrees.

    ::

        USERNAME = Key("username", str)
        VOLUME = Key("volume", float, default=0.5)

        store[USERNAME] = "blob"
        store.get(USERNAME)   # str | None
        store[VOLUME]         # float: 0.5 until a volume is stored

    A typed key reads and writes exactly what a string key of the same name does, so the two
    can be mixed. A key that takes arguments is a function that returns one::

        def draft(post_id: int) -> Key[str]:
            return Key(f"draft.{post_id}", str)

    Given a `default`, the key is a `DefaultedKey`, which reads the default in place of
    `None` when the store has no value.

    A key is also a descriptor. As an attribute of a class whose instances have a `store`,
    such as a subclass of `Fields`, it reads and writes like a field, and setting it to
    `None` removes it::

        class Preferences(Fields):
            username = Key("username", str)

        Preferences(store).username = "blob"

    A key is immutable and hashable. Two keys are equal when they have the same name, the
    same converter object, and equal defaults if they have one.
    """

    __slots__ = ("_c_name", "converter", "name")

    #: The key's name in the store.
    name: str
    #: How the key's value is stored.
    converter: Converter[T]
    _c_name: bytes

    @overload
    def __new__(cls, name: str, type: TypeSpec[T], /) -> Key[T]: ...
    @overload
    def __new__(cls, name: str, type: TypeSpec[T], /, *, default: T) -> DefaultedKey[T]: ...
    def __new__(cls, name: str, type: TypeSpec[T], /, *, default: Any = _MISSING) -> Any:
        if not isinstance(name, str):
            # `type` is the parameter here, and not the built-in.
            raise TypeError(f"A key's name is a str, and not {name.__class__.__name__!r}.")
        if default is not _MISSING and not issubclass(cls, DefaultedKey):
            cls = DefaultedKey
        elif default is _MISSING and issubclass(cls, DefaultedKey):
            raise TypeError("A DefaultedKey needs a default.")
        self = object.__new__(cls)
        object.__setattr__(self, "name", name)
        object.__setattr__(self, "converter", converter_of(type))
        object.__setattr__(self, "_c_name", _raw.c_string(name))
        if default is not _MISSING:
            object.__setattr__(self, "default", default)
        return self

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError("A key cannot be changed.")

    def __delattr__(self, name: str) -> None:
        raise AttributeError("A key cannot be changed.")

    # As a descriptor.

    @overload
    def __get__(self, instance: None, owner: type, /) -> Self: ...
    @overload
    def __get__(self, instance: HasStore, owner: type, /) -> T | None: ...
    def __get__(self, instance: HasStore | None, owner: type, /) -> Self | T | None:
        if instance is None:
            return self
        return instance.store.get(self)

    def __set__(self, instance: HasStore, value: T | None, /) -> None:
        if value is None:
            instance.store.remove(self)
        else:
            instance.store.set(self, value)

    def __delete__(self, instance: HasStore, /) -> None:
        instance.store.remove(self)

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Key):
            return NotImplemented
        return (
            type(self) is type(other)
            and self.name == other.name
            and self.converter is other.converter
        )

    def __hash__(self) -> int:
        return hash((self.name, id(self.converter)))

    def __repr__(self) -> str:
        return f"Key({self.name!r}, {self.converter!r})"

    def __reduce__(self) -> tuple[Any, ...]:
        return (Key, (self.name, self.converter))


class DefaultedKey[T](Key[T]):
    """A `Key` that reads a default in place of `None` when the store has no value.

    `Key(name, type, default=...)` makes one. The default is only read: nothing is written
    to the store until the key is set. Give a defaulted key a default that is not changed in
    place, since every read of a missing key returns the same object.
    """

    __slots__ = ("default",)

    #: What the key reads as while the store has no value for it.
    default: T

    @overload
    def __get__(self, instance: None, owner: type, /) -> Self: ...
    @overload
    def __get__(self, instance: HasStore, owner: type, /) -> T: ...
    def __get__(self, instance: HasStore | None, owner: type, /) -> Self | T:
        if instance is None:
            return self
        return instance.store.get(self)

    def __eq__(self, other: object) -> bool:
        equal = super().__eq__(other)
        if equal is NotImplemented or not equal:
            return equal
        assert isinstance(other, DefaultedKey)
        return bool(self.default == other.default)

    def __hash__(self) -> int:
        return super().__hash__()

    def __repr__(self) -> str:
        return f"Key({self.name!r}, {self.converter!r}, default={self.default!r})"

    def __reduce__(self) -> tuple[Any, ...]:
        return (_restore_defaulted_key, (self.name, self.converter, self.default))


def _restore_defaulted_key(name: str, converter: Converter[Any], default: Any) -> Any:
    return Key(name, converter, default=default)


class Fields:
    """A base for a class whose attributes are keys of one store.

    ::

        class Preferences(Fields):
            username = Key("username", str)
            volume = Key("volume", float, default=0.5)

        preferences = Preferences(store)
        preferences.volume = 0.8
        del preferences.username

    Reading an attribute reads the store, and setting it writes the store, so two instances
    over one store always agree. On the class itself an attribute is the key, for the
    methods that take one: `store.observe(Preferences.volume, on_value)`.

    Any class with a `store` attribute can have keys for attributes. This one only saves
    writing the `__init__`.
    """

    #: The store the keys read and write.
    store: Final[Store]

    def __init__(self, store: Store, /) -> None:
        self.store = store

    def __repr__(self) -> str:
        return f"{type(self).__name__}({self.store!r})"
