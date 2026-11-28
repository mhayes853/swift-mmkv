"""`Expiry`, and expiry as an explicit argument of a write.

The shortest expiry is one second, so the tests that wait for a value to expire share one
wait: `expired` writes every value at once and waits for the short ones to go."""

from __future__ import annotations

import math
import pickle
import time
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta, timezone

import pytest

import swiftmmkv
from swiftmmkv import Directory, Expiry, Key, Mode, Store

SHORT = timedelta(seconds=1)
LONG = timedelta(hours=1)
#: How long a value with a short expiry may take to go.
DEADLINE = 4.0


def wait_until_gone(store: Store, keys: list[str]) -> None:
    """Polls until none of `keys` is in `store`, or the deadline passes."""
    deadline = time.monotonic() + DEADLINE
    while any(key in store for key in keys) and time.monotonic() < deadline:
        time.sleep(0.05)


# MARK: - The Expiry class


def test_never_is_one_expiry() -> None:
    assert Expiry.NEVER is Expiry.NEVER
    assert repr(Expiry.NEVER) == "Expiry.NEVER"


def test_an_expiry_after_a_duration() -> None:
    expiry = Expiry.after(timedelta(seconds=30))

    assert expiry == Expiry.after(timedelta(seconds=30))
    assert expiry != Expiry.after(timedelta(seconds=31))
    assert expiry != Expiry.NEVER
    assert repr(expiry) == "Expiry.after(datetime.timedelta(seconds=30))"


def test_an_expiry_after_takes_only_a_timedelta() -> None:
    with pytest.raises(TypeError):
        Expiry.after(30)  # type: ignore[arg-type]


def test_an_expiry_at_an_aware_moment() -> None:
    moment = datetime(2030, 1, 2, 3, 4, 5, tzinfo=UTC)

    expiry = Expiry.at(moment)

    assert expiry == Expiry.at(seconds_since_1970=moment.timestamp())
    assert expiry == Expiry.at(moment.astimezone(timezone(timedelta(hours=5))))
    assert repr(expiry) == f"Expiry.at(seconds_since_1970={moment.timestamp()!r})"


def test_an_expiry_at_seconds_since_1970() -> None:
    expiry = Expiry.at(seconds_since_1970=1_900_000_000)

    assert expiry == Expiry.at(seconds_since_1970=1_900_000_000.0)
    assert expiry != Expiry.at(seconds_since_1970=1_900_000_001)
    assert expiry != Expiry.after(timedelta(seconds=1_900_000_000))


def test_an_expiry_at_a_naive_moment_is_refused() -> None:
    with pytest.raises(ValueError):
        Expiry.at(datetime(2030, 1, 1))


@pytest.mark.parametrize(
    "call",
    [
        lambda: Expiry.at(),  # type: ignore[call-overload]
        lambda: Expiry.at(  # type: ignore[call-overload]
            datetime.now(UTC), seconds_since_1970=1
        ),
        lambda: Expiry.at("2030-01-01"),  # type: ignore[call-overload]
        lambda: Expiry.at(seconds_since_1970="1"),  # type: ignore[arg-type]
        lambda: Expiry.at(seconds_since_1970=True),
        lambda: Expiry.at(seconds_since_1970=None),  # type: ignore[call-overload]
    ],
    ids=["nothing", "both", "a string moment", "string seconds", "bool seconds", "None"],
)
def test_an_expiry_at_something_else_is_a_type_error(call: object) -> None:
    with pytest.raises(TypeError):
        call()  # type: ignore[operator]


def test_an_expiry_at_seconds_that_are_not_a_number_is_refused() -> None:
    with pytest.raises(ValueError):
        Expiry.at(seconds_since_1970=math.nan)


def test_an_expiry_is_not_made_by_calling_its_class() -> None:
    with pytest.raises(TypeError):
        Expiry()


def test_equal_expiries_hash_alike() -> None:
    expiries = {
        Expiry.after(timedelta(seconds=30)),
        Expiry.after(timedelta(seconds=30)),
        Expiry.at(seconds_since_1970=30),
        Expiry.NEVER,
    }

    assert len(expiries) == 3


def test_an_expiry_is_not_equal_to_other_things() -> None:
    assert Expiry.after(timedelta(seconds=30)) != timedelta(seconds=30)
    assert Expiry.NEVER != 0


@pytest.mark.parametrize(
    "expiry",
    [
        Expiry.NEVER,
        Expiry.after(timedelta(seconds=30)),
        Expiry.at(seconds_since_1970=1_900_000_000.5),
    ],
    ids=["never", "after", "at"],
)
def test_an_expiry_pickles(expiry: Expiry) -> None:
    copy = pickle.loads(pickle.dumps(expiry))

    assert copy == expiry
    assert hash(copy) == hash(expiry)


