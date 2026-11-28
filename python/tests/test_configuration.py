"""Opening a store, and each option it is opened with."""

from __future__ import annotations

import dataclasses
import mmap
import os
from collections.abc import Callable, Iterator
from pathlib import Path

import pytest

import swiftmmkv
from swiftmmkv import (
    Cipher,
    Configuration,
    Directory,
    Encryption,
    FileProtection,
    MMKVError,
    Mode,
    Recovery,
    Status,
    Store,
    StoreID,
)

type Closing = Callable[[Store], Store]


@pytest.fixture
def closing() -> Iterator[Closing]:
    """Registers a store to be closed, and its directory's stores removed, after the test."""
    stores: list[Store] = []

    def register(store: Store) -> Store:
        stores.append(store)
        return store

    yield register
    for store in stores:
        store.close()
    for store in stores:
        store.directory.remove_all_stores()


def file_bytes(path: Path) -> bytes:
    with path.open("rb") as file:
        return file.read()


# MARK: - Opening


def test_opens_a_store_with_keyword_arguments(tmp_path: Path, closing: Closing) -> None:
    store = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS))
    assert store.set("name", "blob")
    assert store.get("name", str) == "blob"


def test_opens_a_store_with_a_configuration(tmp_path: Path, closing: Closing) -> None:
    configuration = Configuration(directory=tmp_path, mode=Mode.SINGLE_PROCESS)
    store = closing(swiftmmkv.open(configuration))
    assert store.set("name", "blob")
    assert store.get("name", str) == "blob"


def test_a_store_keeps_the_configuration_it_was_opened_with(
    tmp_path: Path, closing: Closing
) -> None:
    configuration = Configuration(directory=tmp_path, mode=Mode.SINGLE_PROCESS, id="session")
    store = closing(swiftmmkv.open(configuration))
    assert store.configuration is configuration


def test_keyword_arguments_make_the_configuration_of_their_fields(
    tmp_path: Path, closing: Closing
) -> None:
    store = closing(
        swiftmmkv.open(tmp_path, mode=Mode.MULTI_PROCESS, id="session", compare_before_set=True)
    )
    assert store.configuration == Configuration(
        directory=tmp_path, mode=Mode.MULTI_PROCESS, id="session", compare_before_set=True
    )


def test_a_configuration_and_keyword_arguments_together_raise_type_error(
    tmp_path: Path,
) -> None:
    configuration = Configuration(directory=tmp_path, mode=Mode.SINGLE_PROCESS)
    with pytest.raises(TypeError):
        swiftmmkv.open(configuration, mode=Mode.SINGLE_PROCESS)  # type: ignore[call-overload]


def test_open_without_a_mode_raises_type_error(tmp_path: Path) -> None:
    with pytest.raises(TypeError):
        swiftmmkv.open(tmp_path)  # type: ignore[call-overload]


def test_a_configuration_without_a_mode_raises_type_error(tmp_path: Path) -> None:
    with pytest.raises(TypeError):
        Configuration(directory=tmp_path)  # type: ignore[call-arg]


def test_a_configuration_takes_keyword_arguments_only(tmp_path: Path) -> None:
    with pytest.raises(TypeError):
        Configuration(tmp_path, Mode.SINGLE_PROCESS)  # type: ignore[misc]


def test_an_unknown_keyword_argument_raises_type_error(tmp_path: Path) -> None:
    with pytest.raises(TypeError):
        swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, colour="blue")  # type: ignore[call-overload]


@pytest.mark.parametrize("mode", list(Mode))
def test_a_store_opens_in_each_mode(tmp_path: Path, closing: Closing, mode: Mode) -> None:
    store = closing(swiftmmkv.open(tmp_path, mode=mode))
    assert store.set("name", "blob")
    assert store.get("name", str) == "blob"


def test_an_unknown_mode_fails_the_open_with_invalid_argument(tmp_path: Path) -> None:
    with pytest.raises(MMKVError) as caught:
        swiftmmkv.open(tmp_path, mode=99)  # type: ignore[call-overload]
    assert caught.value.status is Status.INVALID_ARGUMENT


def test_open_creates_a_directory_that_does_not_exist(tmp_path: Path, closing: Closing) -> None:
    directory = tmp_path / "a" / "b"
    closing(swiftmmkv.open(directory, mode=Mode.SINGLE_PROCESS))
    assert directory.is_dir()


