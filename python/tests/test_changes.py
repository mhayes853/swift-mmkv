"""Change listeners: `Store.subscribe`, `ChangeBatch`, `Subscription`, `Store.observe`, and
`on_integrity_failure`."""

from __future__ import annotations

import gc
import json
import os
import subprocess
import sys
import threading
from collections.abc import Iterator
from pathlib import Path
from typing import Any
from uuid import uuid4

import pytest

import swiftmmkv
from swiftmmkv import ChangeBatch, Key, Mode, Store, Subscription

TIMEOUT = 5.0


class Boom(Exception):
    pass


@pytest.fixture
def shared(store: Store) -> Iterator[Store]:
    """A second `Store` over the files of `store`."""
    second = swiftmmkv.open(store.configuration)
    yield second
    second.close()


@pytest.fixture
def multi_process(tmp_path: Path) -> Iterator[Store]:
    """A multi-process store with an identifier no other test uses."""
    store = swiftmmkv.open(tmp_path / "mmkv", mode=Mode.MULTI_PROCESS, id=f"changes-{uuid4().hex}")
    # The files are created when the store is first used.
    store.set("opened", True)
    yield store
    store.close()


def write_from_another_process(store: Store, key: str, value: str) -> None:
    """Writes `value` under `key` of the files of `store`, from a child process."""
    configuration = store.configuration
    code = (
        "import sys, swiftmmkv\n"
        "store = swiftmmkv.open(sys.argv[1], mode=swiftmmkv.Mode.MULTI_PROCESS, id=sys.argv[2])\n"
        "assert store.set(sys.argv[3], sys.argv[4])\n"
        "store.close()\n"
    )
    subprocess.run(
        [
            sys.executable,
            "-c",
            code,
            os.fspath(configuration.directory),
            str(configuration.id),
            key,
            value,
        ],
        env=dict(os.environ),
        check=True,
        timeout=60,
        capture_output=True,
    )


# MARK: - Batches


