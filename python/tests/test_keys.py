"""Typed keys, keys as descriptors, and the store's keys as a collection."""

from __future__ import annotations

import enum
import pickle
import threading
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

import pytest

import swiftmmkv
from swiftmmkv import DefaultedKey, Encryption, Fields, Key, Mode, Store

USERNAME = Key("username", str)
VOLUME = Key("volume", float, default=0.5)
COUNT = Key("count", swiftmmkv.int32)


class Color(enum.IntEnum):
    RED = 1
    GREEN = 2


# MARK: - Making keys


def test_a_key_has_its_name_and_converter() -> None:
    key = Key("count", swiftmmkv.int32)
    assert key.name == "count"
    assert key.converter is swiftmmkv.int32


def test_a_key_of_a_type_has_the_converter_of_the_type() -> None:
    assert Key("count", int).converter is swiftmmkv.int64
    assert Key("volume", float).converter is swiftmmkv.float64


def test_a_key_without_a_default_is_not_a_defaulted_key() -> None:
    key = Key("username", str)
    assert type(key) is Key
    assert not hasattr(key, "default")


def test_a_key_with_a_default_is_a_defaulted_key() -> None:
    key = Key("volume", float, default=0.5)
    assert type(key) is DefaultedKey
    assert isinstance(key, Key)
    assert key.default == 0.5


def test_a_key_may_have_a_default_of_none() -> None:
    key = Key("volume", float, default=None)
    assert type(key) is DefaultedKey
    assert key.default is None


def test_a_defaulted_key_is_made_with_its_class_too() -> None:
    key = DefaultedKey("volume", float, default=0.5)
    assert type(key) is DefaultedKey
    assert key.default == 0.5


def test_a_defaulted_key_needs_a_default() -> None:
    with pytest.raises(TypeError):
        DefaultedKey("volume", float)  # type: ignore[call-overload]


def test_a_key_whose_name_is_not_a_str_raises_type_error() -> None:
    with pytest.raises(TypeError):
        Key(1, int)  # type: ignore[call-overload]


def test_a_key_whose_name_contains_u0000_raises_value_error() -> None:
    with pytest.raises(ValueError):
        Key("a\0b", int)


def test_a_key_of_a_type_with_no_converter_raises_type_error() -> None:
    with pytest.raises(TypeError):
        Key("thing", object)


def test_the_name_and_type_of_a_key_are_positional_only() -> None:
    with pytest.raises(TypeError):
        Key(name="count", type=int)  # type: ignore[call-overload]


# MARK: - Immutability


@pytest.mark.parametrize("attribute", ["name", "converter", "other"])
def test_a_key_cannot_be_changed(attribute: str) -> None:
    with pytest.raises(AttributeError):
        setattr(USERNAME, attribute, "changed")
    assert USERNAME.name == "username"


@pytest.mark.parametrize("attribute", ["name", "converter", "default"])
def test_a_defaulted_key_cannot_be_changed(attribute: str) -> None:
    with pytest.raises(AttributeError):
        setattr(VOLUME, attribute, 1.0)
    assert VOLUME.default == 0.5


@pytest.mark.parametrize("attribute", ["name", "default"])
def test_an_attribute_of_a_key_cannot_be_deleted(attribute: str) -> None:
    with pytest.raises(AttributeError):
        delattr(VOLUME, attribute)
    assert VOLUME.name == "volume"


# MARK: - Equality and hashing


def test_keys_with_the_same_name_and_converter_are_equal() -> None:
    assert Key("count", swiftmmkv.int32) == Key("count", swiftmmkv.int32)


def test_a_type_and_the_converter_it_names_make_equal_keys() -> None:
    assert Key("count", int) == Key("count", swiftmmkv.int64)


def test_keys_with_different_names_are_not_equal() -> None:
    assert Key("count", int) != Key("total", int)


def test_keys_with_different_converters_are_not_equal() -> None:
    assert Key("count", swiftmmkv.int32) != Key("count", swiftmmkv.int64)


def test_keys_with_equal_but_different_converters_are_not_equal() -> None:
    class Converter:
        def read(self, reader: swiftmmkv.Reader) -> None:
            return None

        def write(self, writer: swiftmmkv.Writer, value: object) -> bool:
            return False

    assert Key("thing", Converter()) != Key("thing", Converter())