def test_never_pickles_as_never() -> None:
    assert pickle.loads(pickle.dumps(Expiry.NEVER)) is Expiry.NEVER


def test_an_expiry_is_immutable() -> None:
    with pytest.raises(AttributeError):
        Expiry.NEVER.seconds = 1  # type: ignore[attr-defined]


# MARK: - Writes that do not wait


def test_a_write_without_an_expiry_does_not_enable_expiry(store: Store) -> None:
    store.set("theme", "dark")

    assert not store.expiry_enabled


def test_the_first_expiring_write_enables_expiry(store: Store) -> None:
    assert not store.expiry_enabled

    assert store.set("otp", "123456", expiry=LONG)

    assert store.expiry_enabled
    assert store.get("otp", str) == "123456"


@pytest.mark.parametrize(
    "expiry",
    [
        Expiry.after(LONG),
        LONG,
        datetime.now(UTC) + LONG,
        Expiry.at(datetime.now(UTC) + LONG),
        Expiry.at(seconds_since_1970=time.time() + 3600),
        Expiry.NEVER,
    ],
    ids=["Expiry.after", "timedelta", "datetime", "Expiry.at", "seconds", "never"],
)
def test_a_write_takes_each_form_of_expiry(store: Store, expiry: object) -> None:
    assert store.set("otp", "123456", expiry=expiry)  # type: ignore[arg-type]

    assert store.get("otp", str) == "123456"


@pytest.mark.parametrize(
    "expiry", [30, 30.0, "30s", object()], ids=["int", "float", "str", "object"]
)
def test_an_expiry_of_the_wrong_type_is_a_type_error(store: Store, expiry: object) -> None:
    with pytest.raises(TypeError):
        store.set("otp", "123456", expiry=expiry)  # type: ignore[arg-type]

    assert "otp" not in store


def test_a_batch_expiry_of_the_wrong_type_is_a_type_error(store: Store) -> None:
    with pytest.raises(TypeError):
        store.set_many({"a": 1}, expiry=30)  # type: ignore[arg-type]


def test_a_default_expiry_of_the_wrong_type_is_a_type_error(directory: Directory) -> None:
    with pytest.raises(TypeError):
        directory.open(mode=Mode.SINGLE_PROCESS, default_expiry=30)  # type: ignore[arg-type]


def test_a_naive_datetime_expiry_is_refused(store: Store) -> None:
    with pytest.raises(ValueError):
        store.set("otp", "123456", expiry=datetime.now() + LONG)


def test_disabling_expiry_keeps_every_value_until_it_is_removed(store: Store) -> None:
    store.set("otp", "123456", expiry=LONG)
    store.set("theme", "dark")

    store.disable_expiry()

    assert not store.expiry_enabled
    assert store.keys() == {"otp", "theme"}
    assert store.get("otp", str) == "123456"


def test_disabling_expiry_on_a_store_without_it_does_nothing(store: Store) -> None:
    store.set("theme", "dark")

    store.disable_expiry()

    assert not store.expiry_enabled
    assert store.get("theme", str) == "dark"


def test_an_expiring_write_after_disabling_enables_expiry_again(store: Store) -> None:
    store.set("otp", "1", expiry=LONG)
    store.disable_expiry()

    store.set("otp", "2", expiry=LONG)

    assert store.expiry_enabled


def test_expiry_enabled_is_kept_by_the_files(directory: Directory) -> None:
    with directory.open(mode=Mode.SINGLE_PROCESS) as store:
        store.set("otp", "1", expiry=LONG)

    with directory.open(mode=Mode.SINGLE_PROCESS) as reopened:
        assert reopened.expiry_enabled
        assert reopened.get("otp", str) == "1"


# MARK: - Writes that wait for their values to expire

NOTE = Key("note", str)
COUNT = Key("count", swiftmmkv.int32)


@dataclass
class Point:
    x: int
    y: int


POINT = swiftmmkv.text_converter(
    lambda point: f"{point.x},{point.y}",
    lambda text: Point(*map(int, text.split(","))),
)


@dataclass
class Expired:
    store: Store
    defaulted: Store
    #: The keys of `store` and of `defaulted` that were written to expire.
    short: list[str]
    short_defaulted: list[str]