def test_a_listener_receives_one_batch_per_operation(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        store.set("a", 1)
        store.remove("a")
        store.set("b", "text")

    assert [batch.keys for batch in batches] == [("a",), ("a",), ("b",)]


def test_a_change_made_in_this_process_is_not_external(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        store.set("a", 1)

    assert [batch.is_external for batch in batches] == [False]


def test_removing_under_a_prefix_is_one_batch_of_the_keys_it_removed(store: Store) -> None:
    store.set("settings.theme", "dark")
    store.set("settings.volume", 0.5)
    store.set("other", 1)
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        store.remove_under("settings")

    assert len(batches) == 1
    assert set(batches[0].keys) == {"settings.theme", "settings.volume"}


def test_removing_many_keys_is_one_batch(store: Store) -> None:
    store.set("a", 1)
    store.set("b", 2)
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        store.remove_many(["a", "b"])

    assert len(batches) == 1
    assert sorted(batches[0].keys) == ["a", "b"]


def test_setting_many_keys_is_one_batch(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        store.set_many({"a": 1, "b": 2})

    assert len(batches) == 1
    assert sorted(batches[0].keys) == ["a", "b"]


def test_a_write_the_store_turns_away_tells_listeners_nothing(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        assert not store.set("", 1)

    assert batches == []


def test_a_key_subscription_hears_only_of_its_key(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append, key="a"):
        store.set("b", 1)
        store.set("a", 2)
        store.set("ab", 3)

    assert [batch.keys for batch in batches] == [("a",)]


def test_a_key_subscription_narrows_a_batch_to_its_key(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append, key="a"):
        with store.locked():
            store.set("a", 1)
            store.set("b", 2)

    assert [batch.keys for batch in batches] == [("a",)]


def test_a_typed_key_can_be_followed(store: Store) -> None:
    volume = Key("volume", float)
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append, key=volume):
        store.set("other", 1)
        store[volume] = 0.5

    assert [batch.keys for batch in batches] == [("volume",)]


def test_an_under_subscription_hears_of_the_prefix_and_the_keys_under_it(
    store: Store,
) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append, under="settings"):
        store.set("settings", 1)
        store.set("settings.theme", "dark")
        store.set("settingsTheme", "light")
        store.set("other", 2)

    assert [batch.keys for batch in batches] == [("settings",), ("settings.theme",)]


def test_an_under_subscription_narrows_a_batch_to_the_keys_under_it(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append, under="settings"):
        store.set_many({"settings.theme": "dark", "other": 1, "settings.volume": 0.5})

    assert len(batches) == 1
    assert sorted(batches[0].keys) == ["settings.theme", "settings.volume"]


def test_an_under_subscription_uses_the_separator_it_is_given(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append, under="settings", separator="/"):
        store.set("settings.theme", "dark")
        store.set("settings/theme", "dark")

    assert [batch.keys for batch in batches] == [("settings/theme",)]


def test_an_under_subscription_to_an_empty_prefix_hears_of_every_key(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append, under=""):
        store.set("a", 1)
        store.set("b.c", 2)

    assert [batch.keys for batch in batches] == [("a",), ("b.c",)]


def test_subscribing_to_a_key_and_a_prefix_at_once_raises_type_error(store: Store) -> None:
    with pytest.raises(TypeError):
        store.subscribe(lambda batch: None, key="a", under="b")


def test_a_listener_must_be_callable(store: Store) -> None:
    with pytest.raises(TypeError):
        store.subscribe("not a listener")  # type: ignore[arg-type]


def test_a_followed_key_must_be_a_string_or_a_key(store: Store) -> None:
    with pytest.raises(TypeError):
        store.subscribe(lambda batch: None, key=1)  # type: ignore[arg-type]


# MARK: - ChangeBatch


def test_a_batch_names_the_store_it_came_from(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        store.set("a", 1)

    assert batches[0].store is store


def test_a_batch_tells_whether_it_has_a_key(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        store.set("a", 1)

    batch = batches[0]
    assert "a" in batch
    assert Key("a", int) in batch
    assert "b" not in batch
    assert Key("b", int) not in batch
    assert 1 not in batch


def test_a_batch_reads_a_string_key_as_a_type(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        store.set("count", 3)

    assert batches[0].get("count", int) == 3
    assert batches[0].get("missing", int) is None


def test_a_batch_reads_a_string_key_with_a_default(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        store.set("count", 3)

    assert batches[0].get("count", int, default=7) == 3
    assert batches[0].get("missing", int, default=7) == 7


def test_a_batch_reads_a_typed_key(store: Store) -> None:
    count = Key("count", swiftmmkv.int32)
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        store[count] = 3

    assert batches[0].get(count) == 3
    assert batches[0].get(Key("missing", int)) is None


def test_a_batch_reads_a_typed_key_with_a_default(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        store.set("count", 3)

    assert batches[0].get(Key("count", int), default=7) == 3
    assert batches[0].get(Key("missing", int), default=7) == 7


def test_a_batch_reads_a_defaulted_key(store: Store) -> None:
    volume = Key("volume", float, default=0.5)
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        store.remove(volume)
        store[volume] = 0.8

    assert batches[0].get(volume) == 0.8
    assert batches[0].get(Key("missing", float, default=0.5)) == 0.5


def test_a_batch_will_not_read_a_string_key_without_a_type(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        store.set("count", 3)

    with pytest.raises(TypeError):
        batches[0].get("count")  # type: ignore[call-overload]


def test_a_batch_will_not_read_a_typed_key_with_a_type(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        store.set("count", 3)

    with pytest.raises(TypeError):
        batches[0].get(Key("count", int), int)  # type: ignore[call-overload]


def test_a_batch_reads_what_the_store_holds_when_it_is_read(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        store.set("count", 1)
    store.set("count", 2)

    assert batches[0].keys == ("count",)
    assert batches[0].get("count", int) == 2


def test_a_batch_can_be_kept_after_the_listener_returns(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        store.set_many({"a": 1, "b": 2})
    gc.collect()

    assert sorted(batches[0].keys) == ["a", "b"]
    assert not batches[0].is_external
    assert batches[0].get("a", int) == 1


def test_a_batch_shows_its_keys_in_its_repr(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        store.set("a", 1)

    assert repr(batches[0]) == "<swiftmmkv.ChangeBatch keys=('a',)>"


def test_a_batch_of_an_external_change_says_so_in_its_repr(store: Store) -> None:
    batches: list[ChangeBatch] = []
    store.subscribe(batches.append)
    store.close()

    assert repr(batches[-1]) == "<swiftmmkv.ChangeBatch keys=(), is_external=True>"


def test_a_change_batch_is_not_made_by_calling_its_class() -> None:
    with pytest.raises(TypeError):
        ChangeBatch()


# MARK: - Listeners


def test_a_listener_may_read_the_store(store: Store) -> None:
    read: list[int | None] = []
    with store.subscribe(lambda batch: read.append(batch.store.get("a", int))):
        store.set("a", 1)

    assert read == [1]


def test_a_listener_may_write_the_store(store: Store) -> None:
    batches: list[ChangeBatch] = []

    def on_change(batch: ChangeBatch) -> None:
        batches.append(batch)
        if "a" in batch:
            assert store.set("b", 2)

    with store.subscribe(on_change):
        store.set("a", 1)

    assert store.get("b", int) == 2
    assert [batch.keys for batch in batches] == [("a",), ("b",)]


def test_a_listener_runs_on_the_thread_that_made_the_change(store: Store) -> None:
    threads: list[int] = []
    written: list[int] = []

    def write() -> None:
        written.append(threading.get_ident())
        store.set("a", 1)

    with store.subscribe(lambda batch: threads.append(threading.get_ident())):
        thread = threading.Thread(target=write)
        thread.start()
        thread.join(TIMEOUT)
        assert not thread.is_alive()
        store.set("a", 2)

    assert threads == [written[0], threading.get_ident()]


def test_a_listener_hears_every_change_made_from_several_threads(store: Store) -> None:
    threads, writes = 8, 100
    lock = threading.Lock()
    heard: list[str] = []

    def on_change(batch: ChangeBatch) -> None:
        with lock:
            heard.extend(batch.keys)

    barrier = threading.Barrier(threads, timeout=TIMEOUT)

    def write(number: int) -> None:
        barrier.wait()
        for index in range(writes):
            store.set(f"{number}.{index}", index)

    with store.subscribe(on_change):
        workers = [threading.Thread(target=write, args=(n,)) for n in range(threads)]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join(30)
            assert not worker.is_alive()

    assert sorted(heard) == sorted(f"{n}.{i}" for n in range(threads) for i in range(writes))


def test_a_listener_hears_a_change_made_through_another_store_over_the_same_files(
    store: Store, shared: Store
) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        shared.set("a", 1)

    assert [(batch.keys, batch.is_external) for batch in batches] == [(("a",), False)]
    assert batches[0].store is store
    assert batches[0].get("a", int) == 1


def test_a_listener_hears_of_a_change_from_another_process(multi_process: Store) -> None:
    batches: list[ChangeBatch] = []
    with multi_process.subscribe(batches.append):
        write_from_another_process(multi_process, "username", "blob")
        multi_process.check_for_external_changes()

    assert len(batches) == 1
    assert batches[0].is_external
    assert batches[0].keys == ()
    assert batches[0].get("username", str) == "blob"


def test_a_key_subscription_hears_of_any_change_from_another_process(
    multi_process: Store,
) -> None:
    batches: list[ChangeBatch] = []
    with multi_process.subscribe(batches.append, key="username"):
        write_from_another_process(multi_process, "other", "value")
        multi_process.check_for_external_changes()

    assert [(batch.keys, batch.is_external) for batch in batches] == [((), True)]


def test_checking_for_external_changes_when_there_are_none_tells_nothing(
    multi_process: Store,
) -> None:
    batches: list[ChangeBatch] = []
    with multi_process.subscribe(batches.append):
        multi_process.check_for_external_changes()

    assert batches == []


# MARK: - Subscriptions


def test_cancelling_a_subscription_stops_its_listener(store: Store) -> None:
    batches: list[ChangeBatch] = []
    subscription = store.subscribe(batches.append)
    store.set("a", 1)
    subscription.cancel()
    store.set("a", 2)

    assert [batch.keys for batch in batches] == [("a",)]


def test_cancelling_a_subscription_twice_is_harmless(store: Store) -> None:
    batches: list[ChangeBatch] = []
    subscription = store.subscribe(batches.append)
    subscription.cancel()
    subscription.cancel()
    store.set("a", 1)

    assert batches == []
    assert subscription.cancelled


def test_a_subscription_says_whether_it_is_cancelled(store: Store) -> None:
    subscription = store.subscribe(lambda batch: None)
    assert not subscription.cancelled
    assert repr(subscription) == "<swiftmmkv.Subscription>"

    subscription.cancel()

    assert subscription.cancelled
    assert repr(subscription) == "<swiftmmkv.Subscription cancelled>"


def test_a_subscription_cancels_at_the_end_of_a_with_block(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append) as subscription:
        assert isinstance(subscription, Subscription)
        store.set("a", 1)
    store.set("a", 2)

    assert subscription.cancelled
    assert len(batches) == 1


def test_a_subscription_is_not_made_by_calling_its_class() -> None:
    with pytest.raises(TypeError):
        Subscription()


def test_a_listener_may_cancel_its_own_subscription(store: Store) -> None:
    batches: list[ChangeBatch] = []
    subscription: Subscription | None = None

    def on_change(batch: ChangeBatch) -> None:
        batches.append(batch)
        assert subscription is not None
        subscription.cancel()

    subscription = store.subscribe(on_change)
    store.set("a", 1)
    store.set("a", 2)

    assert len(batches) == 1
    assert subscription.cancelled


def test_a_listener_may_cancel_another_subscription(store: Store) -> None:
    events: list[str] = []
    other = store.subscribe(lambda batch: events.append("other"))

    def on_change(batch: ChangeBatch) -> None:
        if not other.cancelled:
            other.cancel()
            events.append("cancelled")

    with store.subscribe(on_change):
        store.set("a", 1)
        store.set("a", 2)

    assert "cancelled" in events
    assert "other" not in events[events.index("cancelled") :]
    assert other.cancelled


def test_letting_go_of_a_subscription_does_not_cancel_it(store: Store) -> None:
    batches: list[ChangeBatch] = []
    store.subscribe(batches.append)
    gc.collect()

    store.set("a", 1)

    assert [batch.keys for batch in batches] == [("a",)]


def test_closing_a_store_tells_its_listeners_once_of_an_external_change(store: Store) -> None:
    batches: list[ChangeBatch] = []
    subscription = store.subscribe(batches.append)
    store.set("a", 1)

    store.close()

    assert [(batch.keys, batch.is_external) for batch in batches] == [
        (("a",), False),
        ((), True),
    ]
    assert batches[-1].store.get("a", int) is None
    subscription.cancel()


def test_a_closed_store_tells_its_listeners_nothing_more(store: Store) -> None:
    batches: list[ChangeBatch] = []
    subscription = store.subscribe(batches.append)
    store.close()
    store.set("a", 1)
    store.close()
    store.check_for_external_changes()

    assert len(batches) == 1
    subscription.cancel()


def test_a_subscription_ended_by_closing_is_not_cancelled(store: Store) -> None:
    subscription = store.subscribe(lambda batch: None)
    store.close()

    assert not subscription.cancelled
    subscription.cancel()


def test_a_subscription_ended_by_closing_can_be_cancelled_twice(store: Store) -> None:
    subscription = store.subscribe(lambda batch: None)
    store.close()

    subscription.cancel()
    subscription.cancel()
    assert subscription.cancelled


def test_closing_a_store_tells_the_listeners_of_another_store_over_its_files(
    store: Store, shared: Store
) -> None:
    batches: list[ChangeBatch] = []
    subscription = shared.subscribe(batches.append)

    store.close()
    shared.set("a", 1)

    assert shared.closed
    assert [(batch.keys, batch.is_external) for batch in batches] == [((), True)]
    subscription.cancel()


def test_a_listener_may_close_the_store(store: Store) -> None:
    batches: list[ChangeBatch] = []

    def on_change(batch: ChangeBatch) -> None:
        batches.append(batch)
        if not batch.is_external:
            batch.store.close()

    subscription = store.subscribe(on_change)
    store.set("a", 1)
    store.set("a", 2)

    assert store.closed
    assert [(batch.keys, batch.is_external) for batch in batches] == [
        (("a",), False),
        ((), True),
    ]
    subscription.cancel()


def test_a_listeners_error_does_not_come_out_of_the_write(
    store: Store, unraisable: list[Any]
) -> None:
    def on_change(batch: ChangeBatch) -> None:
        raise Boom

    with store.subscribe(on_change):
        assert store.set("a", 1)

    assert store.get("a", int) == 1


def test_a_listeners_error_goes_to_the_unraisable_hook(store: Store, unraisable: list[Any]) -> None:
    error = Boom("from the listener")

    def on_change(batch: ChangeBatch) -> None:
        raise error

    with store.subscribe(on_change):
        store.set("a", 1)

    assert [caught.exc_value for caught in unraisable] == [error]


def test_a_listener_that_raised_is_called_again_for_the_next_change(
    store: Store, unraisable: list[Any]
) -> None:
    batches: list[ChangeBatch] = []

    def on_change(batch: ChangeBatch) -> None:
        batches.append(batch)
        raise Boom

    with store.subscribe(on_change):
        store.set("a", 1)
        store.set("b", 2)

    assert [batch.keys for batch in batches] == [("a",), ("b",)]
    assert len(unraisable) == 2


def test_a_listeners_error_does_not_stop_other_listeners(
    store: Store, unraisable: list[Any]
) -> None:
    def on_change(batch: ChangeBatch) -> None:
        raise Boom

    batches: list[ChangeBatch] = []
    with store.subscribe(on_change), store.subscribe(batches.append):
        store.set("a", 1)

    assert [batch.keys for batch in batches] == [("a",)]
    assert len(unraisable) == 1


def test_a_listeners_error_after_a_locked_block_does_not_come_out_of_the_with(
    store: Store, unraisable: list[Any]
) -> None:
    def on_change(batch: ChangeBatch) -> None:
        raise Boom

    with store.subscribe(on_change):
        with store.locked():
            store.set("a", 1)

    assert len(unraisable) == 1
    # The lock was given up.
    store.close()
    assert store.closed


# MARK: - observe


def test_observing_a_string_key_gives_its_value_at_once(store: Store) -> None:
    store.set("volume", 0.5)
    values: list[float | None] = []
    with store.observe("volume", float, values.append):
        assert values == [0.5]


def test_observing_a_missing_string_key_gives_none_at_once(store: Store) -> None:
    values: list[float | None] = []
    with store.observe("volume", float, values.append):
        assert values == [None]


def test_observing_a_string_key_gives_its_value_after_each_change(store: Store) -> None:
    values: list[float | None] = []
    with store.observe("volume", float, values.append):
        store.set("volume", 0.5)
        store.set("other", 1)
        store.set("volume", 0.5)
        store.remove("volume")

    assert values == [None, 0.5, 0.5, None]


def test_observing_a_string_key_reads_it_with_its_converter(store: Store) -> None:
    store.set("count", 7, swiftmmkv.int32)
    values: list[int | None] = []
    with store.observe("count", swiftmmkv.int32, values.append):
        store.set("count", 8, swiftmmkv.int32)

    assert values == [7, 8]


def test_observing_a_typed_key_gives_its_value_at_once_and_after_each_change(
    store: Store,
) -> None:
    username = Key("username", str)
    values: list[str | None] = []
    with store.observe(username, values.append):
        store[username] = "blob"
        store.remove(username)

    assert values == [None, "blob", None]


def test_observing_a_defaulted_key_gives_its_default_for_a_missing_value(
    store: Store,
) -> None:
    volume = Key("volume", float, default=0.5)
    values: list[float] = []
    with store.observe(volume, values.append):
        store[volume] = 0.8
        store.remove(volume)

    assert values == [0.5, 0.8, 0.5]


def test_observing_stops_once_cancelled(store: Store) -> None:
    values: list[int | None] = []
    subscription = store.observe("count", int, values.append)
    subscription.cancel()
    store.set("count", 1)

    assert values == [None]


def test_observing_hears_a_change_made_through_another_store_over_the_same_files(
    store: Store, shared: Store
) -> None:
    values: list[int | None] = []
    with store.observe("count", int, values.append):
        shared.set("count", 1)

    assert values == [None, 1]


def test_observing_takes_a_key_a_type_and_a_listener(store: Store) -> None:
    with pytest.raises(TypeError):
        store.observe("count", lambda value: None)  # type: ignore[call-overload]
    with pytest.raises(TypeError):
        store.observe(Key("count", int), int, lambda value: None)  # type: ignore[call-overload]
    with pytest.raises(TypeError):
        store.observe("count", int, "not a listener")  # type: ignore[call-overload]


def test_observing_hands_a_first_value_that_cannot_be_read_to_on_error(store: Store) -> None:
    store.set("settings", "not json")
    values: list[Any] = []
    errors: list[Exception] = []
    with store.observe("settings", swiftmmkv.JSON, values.append, on_error=errors.append):
        assert values == []
        assert len(errors) == 1
        assert isinstance(errors[0], json.JSONDecodeError)


def test_observing_carries_on_after_a_value_that_cannot_be_read(store: Store) -> None:
    values: list[Any] = []
    errors: list[Exception] = []
    with store.observe("settings", swiftmmkv.JSON, values.append, on_error=errors.append):
        store.set("settings", "not json")
        store.set("settings", '{"theme": "dark"}')

    assert values == [None, {"theme": "dark"}]
    assert len(errors) == 1
    assert isinstance(errors[0], json.JSONDecodeError)


def test_observing_without_on_error_raises_the_error_of_the_first_read(store: Store) -> None:
    store.set("settings", "not json")
    values: list[Any] = []

    with pytest.raises(json.JSONDecodeError):
        store.observe("settings", swiftmmkv.JSON, values.append)

    store.set("settings", '{"theme": "dark"}')
    assert values == []


def test_observing_without_on_error_hands_a_later_error_to_the_unraisable_hook(
    store: Store, unraisable: list[Any]
) -> None:
    values: list[Any] = []
    with store.observe("settings", swiftmmkv.JSON, values.append):
        store.set("settings", "not json")
        store.set("settings", "[1]")

    assert values == [None, [1]]
    assert len(unraisable) == 1
    assert isinstance(unraisable[0].exc_value, json.JSONDecodeError)


def test_an_error_on_value_raises_at_once_comes_out_of_observe(store: Store) -> None:
    calls: list[int | None] = []

    def on_value(value: int | None) -> None:
        calls.append(value)
        raise Boom

    with pytest.raises(Boom):
        store.observe("count", int, on_value)

    store.set("count", 1)
    assert calls == [None]


# MARK: - Integrity failures


def test_an_integrity_failure_subscription_can_be_cancelled_twice() -> None:
    subscription = swiftmmkv.on_integrity_failure(lambda failure: None)
    assert isinstance(subscription, Subscription)
    assert not subscription.cancelled

    subscription.cancel()
    subscription.cancel()

    assert subscription.cancelled


def test_an_integrity_failure_callback_must_be_callable() -> None:
    with pytest.raises(TypeError):
        swiftmmkv.on_integrity_failure("not a callback")  # type: ignore[arg-type]