def test_a_key_and_a_defaulted_key_are_not_equal() -> None:
    assert Key("volume", float) != Key("volume", float, default=0.5)
    assert Key("volume", float, default=0.5) != Key("volume", float)


def test_defaulted_keys_with_equal_defaults_are_equal() -> None:
    assert Key("tags", list[str], default=["a"]) == Key("tags", list[str], default=["a"])


def test_defaulted_keys_with_different_defaults_are_not_equal() -> None:
    assert Key("volume", float, default=0.5) != Key("volume", float, default=1.0)


def test_a_key_is_not_equal_to_its_name() -> None:
    assert Key("count", int) != "count"
    assert "count" != Key("count", int)


def test_equal_keys_have_equal_hashes() -> None:
    assert hash(Key("count", int)) == hash(Key("count", swiftmmkv.int64))
    assert hash(Key("volume", float, default=0.5)) == hash(Key("volume", float, default=0.5))


def test_a_key_finds_an_equal_key_in_a_dict() -> None:
    labels = {Key("count", int): "Count", VOLUME: "Volume"}
    assert labels[Key("count", int)] == "Count"
    assert labels[Key("volume", float, default=0.5)] == "Volume"


def test_a_defaulted_key_with_an_unhashable_default_is_hashable() -> None:
    key = Key("tags", list[str], default=["a"])
    assert hash(key) == hash(Key("tags", list[str], default=["b"]))


# MARK: - repr


def test_a_keys_repr_names_its_name_and_converter() -> None:
    assert repr(Key("count", swiftmmkv.int32)) == "Key('count', swiftmmkv.int32)"


def test_a_defaulted_keys_repr_names_its_default() -> None:
    assert (
        repr(Key("volume", float, default=0.5)) == "Key('volume', swiftmmkv.float64, default=0.5)"
    )


def test_a_keys_repr_names_a_built_in_types_converter() -> None:
    text = repr(Key("username", str))
    assert text.startswith("Key('username', ")
    assert "str" in text


# MARK: - Pickling


@pytest.mark.parametrize(
    "key",
    [
        Key("count", swiftmmkv.int32),
        Key("count", int),
        Key("username", str),
        Key("data", bytes),
        Key("flag", bool),
        Key("names", list[str]),
        Key("count", swiftmmkv.number),
        Key("settings", swiftmmkv.JSON),
    ],
    ids=["int32", "int", "str", "bytes", "bool", "strings", "number", "json"],
)
def test_a_key_survives_pickling(key: Key[object]) -> None:
    copy = pickle.loads(pickle.dumps(key))
    assert copy == key
    assert type(copy) is Key
    assert copy.converter is key.converter


def test_a_defaulted_key_survives_pickling_with_its_default() -> None:
    key = Key("tags", list[str], default=["a", "b"])
    copy = pickle.loads(pickle.dumps(key))
    assert copy == key
    assert type(copy) is DefaultedKey
    assert copy.default == ["a", "b"]


def test_a_key_of_an_enum_survives_pickling() -> None:
    key = Key("color", Color)
    copy = pickle.loads(pickle.dumps(key))
    assert copy == key


def test_a_pickled_key_reads_what_the_original_wrote(store: Store) -> None:
    store[COUNT] = 7
    assert store[pickle.loads(pickle.dumps(COUNT))] == 7


# MARK: - Typed keys and string keys


def test_a_typed_key_reads_what_a_string_key_wrote(store: Store) -> None:
    assert store.set("count", 7, swiftmmkv.int32)
    assert store.get(COUNT) == 7


def test_a_string_key_reads_what_a_typed_key_wrote(store: Store) -> None:
    assert store.set(COUNT, 7)
    assert store.get("count", swiftmmkv.int32) == 7


def test_a_typed_key_writes_in_the_form_its_converter_names(store: Store) -> None:
    assert store.set(Key("count", swiftmmkv.number), 7)
    assert store.get("count", float) == 7.0