def test_open_takes_a_directory_as_a_str(tmp_path: Path, closing: Closing) -> None:
    store = closing(swiftmmkv.open(str(tmp_path), mode=Mode.SINGLE_PROCESS))
    assert store.directory == Directory(tmp_path)


def test_open_takes_a_directory_object(tmp_path: Path, closing: Closing) -> None:
    store = closing(swiftmmkv.open(Directory(tmp_path), mode=Mode.SINGLE_PROCESS))
    assert store.directory == Directory(tmp_path)


def test_an_empty_directory_fails_the_open() -> None:
    with pytest.raises(MMKVError) as caught:
        swiftmmkv.open("", mode=Mode.SINGLE_PROCESS)
    assert caught.value.status is Status.OPEN_FAILED


def test_a_directory_containing_u0000_raises_value_error(tmp_path: Path) -> None:
    with pytest.raises(ValueError):
        swiftmmkv.open(f"{tmp_path}/a\0b", mode=Mode.SINGLE_PROCESS)


# MARK: - Two stores over the same files


def test_two_stores_over_the_same_files_share_their_contents(
    tmp_path: Path, closing: Closing
) -> None:
    first = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="shared"))
    second = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="shared"))
    assert first is not second
    assert first.set("name", "blob")
    assert second.get("name", str) == "blob"
    assert second.remove("name")
    assert first.get("name", str) is None


def test_the_configuration_of_the_first_store_over_some_files_wins(
    tmp_path: Path, closing: Closing
) -> None:
    first = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="shared"))
    second = closing(
        swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="shared", read_only=True)
    )
    assert second.set("name", "blob") is True
    assert first.get("name", str) == "blob"


def test_a_store_reopened_after_closing_reads_what_was_written(tmp_path: Path) -> None:
    with swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS) as store:
        assert store.set("name", "blob")
    with swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS) as store:
        assert store.get("name", str) == "blob"


# MARK: - Identifiers


def test_a_store_is_named_by_its_identifier_in_its_directory(
    tmp_path: Path, closing: Closing
) -> None:
    store = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="session"))
    assert store.set("name", "blob")
    assert (tmp_path / "session").is_file()
    assert Directory(tmp_path).contains_store("session")


def test_a_store_without_an_identifier_is_the_default_one(tmp_path: Path, closing: Closing) -> None:
    store = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS))
    assert store.id == StoreID.DEFAULT
    assert (tmp_path / "mmkv.default").is_file()


def test_stores_with_different_identifiers_are_separate(tmp_path: Path, closing: Closing) -> None:
    first = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="first"))
    second = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="second"))
    assert first.set("name", "blob")
    assert second.get("name", str) is None


def test_the_id_of_a_store_is_a_store_id(tmp_path: Path, closing: Closing) -> None:
    store = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="session"))
    assert store.id == "session"
    assert type(store.id) is StoreID


def test_an_empty_identifier_fails_the_open(tmp_path: Path) -> None:
    with pytest.raises(MMKVError) as caught:
        swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="")
    assert caught.value.status is Status.OPEN_FAILED


def test_an_identifier_containing_u0000_raises_value_error(tmp_path: Path) -> None:
    with pytest.raises(ValueError):
        swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="a\0b")


def test_store_id_is_a_str() -> None:
    session = StoreID("session")
    assert isinstance(session, str)
    assert session == "session"
    assert hash(session) == hash("session")


def test_store_id_default_is_mmkv_default() -> None:
    assert StoreID.DEFAULT == "mmkv.default"
    assert type(StoreID.DEFAULT) is StoreID


def test_store_id_repr_names_its_type() -> None:
    assert repr(StoreID("session")) == "StoreID('session')"


def test_store_id_str_is_the_plain_identifier() -> None:
    assert str(StoreID("session")) == "session"
    assert f"{StoreID('session')}" == "session"


@pytest.mark.parametrize("value", [1, b"session", None], ids=["int", "bytes", "none"])
def test_store_id_refuses_what_is_not_a_str(value: object) -> None:
    with pytest.raises(TypeError):
        StoreID(value)  # type: ignore[arg-type]


# MARK: - Directories


def test_a_store_reports_its_directory(tmp_path: Path, closing: Closing) -> None:
    store = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS))
    assert isinstance(store.directory, Directory)
    assert os.fspath(store.directory) == str(tmp_path)


