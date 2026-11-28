"""`Store.changes` and `Store.values`: following a store with `async for`."""

from __future__ import annotations

import asyncio
import contextlib
import gc
import json
import threading
from collections.abc import AsyncIterator, Iterator
from pathlib import Path
from typing import Any
from uuid import uuid4

import pytest

import swiftmmkv
from swiftmmkv import ChangeBatch, Key, Mode, Store, _changes

TIMEOUT = 5.0


@pytest.fixture
def multi_process(tmp_path: Path) -> Iterator[Store]:
    """A multi-process store, which is the only kind suspension does anything for."""
    store = swiftmmkv.open(tmp_path / "mmkv", mode=Mode.MULTI_PROCESS, id=f"async-{uuid4().hex}")
    store.set("opened", True)
    yield store
    store.resume()
    store.close()


async def next_of[T](iterator: AsyncIterator[T]) -> T:
    return await asyncio.wait_for(anext(iterator), timeout=TIMEOUT)


async def settle() -> None:
    """Lets the other tasks run until they wait."""
    for _ in range(10):
        await asyncio.sleep(0)


async def ends(iterator: AsyncIterator[Any]) -> bool:
    try:
        await next_of(iterator)
    except StopAsyncIteration:
        return True
    return False


async def cancel(task: asyncio.Task[Any]) -> None:
    task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await asyncio.wait_for(task, timeout=TIMEOUT)


# MARK: - changes


def test_changes_yields_a_batch_for_a_change(store: Store) -> None:
    async def main() -> ChangeBatch:
        changes = store.changes()
        store.set("a", 1)
        batch = await next_of(changes)
        await changes.aclose()
        return batch

    batch = asyncio.run(main())
    assert batch.keys == ("a",)
    assert not batch.is_external
    assert batch.get("a", int) == 1


def test_changes_yields_a_batch_for_each_change_it_waits_for(store: Store) -> None:
    async def main() -> list[tuple[str, ...]]:
        changes = store.changes()
        keys = []
        for key in ("a", "b"):
            waiting = asyncio.ensure_future(next_of(changes))
            await settle()
            store.set(key, 1)
            keys.append((await waiting).keys)
        await changes.aclose()
        return keys

    assert asyncio.run(main()) == [("a",), ("b",)]


def test_changes_misses_nothing_between_the_call_and_the_first_await(store: Store) -> None:
    async def main() -> tuple[str, ...]:
        changes = store.changes()
        store.set("before", 1)
        await settle()
        batch = await next_of(changes)
        await changes.aclose()
        return batch.keys

    assert asyncio.run(main()) == ("before",)


def test_changes_merges_waiting_batches_with_each_key_once_in_the_order_first_changed(
    store: Store,
) -> None:
    async def main() -> tuple[str, ...]:
        changes = store.changes()
        store.set("b", 1)
        store.set("a", 2)
        store.set("b", 3)
        store.set("c", 4)
        batch = await next_of(changes)
        await changes.aclose()
        return batch.keys

    assert asyncio.run(main()) == ("b", "a", "c")


def test_changes_yields_nothing_more_once_merged_batches_are_taken(store: Store) -> None:
    async def main() -> tuple[str, ...]:
        changes = store.changes()
        store.set("a", 1)
        store.set("b", 2)
        await next_of(changes)
        store.set("c", 3)
        batch = await next_of(changes)
        await changes.aclose()
        return batch.keys

    assert asyncio.run(main()) == ("c",)


def test_a_merged_batch_is_external_when_any_batch_in_it_was(multi_process: Store) -> None:
    async def main() -> ChangeBatch:
        changes = multi_process.changes()
        multi_process.set("a", 1)
        multi_process.suspend()
        # Resuming tells listeners of an external change.
        multi_process.resume()
        batch = await next_of(changes)
        await changes.aclose()
        return batch

    batch = asyncio.run(main())
    assert batch.keys == ("a",)
    assert batch.is_external