def test_a_typed_key_of_a_missing_key_reads_none(store: Store) -> None:
    assert store.get(USERNAME) is None


def test_a_defaulted_key_of_a_missing_key_reads_its_default(store: Store) -> None:
    assert store.get(VOLUME) == 0.5


def test_a_defaulted_key_of_a_stored_value_reads_the_value(store: Store) -> None:
    assert store.set(VOLUME, 0.0)
    assert store.get(VOLUME) == 0.0


def test_a_default_given_to_get_wins_over_the_keys_own(store: Store) -> None:
    assert store.get(VOLUME, default=1.0) == 1.0


def test_a_default_given_to_get_is_used_for_a_plain_key(store: Store) -> None:
    assert store.get(USERNAME, default="nobody") == "nobody"


def test_a_defaulted_key_writes_nothing_until_it_is_set(store: Store) -> None:
    assert store.get(VOLUME) == 0.5
    assert "volume" not in store


def test_a_typed_key_with_a_type_given_to_get_raises_type_error(store: Store) -> None:
    with pytest.raises(TypeError):
        store.get(USERNAME, str)  # type: ignore[call-overload]


def test_a_typed_key_with_a_type_given_to_set_raises_type_error(store: Store) -> None:
    with pytest.raises(TypeError):
        store.set(USERNAME, "blob", str)  # type: ignore[call-overload]
    assert "username" not in store


def test_a_typed_key_refuses_a_value_not_of_its_type(store: Store) -> None:
    with pytest.raises(TypeError):
        store.set(USERNAME, 1)  # type: ignore[arg-type]


# MARK: - Subscripts


def test_a_subscript_reads_a_typed_key(store: Store) -> None:
    assert store.set("username", "blob")
    assert store[USERNAME] == "blob"


def test_a_subscript_writes_a_typed_key(store: Store) -> None:
    store[USERNAME] = "blob"
    assert store.get("username", str) == "blob"


def test_a_subscript_of_a_missing_key_raises_key_error_with_its_name(store: Store) -> None:
    with pytest.raises(KeyError) as caught:
        store[USERNAME]
    assert caught.value.args == ("username",)


def test_a_subscript_of_a_missing_defaulted_key_reads_its_default(store: Store) -> None:
    assert store[VOLUME] == 0.5


def test_a_subscript_reads_a_stored_zero(store: Store) -> None:
    store[COUNT] = 0
    assert store[COUNT] == 0


def test_a_subscript_with_a_str_raises_type_error(store: Store) -> None:
    assert store.set("username", "blob")
    with pytest.raises(TypeError):
        store["username"]  # type: ignore[call-overload]


def test_assigning_to_a_subscript_with_a_str_raises_type_error(store: Store) -> None:
    with pytest.raises(TypeError):
        store["username"] = "blob"  # type: ignore[index]
    assert "username" not in store


def test_assigning_a_refused_write_to_a_subscript_does_not_raise(store: Store) -> None:
    store[Key("", str)] = "blob"
    assert len(store) == 0


def test_deleting_a_subscript_removes_a_typed_key(store: Store) -> None:
    store[USERNAME] = "blob"
    del store[USERNAME]
    assert "username" not in store


def test_deleting_a_subscript_removes_a_string_key(store: Store) -> None:
    store[USERNAME] = "blob"
    del store["username"]
    assert "username" not in store


def test_deleting_a_missing_key_is_not_an_error(store: Store) -> None:
    del store["missing"]
    del store[USERNAME]
    assert len(store) == 0


# MARK: - Keys as descriptors


class Preferences(Fields):
    username = Key("username", str)
    volume = Key("volume", float, default=0.5)
    count = Key("count", swiftmmkv.int32)


@dataclass
class Session:
    """Not a `Fields`, but it has a `store`."""

    store: Store
    token = Key("token", str)


def test_a_field_reads_the_store(store: Store) -> None:
    assert store.set("username", "blob")
    assert Preferences(store).username == "blob"


def test_a_field_of_a_missing_key_reads_none(store: Store) -> None:
    assert Preferences(store).username is None


def test_a_defaulted_field_of_a_missing_key_reads_its_default(store: Store) -> None:
    assert Preferences(store).volume == 0.5