def test_directory_temporary_names_a_new_directory_each_time() -> None:
    first, second = Directory.temporary(), Directory.temporary()
    assert isinstance(first, Directory)
    assert first != second


def test_a_store_opens_in_a_temporary_directory(closing: Closing) -> None:
    store = closing(Directory.temporary().open(mode=Mode.SINGLE_PROCESS))
    assert store.set("name", "blob")
    assert store.get("name", str) == "blob"


def test_configuration_temporary_is_a_single_process_default_store() -> None:
    configuration = Configuration.temporary()
    assert configuration.mode is Mode.SINGLE_PROCESS
    assert configuration.id == StoreID.DEFAULT
    assert configuration.read_only is False
    assert configuration.encryption is None


def test_configuration_temporary_names_a_new_directory_each_time() -> None:
    assert Configuration.temporary().directory != Configuration.temporary().directory


def test_configuration_temporary_takes_an_identifier() -> None:
    assert Configuration.temporary(id="session").id == "session"


def test_open_temporary_opens_an_empty_store(closing: Closing) -> None:
    store = closing(swiftmmkv.open_temporary())
    assert len(store) == 0
    assert store.configuration.mode is Mode.SINGLE_PROCESS


def test_each_temporary_store_is_separate(closing: Closing) -> None:
    first = closing(swiftmmkv.open_temporary())
    second = closing(swiftmmkv.open_temporary())
    assert first.set("name", "blob")
    assert second.get("name", str) is None
    assert first.directory != second.directory


def test_open_temporary_takes_an_identifier(closing: Closing) -> None:
    store = closing(swiftmmkv.open_temporary(id="session"))
    assert store.id == "session"


# MARK: - Read-only


def test_a_read_only_store_reads_but_does_not_write(tmp_path: Path) -> None:
    with swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="frozen") as store:
        assert store.set("name", "blob")
    with swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="frozen", read_only=True) as store:
        assert store.get("name", str) == "blob"
        assert store.set("name", "changed") is False
        assert store.set("other", 1) is False
        assert store.get("name", str) == "blob"
        assert "other" not in store


def test_a_read_only_store_leaves_its_file_alone(tmp_path: Path) -> None:
    with swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="frozen") as store:
        assert store.set("name", "blob")
    before = file_bytes(tmp_path / "frozen")
    with swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="frozen", read_only=True) as store:
        store.set("name", "changed")
    assert file_bytes(tmp_path / "frozen") == before


# MARK: - Encryption


def test_an_encrypted_store_keeps_its_values_out_of_its_file(tmp_path: Path) -> None:
    marker = "plain-text-marker"
    with swiftmmkv.open(
        tmp_path, mode=Mode.SINGLE_PROCESS, id="secret", encryption=Encryption.aes256("key")
    ) as store:
        assert store.set("name", marker)
        assert store.get("name", str) == marker
        store.sync()
    assert marker.encode() not in file_bytes(tmp_path / "secret")


def test_a_plain_store_keeps_its_values_in_its_file(tmp_path: Path) -> None:
    marker = "plain-text-marker"
    with swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="plain") as store:
        assert store.set("name", marker)
        store.sync()
    assert marker.encode() in file_bytes(tmp_path / "plain")


@pytest.mark.parametrize("cipher", list(Cipher))
def test_an_encrypted_store_reopened_with_its_key_reads_its_values(
    tmp_path: Path, cipher: Cipher
) -> None:
    encryption = Encryption(cipher, b"secret")
    with swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, encryption=encryption) as store:
        assert store.set("name", "blob")
    with swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, encryption=encryption) as store:
        assert store.get("name", str) == "blob"


@pytest.mark.parametrize(
    "encryption",
    [
        Encryption.aes128(b"k" * 17),
        Encryption.aes256(b"k" * 33),
        Encryption.aes128(b""),
        Encryption.aes256(""),
        Encryption.aes128("ç" * 9),
    ],
    ids=["aes128-too-long", "aes256-too-long", "aes128-empty", "aes256-empty", "aes128-utf8"],
)
def test_a_key_of_the_wrong_length_fails_the_open(tmp_path: Path, encryption: Encryption) -> None:
    with pytest.raises(MMKVError) as caught:
        swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, encryption=encryption)
    assert caught.value.status is Status.INVALID_ENCRYPTION_KEY
    assert caught.value.code == Status.INVALID_ENCRYPTION_KEY