@pytest.fixture(scope="module")
def expired(tmp_path_factory: pytest.TempPathFactory) -> Iterator[Expired]:
    """Two stores whose short-lived values were all written at once, and have had time to
    expire."""
    root = tmp_path_factory.mktemp("expiry")
    store = swiftmmkv.open(root, mode=Mode.SINGLE_PROCESS, id="plain")
    defaulted = swiftmmkv.open(root, mode=Mode.SINGLE_PROCESS, id="defaulted", default_expiry=SHORT)

    now = datetime.now(UTC)
    store.set("kept", "value")
    store.set("kept.never", "value", expiry=Expiry.NEVER)
    store.set("kept.long", "value", expiry=LONG)
    store.set("short.expiry", "value", expiry=Expiry.after(SHORT))
    store.set("short.timedelta", "value", expiry=SHORT)
    store.set("short.datetime", "value", expiry=now + SHORT)
    store.set("short.seconds", "value", expiry=Expiry.at(seconds_since_1970=now.timestamp() + 1))
    store.set("short.int", 7, swiftmmkv.int64, expiry=SHORT)
    store.set(NOTE, "value", expiry=SHORT)
    store.set(COUNT, 3, expiry=SHORT)
    store.set_many({"short.many.1": "a", "short.many.2": "b"}, expiry=SHORT)
    store.set("short.json", {"x": 1}, swiftmmkv.JSON, expiry=SHORT)
    store.set("short.converter", Point(1, 2), POINT, expiry=SHORT)

    defaulted.set("short", "value")
    defaulted.set("short.many", 1.5)
    defaulted.set_many({"short.batch": "a"})
    defaulted.set("kept.never", "value", expiry=Expiry.NEVER)
    defaulted.set("kept.long", "value", expiry=LONG)

    short = [key for key in store.keys() if key.startswith("short.")] + ["note", "count"]
    short_defaulted = ["short", "short.many", "short.batch"]
    assert len(short) == 11

    wait_until_gone(store, short)
    wait_until_gone(defaulted, short_defaulted)
    yield Expired(store, defaulted, short, short_defaulted)
    store.close()
    defaulted.close()


@pytest.mark.parametrize(
    "key",
    [
        "short.expiry",
        "short.timedelta",
        "short.datetime",
        "short.seconds",
        "short.int",
        "note",
        "count",
        "short.many.1",
        "short.many.2",
        "short.json",
        "short.converter",
    ],
)
def test_a_value_with_a_short_expiry_is_gone_after_it(expired: Expired, key: str) -> None:
    assert key not in expired.store


def test_an_expired_value_reads_as_missing(expired: Expired) -> None:
    store = expired.store

    assert store.get("short.expiry", str) is None
    assert store.get("short.int", swiftmmkv.int64) is None
    assert store.get("short.json", swiftmmkv.JSON) is None
    assert store.get("short.converter", POINT) is None
    assert store.value_size("short.expiry") is None


def test_an_expired_typed_key_reads_as_missing(expired: Expired) -> None:
    assert expired.store.get(NOTE) is None
    assert expired.store.get(COUNT, default=0) == 0
    with pytest.raises(KeyError):
        expired.store[NOTE]


def test_an_expired_key_is_left_out_of_the_keys(expired: Expired) -> None:
    assert expired.store.keys() == {"kept", "kept.never", "kept.long"}
    assert expired.store.keys(under="short") == frozenset()


def test_an_expired_key_is_left_out_of_the_count(expired: Expired) -> None:
    assert len(expired.store) == 3


def test_a_write_without_an_expiry_keeps_its_value(expired: Expired) -> None:
    assert expired.store.get("kept", str) == "value"
    assert expired.store.get("kept.never", str) == "value"


def test_a_value_with_a_long_expiry_is_kept(expired: Expired) -> None:
    assert expired.store.get("kept.long", str) == "value"
    assert expired.defaulted.get("kept.long", str) == "value"


def test_the_default_expiry_applies_to_writes_that_name_none(expired: Expired) -> None:
    for key in expired.short_defaulted:
        assert key not in expired.defaulted


def test_never_overrides_the_default_expiry(expired: Expired) -> None:
    assert expired.defaulted.get("kept.never", str) == "value"
    assert expired.defaulted.keys() == {"kept.never", "kept.long"}


def test_a_default_expiry_enables_expiry(expired: Expired) -> None:
    assert expired.defaulted.expiry_enabled


def test_a_value_goes_no_more_than_a_second_before_its_expiry(store: Store) -> None:
    # MMKV counts whole seconds of the clock, so a value that is written late in a second
    # goes sooner than its expiry says, by less than a second.
    deadline = time.monotonic() + 2
    while time.time() % 1 < 0.8 and time.monotonic() < deadline:
        time.sleep(0.01)
    written = time.monotonic()
    store.set("otp", "123456", expiry=timedelta(seconds=2))

    time.sleep(max(0.0, written + 0.5 - time.monotonic()))

    assert store.get("otp", str) == "123456"