def test_setting_a_field_writes_the_store(store: Store) -> None:
    Preferences(store).count = 3
    assert store.get("count", swiftmmkv.int32) == 3


def test_setting_a_field_to_none_removes_its_key(store: Store) -> None:
    preferences = Preferences(store)
    preferences.username = "blob"
    preferences.username = None
    assert "username" not in store
    assert preferences.username is None


def test_setting_a_defaulted_field_to_none_brings_back_its_default(store: Store) -> None:
    preferences = Preferences(store)
    preferences.volume = 0.8
    preferences.volume = None
    assert preferences.volume == 0.5


def test_deleting_a_field_removes_its_key(store: Store) -> None:
    preferences = Preferences(store)
    preferences.username = "blob"
    del preferences.username
    assert "username" not in store


def test_deleting_a_field_of_a_missing_key_is_not_an_error(store: Store) -> None:
    del Preferences(store).username
    assert len(store) == 0


def test_setting_a_field_to_a_value_not_of_its_type_raises_type_error(store: Store) -> None:
    with pytest.raises(TypeError):
        Preferences(store).count = "three"  # type: ignore[assignment]


def test_two_instances_over_one_store_agree(store: Store) -> None:
    first, second = Preferences(store), Preferences(store)
    first.username = "blob"
    assert second.username == "blob"


def test_a_field_on_the_class_is_its_key() -> None:
    assert Preferences.username is Preferences.__dict__["username"]
    assert Preferences.username == Key("username", str)
    assert Preferences.volume == Key("volume", float, default=0.5)


def test_a_field_on_the_class_can_be_given_to_the_store(store: Store) -> None:
    store[Preferences.count] = 9
    assert Preferences(store).count == 9


def test_fields_have_a_repr_naming_their_class_and_store(store: Store) -> None:
    assert repr(Preferences(store)) == f"Preferences({store!r})"


def test_fields_keep_their_store(store: Store) -> None:
    assert Preferences(store).store is store


def test_a_key_is_a_field_of_any_class_with_a_store(store: Store) -> None:
    session = Session(store)
    session.token = "abc"
    assert store.get("token", str) == "abc"
    assert session.token == "abc"
    del session.token
    assert session.token is None
    assert Session.token == Key("token", str)


def test_a_key_is_a_field_of_a_class_whose_store_is_a_property(store: Store) -> None:
    class Account:
        name = Key("name", str)

        def __init__(self, store: Store) -> None:
            self._store = store

        @property
        def store(self) -> Store:
            return self._store

    account = Account(store)
    account.name = "blob"
    assert account.name == "blob"
    account.name = None
    assert "name" not in store


# MARK: - Collection protocols


def test_in_finds_a_string_key(store: Store) -> None:
    assert store.set("username", "blob")
    assert "username" in store
    assert "missing" not in store


def test_in_finds_a_typed_key(store: Store) -> None:
    assert store.set("username", "blob")
    assert USERNAME in store
    assert COUNT not in store


def test_in_finds_a_stored_zero_or_empty_value(store: Store) -> None:
    assert store.set("count", 0)
    assert store.set("name", "")
    assert "count" in store
    assert "name" in store


@pytest.mark.parametrize("key", [1, None, b"username", ("username",)])
def test_in_is_false_for_what_is_not_a_key(store: Store, key: object) -> None:
    assert store.set("username", "blob")
    assert key not in store


def test_a_defaulted_key_of_a_missing_key_is_not_in_the_store(store: Store) -> None:
    assert VOLUME not in store


def test_len_counts_the_keys(store: Store) -> None:
    assert len(store) == 0
    for key in ["a", "b", "c"]:
        assert store.set(key, 1)
    assert len(store) == 3


def test_len_counts_a_key_written_twice_once(store: Store) -> None:
    assert store.set("a", 1)
    assert store.set("a", 2)
    assert len(store) == 1


def test_iteration_yields_every_key_once(store: Store) -> None:
    for key in ["a", "b", "c"]:
        assert store.set(key, 1)
    keys = list(store)
    assert sorted(keys) == ["a", "b", "c"]


def test_iteration_of_an_empty_store_yields_nothing(store: Store) -> None:
    assert list(store) == []


