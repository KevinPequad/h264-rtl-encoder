"""Deterministic H.264 DPB / reference-list timeline model.

This module is intentionally small and pure-Python so the B/DPB lane can be
reasoned about without touching RTL. It models the current progressive,
short-term-only target well enough to drive unit tests for:

- DPB insertion / eviction / flush behavior
- B / BREF default List0 and List1 construction
- colocated-picture selection for direct-mode edge cases
- list1 identical-to-list0 swap behavior when only one side of the POC window
  exists

The model is not a full H.264 decoder. Long-term references, fields, and MMCO
syntax are intentionally left as future extensions.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Iterable, Sequence

__all__ = [
    "FrameSpec",
    "DpbPicture",
    "TimelineEntry",
    "build_default_lists",
    "simulate_dpb_timeline",
    "timeline_to_dict",
]


@dataclass(frozen=True, slots=True)
class FrameSpec:
    """Input specification for a single encoded picture."""

    display_idx: int
    poc_lsb: int
    frame_num: int
    is_idr: bool = False
    is_reference: bool = False
    is_bref: bool = False
    is_b: bool = False
    poc: int | None = None
    active_ref_count_l0: int | None = None
    active_ref_count_l1: int | None = None
    requested_list0: tuple[int, ...] | None = None
    requested_list1: tuple[int, ...] | None = None

    @property
    def resolved_poc(self) -> int:
        return self.poc if self.poc is not None else self.poc_lsb

    @property
    def is_b_picture(self) -> bool:
        return self.is_b or self.is_bref

    @property
    def is_reference_picture(self) -> bool:
        return self.is_idr or self.is_reference or self.is_bref

    @property
    def nal_ref_idc(self) -> int:
        return 1 if self.is_reference_picture else 0


@dataclass(frozen=True, slots=True)
class DpbPicture:
    """State for one decoded picture buffer entry."""

    bank_id: int
    encode_idx: int
    display_idx: int
    poc: int
    poc_lsb: int
    frame_num: int
    frame_num_wrap: int
    pic_num: int
    is_reference: bool
    is_short_term: bool = True
    is_long_term: bool = False
    is_idr: bool = False
    is_bref: bool = False
    nal_ref_idc: int = 1
    long_term_frame_idx: int | None = None


@dataclass(frozen=True, slots=True)
class TimelineEntry:
    """Model output for a single picture in encode order."""

    frame: FrameSpec
    dpb_before: tuple[DpbPicture, ...]
    dpb_after: tuple[DpbPicture, ...]
    bank_id: int | None
    default_list0: tuple[int, ...]
    default_list1: tuple[int, ...]
    selected_list0: tuple[int, ...]
    selected_list1: tuple[int, ...]
    colocated_bank: int | None
    marking_actions: tuple[str, ...]
    num_ref_idx_l0_active_minus1: int
    num_ref_idx_l1_active_minus1: int | None
    reordering_required_l0: bool
    reordering_required_l1: bool

    @property
    def current_list0(self) -> tuple[int, ...]:
        return self.selected_list0

    @property
    def current_list1(self) -> tuple[int, ...]:
        return self.selected_list1


@dataclass(frozen=True, slots=True)
class _BankAllocator:
    next_bank_id: int = 0
    available_bank_ids: tuple[int, ...] = ()

    def acquire(self) -> tuple[int, "_BankAllocator"]:
        if self.available_bank_ids:
            bank_id = self.available_bank_ids[0]
            remaining = self.available_bank_ids[1:]
            return bank_id, _BankAllocator(self.next_bank_id, remaining)
        bank_id = self.next_bank_id
        return bank_id, _BankAllocator(self.next_bank_id + 1, self.available_bank_ids)

    def release_many(self, bank_ids: Iterable[int]) -> "_BankAllocator":
        merged = sorted(set(self.available_bank_ids).union(bank_ids))
        return _BankAllocator(self.next_bank_id, tuple(merged))


def _resolve_poc(frame: FrameSpec) -> int:
    return frame.resolved_poc


def _frame_num_wrap(frame_num: int, max_frame_num: int) -> int:
    if max_frame_num < 1:
        raise ValueError("max_frame_num must be >= 1")
    return frame_num % max_frame_num


def _short_term_pic_num(pic: DpbPicture, current_frame_num: int, max_frame_num: int) -> int:
    """Return stateful short-term PicNum/order value for this model.

    Frame numbers in slice syntax wrap modulo MaxFrameNum, but this timeline
    model keeps a stateful unwrapped frame number in DpbPicture.frame_num.
    Ordering by the unwrapped value preserves reference age across repeated
    modulo cycles; reducing both sides with % max_frame_num collapses refs
    from different cycles and can make stale pictures look newest.
    """

    _ = (current_frame_num, max_frame_num)
    return pic.frame_num


def _sort_short_term_for_p(
    active_refs: Sequence[DpbPicture], current_frame_num: int, max_frame_num: int
) -> tuple[DpbPicture, ...]:
    return tuple(
        sorted(
            active_refs,
            key=lambda pic: (
                -_short_term_pic_num(pic, current_frame_num, max_frame_num),
                -pic.poc,
                -pic.bank_id,
            ),
        )
    )


def _sort_past_refs(
    active_refs: Sequence[DpbPicture], current_poc: int, current_frame_num: int, max_frame_num: int
) -> tuple[DpbPicture, ...]:
    past_refs = [pic for pic in active_refs if pic.poc < current_poc]
    return tuple(
        sorted(
            past_refs,
            key=lambda pic: (
                -pic.poc,
                -_short_term_pic_num(pic, current_frame_num, max_frame_num),
                -pic.bank_id,
            ),
        )
    )


def _sort_future_refs(
    active_refs: Sequence[DpbPicture], current_poc: int, current_frame_num: int, max_frame_num: int
) -> tuple[DpbPicture, ...]:
    future_refs = [pic for pic in active_refs if pic.poc > current_poc]
    return tuple(
        sorted(
            future_refs,
            key=lambda pic: (
                pic.poc,
                -_short_term_pic_num(pic, current_frame_num, max_frame_num),
                pic.bank_id,
            ),
        )
    )


def _bank_ids(pictures: Sequence[DpbPicture]) -> tuple[int, ...]:
    return tuple(pic.bank_id for pic in pictures)


def _truncate_list(ref_list: tuple[int, ...], active_count: int | None, list_name: str) -> tuple[int, ...]:
    if active_count is None:
        return ref_list
    if active_count < 1:
        raise ValueError(f"{list_name} active ref count must be >= 1")
    if active_count > len(ref_list):
        raise ValueError(
            f"{list_name} active ref count {active_count} exceeds available references {len(ref_list)}"
        )
    return ref_list[:active_count]


def _validate_requested_list(requested: tuple[int, ...], default_list: tuple[int, ...], list_name: str) -> None:
    if len(requested) != len(set(requested)):
        raise ValueError(f"{list_name} contains duplicate bank ids: {requested}")
    missing = set(requested) - set(default_list)
    if missing:
        raise ValueError(f"{list_name} references banks not present in the current DPB: {sorted(missing)}")


def _build_selected_list(
    *,
    default_list: tuple[int, ...],
    requested_list: tuple[int, ...] | None,
    active_count: int | None,
    list_name: str,
) -> tuple[tuple[int, ...], bool]:
    if requested_list is None:
        selected = default_list
        reordering_required = False
    else:
        requested = tuple(requested_list)
        _validate_requested_list(requested, default_list, list_name)
        selected = requested
        reordering_required = requested != default_list
    selected = _truncate_list(selected, active_count, list_name)
    if not selected:
        raise ValueError(f"{list_name} selects zero reference pictures")
    return selected, reordering_required


def build_default_lists(
    active_refs: Sequence[DpbPicture],
    current_poc: int,
    current_pic_num: int,
    *,
    is_b_picture: bool,
    max_frame_num: int = 1 << 8,
) -> tuple[tuple[int, ...], tuple[int, ...]]:
    """Return the standard default List0/List1 bank order for a picture."""

    if is_b_picture:
        past_refs = _sort_past_refs(active_refs, current_poc, current_pic_num, max_frame_num)
        future_refs = _sort_future_refs(active_refs, current_poc, current_pic_num, max_frame_num)
        list0 = _bank_ids(past_refs + future_refs)
        list1 = _bank_ids(future_refs + past_refs)
        if len(list1) > 1 and list1 == list0:
            list1 = (list1[1], list1[0], *list1[2:])
        return list0, list1

    short_term_refs = _sort_short_term_for_p(active_refs, current_pic_num, max_frame_num)
    return _bank_ids(short_term_refs), ()


def _evict_oldest_short_term(
    active_refs: list[DpbPicture], current_frame_num: int, max_frame_num: int
) -> tuple[DpbPicture | None, list[DpbPicture]]:
    if not active_refs:
        return None, active_refs
    oldest = min(
        active_refs,
        key=lambda pic: (_short_term_pic_num(pic, current_frame_num, max_frame_num), pic.poc, pic.bank_id),
    )
    active_refs.remove(oldest)
    return oldest, active_refs


def simulate_dpb_timeline(
    frames: Sequence[FrameSpec],
    *,
    max_short_term_refs: int = 4,
    max_frame_num: int = 1 << 8,
) -> list[TimelineEntry]:
    """Simulate the DPB state evolution for a sequence of pictures.

    The model keeps only short-term references, which is enough for the current
    B/BREF lane and the accompanying unit tests.
    """

    if max_short_term_refs < 1:
        raise ValueError("max_short_term_refs must be >= 1")
    if max_frame_num < 1:
        raise ValueError("max_frame_num must be >= 1")

    active_refs: list[DpbPicture] = []
    allocator = _BankAllocator()
    timeline: list[TimelineEntry] = []
    frame_num_offset = 0
    previous_frame_num_wrap: int | None = None

    for encode_idx, frame in enumerate(frames):
        poc = _resolve_poc(frame)
        frame_num_wrap = _frame_num_wrap(frame.frame_num, max_frame_num)
        if frame.is_idr:
            frame_num_offset = 0
            previous_frame_num_wrap = None
        if previous_frame_num_wrap is not None and frame_num_wrap < previous_frame_num_wrap:
            frame_num_offset += max_frame_num
        previous_frame_num_wrap = frame_num_wrap
        current_frame_num = frame_num_offset + frame_num_wrap
        dpb_before = tuple(active_refs)

        if frame.is_idr:
            default_list0 = ()
            default_list1 = ()
            selected_list0 = ()
            selected_list1 = ()
            reordering_required_l0 = False
            reordering_required_l1 = False
            colocated_bank = None
            if active_refs:
                allocator = allocator.release_many(pic.bank_id for pic in active_refs)
                active_refs = []
        else:
            default_list0, default_list1 = build_default_lists(
                active_refs,
                poc,
                current_frame_num,
                is_b_picture=frame.is_b_picture,
                max_frame_num=max_frame_num,
            )
            selected_list0, reordering_required_l0 = _build_selected_list(
                default_list=default_list0,
                requested_list=frame.requested_list0,
                active_count=frame.active_ref_count_l0,
                list_name="List0",
            )
            if frame.is_b_picture:
                selected_list1, reordering_required_l1 = _build_selected_list(
                    default_list=default_list1,
                    requested_list=frame.requested_list1,
                    active_count=frame.active_ref_count_l1,
                    list_name="List1",
                )
            else:
                selected_list1 = ()
                reordering_required_l1 = False
            colocated_bank = selected_list1[0] if frame.is_b_picture and selected_list1 else None

        marking_actions: list[str] = []
        bank_id: int | None = None

        if frame.is_reference_picture and not frame.is_idr:
            while len(active_refs) >= max_short_term_refs:
                evicted, active_refs = _evict_oldest_short_term(active_refs, current_frame_num, max_frame_num)
                if evicted is None:
                    break
                allocator = allocator.release_many((evicted.bank_id,))
                marking_actions.append(
                    f"evict bank={evicted.bank_id} frame_num={evicted.frame_num} poc={evicted.poc}"
                )

            bank_id, allocator = allocator.acquire()
            new_picture = DpbPicture(
                bank_id=bank_id,
                encode_idx=encode_idx,
                display_idx=frame.display_idx,
                poc=poc,
                poc_lsb=frame.poc_lsb,
                frame_num=current_frame_num,
                frame_num_wrap=frame_num_wrap,
                pic_num=current_frame_num,
                is_reference=True,
                is_short_term=True,
                is_long_term=False,
                is_idr=False,
                is_bref=frame.is_bref,
                nal_ref_idc=frame.nal_ref_idc,
                long_term_frame_idx=None,
            )
            active_refs.append(new_picture)
            active_refs.sort(key=lambda pic: (pic.frame_num, pic.poc, pic.bank_id))
            marking_actions.append(f"insert bank={bank_id} frame_num={frame.frame_num} poc={poc}")
        elif frame.is_idr:
            bank_id, allocator = allocator.acquire()
            new_picture = DpbPicture(
                bank_id=bank_id,
                encode_idx=encode_idx,
                display_idx=frame.display_idx,
                poc=poc,
                poc_lsb=frame.poc_lsb,
                frame_num=current_frame_num,
                frame_num_wrap=frame_num_wrap,
                pic_num=current_frame_num,
                is_reference=True,
                is_short_term=True,
                is_long_term=False,
                is_idr=True,
                is_bref=frame.is_bref,
                nal_ref_idc=frame.nal_ref_idc,
                long_term_frame_idx=None,
            )
            active_refs.append(new_picture)
            active_refs.sort(key=lambda pic: (pic.frame_num, pic.poc, pic.bank_id))
            marking_actions.append(f"idr_reset bank={bank_id} frame_num={frame.frame_num} poc={poc}")

        dpb_after = tuple(active_refs)

        timeline.append(
            TimelineEntry(
                frame=frame,
                dpb_before=dpb_before,
                dpb_after=dpb_after,
                bank_id=bank_id if frame.is_reference_picture else None,
                default_list0=default_list0,
                default_list1=default_list1,
                selected_list0=selected_list0,
                selected_list1=selected_list1,
                colocated_bank=colocated_bank,
                marking_actions=tuple(marking_actions),
                num_ref_idx_l0_active_minus1=max(0, len(selected_list0) - 1),
                num_ref_idx_l1_active_minus1=(max(0, len(selected_list1) - 1) if frame.is_b_picture else None),
                reordering_required_l0=reordering_required_l0,
                reordering_required_l1=reordering_required_l1,
            )
        )

    return timeline


def timeline_to_dict(timeline: Sequence[TimelineEntry]) -> list[dict[str, object]]:
    """Convert a timeline to plain Python objects for logging or JSON export."""

    return [asdict(entry) for entry in timeline]