@pytest.mark.parametrize(
    "encryption",
    [Encryption.aes128(b"k" * 16), Encryption.aes256(b"k" * 32), Encryption.aes128(b"k")],
    ids=["aes128-longest", "aes256-longest", "shortest"],
)
def test_a_key_of_a_length_its_cipher_allows_opens(
    tmp_path: Path, closing: Closing, encryption: Encryption
) -> None:
    store = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, encryption=encryption))
    assert store.set("name", "blob")


def test_an_unknown_cipher_fails_the_open_with_invalid_argument(tmp_path: Path) -> None:
    encryption = Encryption(99, b"secret")  # type: ignore[arg-type]
    with pytest.raises(MMKVError) as caught:
        swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, encryption=encryption)
    assert caught.value.status is Status.INVALID_ARGUMENT


def test_encryption_repr_leaves_out_the_key() -> None:
    encryption = Encryption.aes256("hunter2")
    assert "hunter2" not in repr(encryption)
    assert repr(encryption) == "Encryption(cipher=<Cipher.AES256: 2>)"


def test_an_encryption_key_given_as_a_str_is_its_utf8() -> None:
    assert Encryption.aes128("ç✓").key == "ç✓".encode()


def test_an_encryption_key_given_as_a_bytearray_is_bytes() -> None:
    key = Encryption.aes256(bytearray(b"secret")).key  # type: ignore[arg-type]
    assert key == b"secret"
    assert type(key) is bytes


def test_the_class_methods_choose_their_cipher() -> None:
    assert Encryption.aes128(b"k").cipher is Cipher.AES128
    assert Encryption.aes256(b"k").cipher is Cipher.AES256


def test_encryptions_are_equal_when_their_cipher_and_key_are() -> None:
    assert Encryption.aes256("key") == Encryption(Cipher.AES256, b"key")
    assert Encryption.aes256("key") != Encryption.aes128("key")
    assert Encryption.aes256("key") != Encryption.aes256("other")


def test_an_encryption_cannot_be_changed() -> None:
    encryption = Encryption.aes256("key")
    with pytest.raises(dataclasses.FrozenInstanceError):
        encryption.key = b"other"  # type: ignore[misc]


# MARK: - Sizes


def test_the_expected_capacity_sizes_the_file(tmp_path: Path, closing: Closing) -> None:
    store = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, expected_capacity=1 << 20))
    assert store.set("flag", True)
    assert store.byte_size >= 1 << 20


def test_an_expected_capacity_of_zero_uses_one_memory_page(
    tmp_path: Path, closing: Closing
) -> None:
    store = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS))
    assert store.set("flag", True)
    assert store.byte_size == mmap.PAGESIZE


@pytest.mark.parametrize("field", ["expected_capacity", "item_size_limit"])
def test_a_negative_size_raises_overflow_error(tmp_path: Path, field: str) -> None:
    with pytest.raises(OverflowError):
        swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, **{field: -1})


@pytest.mark.parametrize("field", ["expected_capacity", "item_size_limit"])
@pytest.mark.parametrize("value", [1.5, "64", True], ids=["float", "str", "bool"])
def test_a_size_that_is_not_an_int_raises_type_error(
    tmp_path: Path, field: str, value: object
) -> None:
    with pytest.raises(TypeError):
        swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, **{field: value})


def test_the_item_size_limit_turns_large_values_away(tmp_path: Path, closing: Closing) -> None:
    store = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, item_size_limit=64))
    assert store.set("small", "value") is True
    assert store.set("large", "x" * 256) is False
    assert "small" in store
    assert "large" not in store


def test_no_item_size_limit_takes_large_values(tmp_path: Path, closing: Closing) -> None:
    store = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, item_size_limit=None))
    assert store.set("large", b"x" * 100_000) is True
    assert store.value_size("large") == 100_000


# MARK: - Compare before set


@pytest.mark.parametrize("value", ["value", b"y" * 300], ids=["str", "bytes"])
def test_compare_before_set_skips_a_write_of_the_value_already_held(
    tmp_path: Path, closing: Closing, value: object
) -> None:
    store = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, compare_before_set=True))
    assert store.set("other", 1)
    assert store.set("key", value)
    used = store.used_byte_size
    for _ in range(20):
        assert store.set("key", value)
    assert store.used_byte_size == used


