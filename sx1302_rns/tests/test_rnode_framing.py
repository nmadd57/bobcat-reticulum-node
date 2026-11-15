"""RNode framing: header byte layout, splitting and reassembly."""

import pytest

from sx1302_reticulum import rnode_framing as rf


def test_constants_match_rnode_firmware():
    assert rf.HEADER_L == 1
    assert rf.SINGLE_MTU == 255
    assert rf.MAX_PAYLOAD == 254
    assert rf.MTU == 508
    assert rf.FLAG_SPLIT == 0x01
    assert rf.NIBBLE_SEQ == 0xF0
    assert rf.SEQ_UNSET == 0xFF


def test_single_frame_header_is_random_upper_nibble():
    (frame,) = rf.encode(b"abc", rand=0xB7)
    assert frame == b"\xb0abc"  # random(256) & 0xF0, no split flag

    for _ in range(50):
        (frame,) = rf.encode(b"abc")
        assert frame[0] & 0x0F == 0
        assert frame[1:] == b"abc"


def test_largest_single_frame_is_255_bytes():
    (frame,) = rf.encode(b"x" * 254, rand=0x10)
    assert len(frame) == 255


def test_split_into_two_frames_with_same_header():
    payload = bytes(range(256)) + bytes(range(100))  # 356 bytes
    first, second = rf.encode(payload, rand=0x5A)
    assert first[0] == second[0] == 0x51  # 0x50 | FLAG_SPLIT
    assert len(first) == 255
    assert first[1:] + second[1:] == payload
    assert len(second) == 1 + 356 - 254


def test_mtu_boundaries():
    first, second = rf.encode(b"q" * 508, rand=0)
    assert len(first) == len(second) == 255
    with pytest.raises(ValueError):
        rf.encode(b"q" * 509)


def test_empty_payload_produces_no_frames():
    assert rf.encode(b"") == []


@pytest.mark.parametrize("size", [1, 100, 254, 255, 300, 508])
def test_encode_then_reassemble_roundtrip(size):
    payload = bytes((i * 7) & 0xFF for i in range(size))
    reassembler = rf.Reassembler()
    out = None
    for frame in rf.encode(payload):
        out = reassembler.feed(frame)
    assert out == payload


def test_split_first_half_waits():
    reassembler = rf.Reassembler()
    assert reassembler.feed(b"\x31" + b"A" * 254) is None
    assert reassembler.feed(b"\x31" + b"B" * 6) == b"A" * 254 + b"B" * 6


def test_mismatched_sequence_restarts_as_new_first_half():
    reassembler = rf.Reassembler()
    assert reassembler.feed(b"\x11" + b"old") is None
    assert reassembler.feed(b"\x21" + b"new1") is None  # new first half
    assert reassembler.feed(b"\x21" + b"new2") == b"new1new2"


def test_non_split_frame_clears_pending_and_delivers():
    reassembler = rf.Reassembler()
    assert reassembler.feed(b"\x11" + b"half") is None
    assert reassembler.feed(b"\x40" + b"whole") == b"whole"
    # The old pending half is gone, so a stray second half starts over.
    assert reassembler.feed(b"\x11" + b"tail") is None


def test_empty_and_header_only_frames_are_ignored():
    reassembler = rf.Reassembler()
    assert reassembler.feed(b"") is None
    assert reassembler.feed(b"\x50") is None


def test_low_header_bits_other_than_split_are_ignored():
    reassembler = rf.Reassembler()
    assert reassembler.feed(b"\x5e" + b"data") == b"data"