def test_changes_of_a_key_yields_only_that_key(store: Store) -> None:
    async def main() -> tuple[str, ...]:
        changes = store.changes(key=Key("a", int))
        store.set("b", 1)
        store.set_many({"a": 2, "c": 3})
        batch = await next_of(changes)
        await changes.aclose()
        return batch.keys

    assert asyncio.run(main()) == ("a",)


def test_changes_under_a_prefix_yields_only_the_keys_under_it(store: Store) -> None:
    async def main() -> tuple[str, ...]:
        changes = store.changes(under="settings", separator="/")
        store.set("settings/theme", "dark")
        store.set("settings.theme", "dark")
        store.set("other", 1)
        store.set("settings", "x")
        batch = await next_of(changes)
        await changes.aclose()
        return batch.keys

    assert asyncio.run(main()) == ("settings/theme", "settings")


def test_changes_of_a_key_and_a_prefix_at_once_raises_type_error(store: Store) -> None:
    with pytest.raises(TypeError):
        store.changes(key="a", under="b")


def test_changes_can_be_followed_with_async_for(store: Store) -> None:
    async def main() -> list[tuple[str, ...]]:
        changes = store.changes()
        store.set("a", 1)
        keys = []
        async with asyncio.timeout(TIMEOUT):
            async for batch in changes:
                keys.append(batch.keys)
                if len(keys) == 1:
                    store.set("b", 2)
                else:
                    break
        await changes.aclose()
        return keys

    assert asyncio.run(main()) == [("a",), ("b",)]


def test_changes_ends_after_the_batch_that_says_the_store_closed(store: Store) -> None:
    async def main() -> tuple[ChangeBatch, bool]:
        changes = store.changes()
        store.close()
        return await next_of(changes), await ends(changes)

    batch, ended = asyncio.run(main())
    assert batch.is_external
    assert batch.keys == ()
    assert ended


def test_changes_yields_what_was_waiting_before_the_store_closed(store: Store) -> None:
    async def main() -> tuple[ChangeBatch, bool]:
        changes = store.changes()
        store.set("a", 1)
        store.close()
        return await next_of(changes), await ends(changes)

    batch, ended = asyncio.run(main())
    assert batch.keys == ("a",)
    assert batch.is_external
    assert ended


def test_closing_the_store_wakes_a_task_waiting_on_its_changes(store: Store) -> None:
    async def main() -> bool:
        changes = store.changes()
        waiting = asyncio.ensure_future(next_of(changes))
        await settle()
        store.close()
        batch = await waiting
        assert batch.is_external
        return await ends(changes)

    assert asyncio.run(main())


def test_changes_of_a_closed_store_ends_at_once(store: Store) -> None:
    store.close()

    async def main() -> bool:
        return await ends(store.changes())

    assert asyncio.run(main())


def test_changes_stays_ended(store: Store) -> None:
    async def main() -> bool:
        changes = store.changes()
        store.close()
        await next_of(changes)
        await ends(changes)
        return await ends(changes)

    assert asyncio.run(main())


def test_closing_changes_ends_the_iteration(store: Store) -> None:
    async def main() -> bool:
        changes = store.changes()
        store.set("a", 1)
        await changes.aclose()
        store.set("b", 2)
        return await ends(changes)

    assert asyncio.run(main())


def test_closing_changes_wakes_a_task_waiting_on_it(store: Store) -> None:
    async def main() -> bool:
        changes = store.changes()
        waiting = asyncio.ensure_future(ends(changes))
        await settle()
        await changes.aclose()
        return await waiting

    assert asyncio.run(main())


def test_closing_changes_cancels_its_subscription(store: Store) -> None:
    async def main() -> int:
        before = len(_changes._contexts)
        changes = store.changes()
        assert len(_changes._contexts) == before + 1
        await changes.aclose()
        return len(_changes._contexts) - before

    assert asyncio.run(main()) == 0