def test_without_compare_before_set_a_repeated_write_grows_the_file(
    tmp_path: Path, closing: Closing
) -> None:
    store = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS))
    assert store.set("other", 1)
    assert store.set("key", "value")
    used = store.used_byte_size
    for _ in range(20):
        assert store.set("key", "value")
    assert store.used_byte_size > used


def test_compare_before_set_still_takes_a_different_value(tmp_path: Path, closing: Closing) -> None:
    store = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, compare_before_set=True))
    assert store.set("key", "value")
    assert store.set("key", "changed")
    assert store.get("key", str) == "changed"


# MARK: - Recovery and file protection


@pytest.mark.parametrize("recovery", list(Recovery))
def test_a_store_opens_with_each_recovery(
    tmp_path: Path, closing: Closing, recovery: Recovery
) -> None:
    store = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, recovery=recovery))
    assert store.configuration.recovery is recovery
    assert store.set("name", "blob")
    assert store.get("name", str) == "blob"


def test_an_unknown_recovery_fails_the_open_with_invalid_argument(tmp_path: Path) -> None:
    with pytest.raises(MMKVError) as caught:
        swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, recovery=99)  # type: ignore[call-overload]
    assert caught.value.status is Status.INVALID_ARGUMENT


@pytest.mark.parametrize("protection", list(FileProtection))
def test_a_store_opens_with_each_file_protection(
    tmp_path: Path, closing: Closing, protection: FileProtection
) -> None:
    store = closing(swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, file_protection=protection))
    assert store.configuration.file_protection is protection
    assert store.set("name", "blob")
    assert store.get("name", str) == "blob"


def test_an_unknown_file_protection_fails_the_open_with_invalid_argument(
    tmp_path: Path,
) -> None:
    with pytest.raises(MMKVError) as caught:
        swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, file_protection=99)  # type: ignore[call-overload]
    assert caught.value.status is Status.INVALID_ARGUMENT


# MARK: - Configurations as values


def test_a_configuration_has_the_defaults_it_documents(tmp_path: Path) -> None:
    configuration = Configuration(directory=tmp_path, mode=Mode.SINGLE_PROCESS)
    assert configuration.id == StoreID.DEFAULT
    assert configuration.read_only is False
    assert configuration.encryption is None
    assert configuration.expected_capacity == 0
    assert configuration.recovery is Recovery.DISCARD
    assert configuration.compare_before_set is False
    assert configuration.item_size_limit is None
    assert configuration.file_protection is FileProtection.COMPLETE_UNTIL_FIRST_USER_AUTHENTICATION
    assert configuration.default_expiry == swiftmmkv.Expiry.NEVER


def test_a_configuration_cannot_be_changed(tmp_path: Path) -> None:
    configuration = Configuration(directory=tmp_path, mode=Mode.SINGLE_PROCESS)
    with pytest.raises(dataclasses.FrozenInstanceError):
        configuration.read_only = True  # type: ignore[misc]


def test_a_configuration_checks_nothing_until_it_is_opened(tmp_path: Path) -> None:
    configuration = Configuration(directory=tmp_path, mode=99, id="")  # type: ignore[arg-type]
    with pytest.raises(MMKVError):
        swiftmmkv.open(configuration)


def test_replace_makes_a_configuration_that_differs_in_some_fields(tmp_path: Path) -> None:
    configuration = Configuration(directory=tmp_path, mode=Mode.SINGLE_PROCESS, id="first")
    replaced = dataclasses.replace(configuration, id="second", read_only=True)
    assert replaced.id == "second"
    assert replaced.read_only is True
    assert replaced.directory == configuration.directory
    assert configuration.id == "first"
    assert configuration.read_only is False


def test_a_replaced_temporary_configuration_opens(closing: Closing) -> None:
    configuration = dataclasses.replace(
        Configuration.temporary(), id="session", encryption=Encryption.aes256("key")
    )
    store = closing(swiftmmkv.open(configuration))
    assert store.id == "session"
    assert store.set("name", "blob")
    assert store.get("name", str) == "blob"


def test_configurations_are_equal_when_their_fields_are(tmp_path: Path) -> None:
    first = Configuration(directory=tmp_path, mode=Mode.SINGLE_PROCESS, id="session")
    second = Configuration(directory=tmp_path, mode=Mode.SINGLE_PROCESS, id="session")
    assert first == second
    assert first != dataclasses.replace(second, id="other")