def test_iteration_may_remove_the_keys_it_yields(store: Store) -> None:
    for key in ["a", "b", "c"]:
        assert store.set(key, 1)
    for key in store:
        store.remove(key)
    assert len(store) == 0


def test_keys_is_a_frozenset_of_every_key(store: Store) -> None:
    for key in ["a", "b", "ç✓"]:
        assert store.set(key, 1)
    keys = store.keys()
    assert type(keys) is frozenset
    assert keys == {"a", "b", "ç✓"}


def test_keys_is_a_copy_that_later_changes_leave_alone(store: Store) -> None:
    assert store.set("a", 1)
    keys = store.keys()
    assert store.set("b", 1)
    assert store.remove("a")
    assert keys == {"a"}


def test_keys_of_an_empty_store_is_empty(store: Store) -> None:
    assert store.keys() == frozenset()


def test_keys_lists_more_keys_than_fit_in_one_read(store: Store) -> None:
    names = {f"key-number-{i}" for i in range(500)}
    for name in names:
        assert store.set(name, True)
    assert store.keys() == names
    assert len(store) == 500


@pytest.fixture
def settings(store: Store) -> Store:
    for key in ["settings", "settings.theme", "settings.sync.isEnabled", "settingsTheme", "user"]:
        assert store.set(key, True)
    return store


def test_keys_under_a_prefix_are_the_prefix_and_the_keys_after_its_separator(
    settings: Store,
) -> None:
    assert settings.keys(under="settings") == {
        "settings",
        "settings.theme",
        "settings.sync.isEnabled",
    }


def test_keys_under_a_nested_prefix(settings: Store) -> None:
    assert settings.keys(under="settings.sync") == {"settings.sync.isEnabled"}


def test_keys_under_a_prefix_with_no_keys_is_empty(settings: Store) -> None:
    assert settings.keys(under="missing") == frozenset()


def test_every_key_is_under_an_empty_prefix(settings: Store) -> None:
    assert settings.keys(under="") == settings.keys()


def test_keys_under_a_prefix_without_the_prefix_itself(store: Store) -> None:
    assert store.set("settings.theme", "dark")
    assert store.keys(under="settings") == {"settings.theme"}


def test_keys_under_a_prefix_take_another_separator(store: Store) -> None:
    for key in ["settings/theme", "settings.theme", "settings/sync/isEnabled"]:
        assert store.set(key, True)
    assert store.keys(under="settings", separator="/") == {
        "settings/theme",
        "settings/sync/isEnabled",
    }


def test_keys_under_a_prefix_take_a_separator_of_several_characters(store: Store) -> None:
    for key in ["a::b", "a:b", "a::c::d"]:
        assert store.set(key, True)
    assert store.keys(under="a", separator="::") == {"a::b", "a::c::d"}


def test_keys_under_a_prefix_containing_u0000_raises_value_error(store: Store) -> None:
    with pytest.raises(ValueError):
        store.keys(under="a\0b")


def test_keys_under_lists_more_keys_than_fit_in_one_read(store: Store) -> None:
    names = {f"group.key-number-{i}" for i in range(300)}
    for name in names:
        assert store.set(name, True)
    assert store.set("other", True)
    assert store.keys(under="group") == names


# MARK: - Removal


def test_remove_removes_a_key_and_reports_it(store: Store) -> None:
    assert store.set("a", 1)
    assert store.remove("a") is True
    assert "a" not in store


def test_remove_reports_that_a_key_with_no_value_had_none(store: Store) -> None:
    assert store.remove("missing") is False


def test_remove_takes_a_typed_key(store: Store) -> None:
    store[USERNAME] = "blob"
    assert store.remove(USERNAME)
    assert USERNAME not in store


def test_remove_leaves_other_keys_alone(store: Store) -> None:
    assert store.set("a", 1)
    assert store.set("b", 2)
    assert store.remove("a")
    assert store.get("b", int) == 2


def test_remove_refuses_what_is_not_a_key(store: Store) -> None:
    with pytest.raises(TypeError):
        store.remove(1)  # type: ignore[arg-type]


