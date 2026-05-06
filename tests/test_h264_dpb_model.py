from __future__ import annotations

from scripts.h264_dpb_model import FrameSpec, simulate_dpb_timeline


def test_simulate_dpb_timeline_tracks_bref_as_future_reference() -> None:
    frames = [
        FrameSpec(display_idx=0, poc_lsb=0, frame_num=0, is_idr=True, is_reference=True),
        FrameSpec(display_idx=2, poc_lsb=4, frame_num=1, is_bref=True, is_reference=True),
        FrameSpec(display_idx=1, poc_lsb=2, frame_num=1, is_b=True, is_reference=False),
        FrameSpec(display_idx=4, poc_lsb=8, frame_num=2, is_bref=True, is_reference=True),
        FrameSpec(display_idx=3, poc_lsb=6, frame_num=2, is_b=True, is_reference=False),
    ]

    timeline = simulate_dpb_timeline(frames, max_short_term_refs=4)

    first_b = timeline[2]
    assert first_b.bank_id is None
    assert first_b.dpb_before == first_b.dpb_after
    assert first_b.current_list0 == (0, 1)
    assert first_b.current_list1 == (1, 0)
    assert first_b.colocated_bank == timeline[1].bank_id

    second_b = timeline[4]
    assert second_b.bank_id is None
    assert second_b.dpb_before == second_b.dpb_after
    assert second_b.current_list0 == (1, 0, 2)
    assert second_b.current_list1 == (2, 1, 0)
    assert second_b.colocated_bank == timeline[3].bank_id


def test_simulate_dpb_timeline_swaps_identical_list1_when_only_past_refs_exist() -> None:
    timeline = simulate_dpb_timeline(
        [
            FrameSpec(display_idx=0, poc_lsb=0, frame_num=0, is_idr=True, is_reference=True),
            FrameSpec(display_idx=2, poc_lsb=2, frame_num=1, is_reference=True),
            FrameSpec(display_idx=4, poc_lsb=4, frame_num=2, is_reference=True),
            FrameSpec(display_idx=6, poc_lsb=6, frame_num=2, is_b=True, is_reference=False),
        ],
        max_short_term_refs=4,
    )

    last_b = timeline[3]
    assert last_b.current_list0 == (2, 1, 0)
    assert last_b.current_list1 == (1, 2, 0)
    assert last_b.current_list0 != last_b.current_list1
    assert last_b.colocated_bank == 1


def test_non_reference_b_picture_does_not_change_dpb_or_bank_rotation() -> None:
    timeline = simulate_dpb_timeline(
        [
            FrameSpec(display_idx=0, poc_lsb=0, frame_num=0, is_idr=True, is_reference=True),
            FrameSpec(display_idx=2, poc_lsb=2, frame_num=1, is_reference=True),
            FrameSpec(display_idx=1, poc_lsb=1, frame_num=1, is_b=True, is_reference=False),
            FrameSpec(display_idx=4, poc_lsb=4, frame_num=2, is_reference=True),
        ],
        max_short_term_refs=4,
    )

    b_frame = timeline[2]
    assert b_frame.bank_id is None
    assert b_frame.dpb_before == b_frame.dpb_after
    assert b_frame.current_list0 == (0, 1)
    assert b_frame.current_list1 == (1, 0)
    assert b_frame.colocated_bank == 1


def test_simulate_dpb_timeline_evicts_oldest_short_term_reference_when_limit_is_one() -> None:
    timeline = simulate_dpb_timeline(
        [
            FrameSpec(display_idx=0, poc_lsb=0, frame_num=0, is_idr=True, is_reference=True),
            FrameSpec(display_idx=2, poc_lsb=2, frame_num=1, is_reference=True),
            FrameSpec(display_idx=4, poc_lsb=4, frame_num=2, is_reference=True),
        ],
        max_short_term_refs=1,
    )

    first_ref = timeline[0]
    second_ref = timeline[1]
    third_ref = timeline[2]

    assert [pic.bank_id for pic in first_ref.dpb_after] == [0]
    assert [pic.bank_id for pic in second_ref.dpb_before] == [0]
    assert [pic.bank_id for pic in second_ref.dpb_after] == [0]
    assert second_ref.marking_actions == (
        'evict bank=0 frame_num=0 poc=0',
        'insert bank=0 frame_num=1 poc=2',
    )
    assert [pic.bank_id for pic in third_ref.dpb_after] == [0]
    assert third_ref.marking_actions == (
        'evict bank=0 frame_num=1 poc=2',
        'insert bank=0 frame_num=2 poc=4',
    )