def test_letting_go_of_changes_cancels_its_subscription(store: Store) -> None:
    before = len(_changes._contexts)
    changes = store.changes()
    assert len(_changes._contexts) == before + 1

    del changes
    gc.collect()

    assert len(_changes._contexts) == before


def test_letting_go_of_changes_leaves_other_listeners_alone(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        changes = store.changes()
        del changes
        gc.collect()
        store.set("a", 1)

    assert [batch.keys for batch in batches] == [("a",)]


def test_a_task_waiting_on_changes_can_be_cancelled_and_the_iterator_used_again(
    store: Store,
) -> None:
    async def main() -> tuple[str, ...]:
        changes = store.changes()
        waiting = asyncio.ensure_future(anext(changes))
        await settle()
        await cancel(waiting)
        store.set("a", 1)
        batch = await next_of(changes)
        await changes.aclose()
        return batch.keys

    assert asyncio.run(main()) == ("a",)


def test_two_tasks_waiting_on_one_changes_iterator_raises(store: Store) -> None:
    async def main() -> None:
        changes = store.changes()
        first = asyncio.ensure_future(anext(changes))
        await settle()
        try:
            with pytest.raises(RuntimeError):
                await next_of(changes)
            assert not first.done()
        finally:
            await cancel(first)
            await changes.aclose()

    asyncio.run(main())


def test_the_first_task_keeps_waiting_after_a_second_was_refused(store: Store) -> None:
    async def main() -> tuple[str, ...]:
        changes = store.changes()
        first = asyncio.ensure_future(next_of(changes))
        await settle()
        with pytest.raises(RuntimeError):
            await next_of(changes)
        store.set("a", 1)
        batch = await first
        await changes.aclose()
        return batch.keys

    assert asyncio.run(main()) == ("a",)


def test_a_change_made_on_another_thread_wakes_the_waiting_task(store: Store) -> None:
    async def main() -> tuple[str, ...]:
        changes = store.changes()
        waiting = asyncio.ensure_future(next_of(changes))
        await settle()
        thread = threading.Thread(target=store.set, args=("a", 1))
        thread.start()
        batch = await waiting
        thread.join(TIMEOUT)
        assert not thread.is_alive()
        await changes.aclose()
        return batch.keys

    assert asyncio.run(main()) == ("a",)


def test_changes_from_several_threads_are_all_yielded(store: Store) -> None:
    threads, writes = 4, 50

    def write(number: int) -> None:
        for index in range(writes):
            store.set(f"{number}.{index}", index)

    async def main() -> set[str]:
        changes = store.changes()
        workers = [threading.Thread(target=write, args=(n,)) for n in range(threads)]
        for worker in workers:
            worker.start()
        keys: set[str] = set()
        while len(keys) < threads * writes:
            keys.update((await next_of(changes)).keys)
        for worker in workers:
            worker.join(TIMEOUT)
            assert not worker.is_alive()
        await changes.aclose()
        return keys

    assert asyncio.run(main()) == {f"{n}.{i}" for n in range(threads) for i in range(writes)}


# MARK: - values


def test_values_yields_the_current_value_first(store: Store) -> None:
    store.set("volume", 0.5)

    async def main() -> float | None:
        values = store.values("volume", float)
        value = await next_of(values)
        await values.aclose()
        return value

    assert asyncio.run(main()) == 0.5


def test_values_yields_the_value_after_each_change(store: Store) -> None:
    store.set("count", 0)

    async def main() -> list[int | None]:
        values = store.values("count", int)
        seen = [await next_of(values)]
        for count in (1, 2):
            store.set("count", count)
            seen.append(await next_of(values))
        await values.aclose()
        return seen

    assert asyncio.run(main()) == [0, 1, 2]


def test_values_yields_again_when_the_key_is_written_with_the_value_it_had(
    store: Store,
) -> None:
    store.set("count", 1)

    async def main() -> list[int | None]:
        values = store.values("count", int)
        seen = [await next_of(values)]
        store.set("count", 1)
        seen.append(await next_of(values))
        await values.aclose()
        return seen

    assert asyncio.run(main()) == [1, 1]


def test_values_yields_nothing_for_a_change_to_another_key(store: Store) -> None:
    async def main() -> int | None:
        values = store.values("count", int)
        await next_of(values)
        store.set("other", 1)
        store.set("count", 2)
        value = await next_of(values)
        await values.aclose()
        return value

    assert asyncio.run(main()) == 2


def test_values_skips_to_the_newest_value_when_the_consumer_falls_behind(
    store: Store,
) -> None:
    store.set("count", 0)

    async def main() -> list[int | None]:
        values = store.values("count", int)
        seen = [await next_of(values)]
        for count in (1, 2, 3):
            store.set("count", count)
        seen.append(await next_of(values))
        store.set("count", 4)
        seen.append(await next_of(values))
        await values.aclose()
        return seen

    assert asyncio.run(main()) == [0, 3, 4]


def test_values_of_a_missing_string_key_yields_none(store: Store) -> None:
    async def main() -> Any:
        values = store.values("count", int)
        value = await next_of(values)
        await values.aclose()
        return value

    assert asyncio.run(main()) is None


def test_values_of_a_missing_typed_key_yields_none(store: Store) -> None:
    async def main() -> Any:
        values = store.values(Key("count", int))
        value = await next_of(values)
        await values.aclose()
        return value

    assert asyncio.run(main()) is None


def test_values_of_a_removed_key_yields_none(store: Store) -> None:
    store.set("count", 1)

    async def main() -> Any:
        values = store.values("count", int)
        await next_of(values)
        store.remove("count")
        value = await next_of(values)
        await values.aclose()
        return value

    assert asyncio.run(main()) is None


def test_values_of_a_defaulted_key_yields_its_default_for_a_missing_value(
    store: Store,
) -> None:
    volume = Key("volume", float, default=0.5)

    async def main() -> list[float]:
        values = store.values(volume)
        seen = [await next_of(values)]
        store[volume] = 0.8
        seen.append(await next_of(values))
        store.remove(volume)
        seen.append(await next_of(values))
        await values.aclose()
        return seen

    assert asyncio.run(main()) == [0.5, 0.8, 0.5]


def test_values_reads_with_the_converter_it_is_given(store: Store) -> None:
    store.set("count", 7, swiftmmkv.uint32)

    async def main() -> int | None:
        values = store.values("count", swiftmmkv.uint32)
        value = await next_of(values)
        await values.aclose()
        return value

    assert asyncio.run(main()) == 7


def test_values_takes_a_type_for_a_string_key_and_none_for_a_typed_key(store: Store) -> None:
    with pytest.raises(TypeError):
        store.values("count")  # type: ignore[call-overload]
    with pytest.raises(TypeError):
        store.values(Key("count", int), int)  # type: ignore[call-overload]


def test_values_raises_the_converters_error_and_then_ends(store: Store) -> None:
    store.set("settings", "not json")

    async def main() -> bool:
        values = store.values("settings", swiftmmkv.JSON)
        with pytest.raises(json.JSONDecodeError):
            await next_of(values)
        return await ends(values)

    assert asyncio.run(main())


def test_values_raises_the_converters_error_for_a_later_value(store: Store) -> None:
    store.set("settings", "[]")

    async def main() -> bool:
        values = store.values("settings", swiftmmkv.JSON)
        assert await next_of(values) == []
        store.set("settings", "not json")
        with pytest.raises(json.JSONDecodeError):
            await next_of(values)
        store.set("settings", "[1]")
        return await ends(values)

    assert asyncio.run(main())


def test_values_ends_when_the_store_closes(store: Store) -> None:
    store.set("count", 1)

    async def main() -> bool:
        values = store.values("count", int)
        await next_of(values)
        store.close()
        return await ends(values)

    assert asyncio.run(main())


def test_closing_the_store_wakes_a_task_waiting_on_its_values(store: Store) -> None:
    async def main() -> bool:
        values = store.values("count", int)
        await next_of(values)
        waiting = asyncio.ensure_future(ends(values))
        await settle()
        store.close()
        return await waiting

    assert asyncio.run(main())


def test_values_of_a_closed_store_ends_at_once(store: Store) -> None:
    store.close()

    async def main() -> bool:
        return await ends(store.values("count", int))

    assert asyncio.run(main())


def test_values_yields_nothing_while_the_store_is_suspended(multi_process: Store) -> None:
    multi_process.set("count", 1)

    async def main() -> tuple[bool, int | None]:
        values = multi_process.values("count", int)
        # The first value is waiting when the store is suspended.
        multi_process.suspend()
        waiting = asyncio.ensure_future(next_of(values))
        await settle()
        done_while_suspended = waiting.done()
        multi_process.resume()
        value = await waiting
        await values.aclose()
        return done_while_suspended, value

    assert asyncio.run(main()) == (False, 1)


def test_values_yields_the_value_again_when_the_store_resumes(multi_process: Store) -> None:
    multi_process.set("count", 1)

    async def main() -> list[int | None]:
        values = multi_process.values("count", int)
        seen = [await next_of(values)]
        multi_process.suspend()
        waiting = asyncio.ensure_future(next_of(values))
        await settle()
        multi_process.resume()
        seen.append(await waiting)
        await values.aclose()
        return seen

    assert asyncio.run(main()) == [1, 1]


def test_closing_values_ends_the_iteration(store: Store) -> None:
    async def main() -> bool:
        values = store.values("count", int)
        await values.aclose()
        store.set("count", 1)
        return await ends(values)

    assert asyncio.run(main())


def test_closing_values_wakes_a_task_waiting_on_it(store: Store) -> None:
    async def main() -> bool:
        values = store.values("count", int)
        await next_of(values)
        waiting = asyncio.ensure_future(ends(values))
        await settle()
        await values.aclose()
        return await waiting

    assert asyncio.run(main())


def test_letting_go_of_values_cancels_its_subscription(store: Store) -> None:
    before = len(_changes._contexts)
    values = store.values("count", int)
    assert len(_changes._contexts) == before + 1

    del values
    gc.collect()

    assert len(_changes._contexts) == before


def test_a_change_made_on_another_thread_wakes_a_task_waiting_on_values(store: Store) -> None:
    async def main() -> int | None:
        values = store.values("count", int)
        await next_of(values)
        waiting = asyncio.ensure_future(next_of(values))
        await settle()
        thread = threading.Thread(target=store.set, args=("count", 5))
        thread.start()
        value = await waiting
        thread.join(TIMEOUT)
        assert not thread.is_alive()
        await values.aclose()
        return value

    assert asyncio.run(main()) == 5


def test_a_task_waiting_on_values_can_be_cancelled_and_the_iterator_used_again(
    store: Store,
) -> None:
    async def main() -> int | None:
        values = store.values("count", int)
        await next_of(values)
        waiting = asyncio.ensure_future(anext(values))
        await settle()
        await cancel(waiting)
        store.set("count", 2)
        value = await next_of(values)
        await values.aclose()
        return value

    assert asyncio.run(main()) == 2


def test_two_tasks_waiting_on_one_values_iterator_raises(store: Store) -> None:
    async def main() -> None:
        values = store.values("count", int)
        await next_of(values)
        first = asyncio.ensure_future(anext(values))
        await settle()
        try:
            with pytest.raises(RuntimeError):
                await next_of(values)
        finally:
            await cancel(first)
            await values.aclose()

    asyncio.run(main())