def test_remove_many_removes_each_key(store: Store) -> None:
    for key in ["a", "b", "c", "d"]:
        assert store.set(key, 1)
    store.remove_many(["b", "c", "missing"])
    assert store.keys() == {"a", "d"}


def test_remove_many_takes_typed_keys_and_string_keys(store: Store) -> None:
    store[USERNAME] = "blob"
    store[COUNT] = 1
    assert store.set("other", 1)
    store.remove_many([USERNAME, "count"])
    assert store.keys() == {"other"}


def test_remove_many_takes_any_iterable(store: Store) -> None:
    for key in ["a", "b"]:
        assert store.set(key, 1)
    store.remove_many(key for key in ["a", "b"])
    assert len(store) == 0


def test_remove_many_of_nothing_removes_nothing(store: Store) -> None:
    assert store.set("a", 1)
    store.remove_many([])
    assert store.keys() == {"a"}


def test_remove_many_takes_what_keys_returned(store: Store) -> None:
    for key in ["a", "b", "c"]:
        assert store.set(key, 1)
    store.remove_many(store.keys())
    assert len(store) == 0


@pytest.mark.parametrize("keys", ["ab", USERNAME], ids=["str", "key"])
def test_remove_many_refuses_one_key(store: Store, keys: object) -> None:
    assert store.set("a", 1)
    with pytest.raises(TypeError):
        store.remove_many(keys)  # type: ignore[arg-type]
    assert store.keys() == {"a"}


def test_remove_many_with_a_key_containing_u0000_raises_value_error(store: Store) -> None:
    assert store.set("a", 1)
    with pytest.raises(ValueError):
        store.remove_many(["a", "b\0"])
    assert "a" in store


def test_remove_under_removes_the_prefix_and_the_keys_under_it(settings: Store) -> None:
    settings.remove_under("settings")
    assert settings.keys() == {"settingsTheme", "user"}


def test_remove_under_takes_another_separator(store: Store) -> None:
    for key in ["settings/theme", "settings.theme", "settings/sync/isEnabled"]:
        assert store.set(key, True)
    store.remove_under("settings", separator="/")
    assert store.keys() == {"settings.theme"}


def test_remove_under_removes_what_keys_under_lists(settings: Store) -> None:
    listed = settings.keys(under="settings")
    before = settings.keys()
    settings.remove_under("settings")
    assert settings.keys() == before - listed


def test_remove_under_a_prefix_with_no_keys_removes_nothing(settings: Store) -> None:
    before = settings.keys()
    settings.remove_under("missing")
    assert settings.keys() == before


def test_clear_removes_every_key(store: Store) -> None:
    for key in ["a", "b", "c"]:
        assert store.set(key, 1)
    store.clear()
    assert len(store) == 0
    assert store.keys() == frozenset()


def test_a_store_takes_writes_after_it_is_cleared(store: Store) -> None:
    assert store.set("a", 1)
    store.clear()
    assert store.set("a", 2)
    assert store.get("a", int) == 2


def grow(store: Store) -> int:
    """Grows the store's file past its initial size, and returns its size."""
    initial = store.byte_size
    for i in range(100):
        assert store.set(f"key-{i}", b"x" * 1000)
    assert store.byte_size > initial
    return store.byte_size


def test_clear_shrinks_the_file_back_to_its_initial_size(store: Store) -> None:
    assert store.set("a", 1)
    initial = store.byte_size
    grow(store)
    store.clear()
    assert store.byte_size == initial


def test_clear_keeping_capacity_keeps_the_files_size(store: Store) -> None:
    grown = grow(store)
    store.clear(keep_capacity=True)
    assert len(store) == 0
    assert store.byte_size == grown


@pytest.fixture
def other_store() -> Iterator[Store]:
    store = swiftmmkv.open_temporary(id="other")
    yield store
    store.close()
    store.directory.remove_all_stores()


def test_import_all_copies_every_key_and_value(store: Store, other_store: Store) -> None:
    assert other_store.set("a", "from source")
    assert other_store.set("b", 2, swiftmmkv.int32)
    assert store.import_all(other_store) == 2
    assert store.get("a", str) == "from source"
    assert store.get("b", swiftmmkv.int32) == 2


def test_import_all_replaces_the_keys_the_store_has(store: Store, other_store: Store) -> None:
    assert other_store.set("a", "from source")
    assert other_store.set("b", "from source")
    assert store.set("b", "from destination")
    assert store.set("c", "from destination")
    assert store.import_all(other_store) == 2
    assert store.keys() == {"a", "b", "c"}
    assert store.get("b", str) == "from source"
    assert store.get("c", str) == "from destination"


def test_import_all_leaves_the_source_alone(store: Store, other_store: Store) -> None:
    assert other_store.set("a", 1)
    store.import_all(other_store)
    assert other_store.keys() == {"a"}


def test_import_all_of_an_empty_store_copies_nothing(store: Store, other_store: Store) -> None:
    assert store.set("a", 1)
    assert store.import_all(other_store) == 0
    assert store.keys() == {"a"}


def test_import_all_copies_across_modes_and_encryption(store: Store, tmp_path: Path) -> None:
    with swiftmmkv.open(
        tmp_path, mode=Mode.MULTI_PROCESS, encryption=Encryption.aes256("secret")
    ) as source:
        assert source.set("a", "secret value")
        assert store.import_all(source) == 1
    assert store.get("a", str) == "secret value"


def test_import_all_refuses_what_is_not_a_store(store: Store) -> None:
    with pytest.raises(TypeError):
        store.import_all({"a": 1})  # type: ignore[arg-type]


# MARK: - Batches


def test_set_many_stores_every_value(store: Store) -> None:
    assert store.set_many({"score.1": 10.0, "name": "blob", "flag": True}) is True
    assert store.get("score.1", float) == 10.0
    assert store.get("name", str) == "blob"
    assert store.get("flag", bool) is True


def test_set_many_of_nothing_reports_success(store: Store) -> None:
    assert store.set_many({}) is True
    assert len(store) == 0


def test_set_many_stores_every_value_as_the_type_named(store: Store) -> None:
    assert store.set_many({"a": 1, "b": 2}, swiftmmkv.number) is True
    assert store.get("a", float) == 1.0
    assert store.get("b", float) == 2.0


def test_set_many_reports_false_when_one_write_is_refused_and_stores_the_rest(
    store: Store,
) -> None:
    assert store.set_many({"": 1, "ok": 2}) is False
    assert store.keys() == {"ok"}


def test_set_many_raises_for_a_bad_value_and_keeps_what_it_wrote(store: Store) -> None:
    with pytest.raises(TypeError):
        store.set_many({"a": 1, "b": "two"}, int)
    assert store.get("a", int) == 1
    assert "b" not in store


def test_set_many_gives_up_the_lock_when_it_raises(store: Store) -> None:
    with pytest.raises(TypeError):
        store.set_many({"a": object()})
    written: list[bool] = []
    thread = threading.Thread(target=lambda: written.append(store.set("b", 1)))
    thread.start()
    thread.join(timeout=10)
    assert not thread.is_alive()
    assert written == [True]


def test_get_many_reads_each_key_as_the_type_named(store: Store) -> None:
    assert store.set_many({"score.1": 10.0, "score.2": 12.5})
    assert store.get_many(["score.1", "score.2"], float) == {"score.1": 10.0, "score.2": 12.5}


def test_get_many_leaves_out_a_key_with_no_value(store: Store) -> None:
    assert store.set("a", 1)
    assert store.get_many(["a", "missing"], int) == {"a": 1}


def test_get_many_keeps_a_stored_zero(store: Store) -> None:
    assert store.set("a", 0)
    assert store.get_many(["a"], int) == {"a": 0}


def test_get_many_of_no_keys_is_empty(store: Store) -> None:
    assert store.get_many([], str) == {}


def test_get_many_takes_any_iterable(store: Store) -> None:
    assert store.set("a", "x")
    assert store.get_many(iter(["a"]), str) == {"a": "x"}


def test_get_many_reads_with_a_converter(store: Store) -> None:
    assert store.set("color", Color.GREEN)
    assert store.set("bad", 99)
    assert store.get_many(["color", "bad"], Color) == {"color": Color.GREEN}
