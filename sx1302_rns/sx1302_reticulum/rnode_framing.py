"""RNode-compatible LoRa framing.

RNode firmware prepends one header byte to every LoRa frame it transmits and
strips one from every frame it receives. Without that byte a raw LoRa node
and an RNode hear each other's radio signal but discard each other's data.

Header byte layout (from markqvist/RNode_Firmware ``Framing.h``, ``Utilities.h``
and ``RNode_Firmware.ino``):

* upper nibble (``NIBBLE_SEQ`` 0xF0): a random sequence number. The firmware
  uses ``random(256) & 0xF0`` and reads it back as ``header >> 4``.
* lowest bit (``FLAG_SPLIT`` 0x01): set when the Reticulum packet was split
  over two radio frames.
* the other bits are written as zero and ignored on receive.

A Reticulum packet of up to ``MAX_PAYLOAD`` (254) bytes goes out in one frame:
``header + payload`` (at most 255 bytes, the LoRa/HAL limit). A larger one,
up to ``MTU`` (508) bytes, goes out in two frames that carry the same header
with ``FLAG_SPLIT`` set: the first holds 254 payload bytes and the second
holds the rest.

Receive-side reassembly mirrors ``receive_callback()`` in the firmware:

* split frame, nothing pending: remember its sequence and keep the data;
* split frame, same sequence as the pending one: append it and deliver;
* split frame, different sequence: drop the pending data, start over with it;
* any non-split frame: drop pending data and deliver the frame as it is.

Like the firmware, there is no timeout on a pending first half. It is replaced
by the next frame that does not complete it.
"""

from __future__ import annotations

import os

HEADER_L = 1
SINGLE_MTU = 255
MAX_PAYLOAD = SINGLE_MTU - HEADER_L  # 254
MTU = 2 * MAX_PAYLOAD  # 508

FLAG_SPLIT = 0x01
NIBBLE_SEQ = 0xF0
SEQ_UNSET = 0xFF


def _random_header(rand: int | None = None) -> int:
    value = os.urandom(1)[0] if rand is None else rand
    return value & NIBBLE_SEQ


def encode(payload: bytes, rand: int | None = None) -> list[bytes]:
    """Return the radio frames that carry ``payload``.

    ``rand`` fixes the random byte for tests. Empty payloads produce no frames.
    """
    size = len(payload)
    if size == 0:
        return []
    if size > MTU:
        raise ValueError(f"payload of {size} bytes exceeds the {MTU}-byte RNode MTU")

    header = _random_header(rand)
    if size <= MAX_PAYLOAD:
        return [bytes([header]) + bytes(payload)]

    header |= FLAG_SPLIT
    return [
        bytes([header]) + bytes(payload[:MAX_PAYLOAD]),
        bytes([header]) + bytes(payload[MAX_PAYLOAD:]),
    ]


class Reassembler:
    """Strip the RNode header from received frames and join split packets."""

    def __init__(self) -> None:
        self._seq = SEQ_UNSET
        self._buffer = b""

    def reset(self) -> None:
        self._seq = SEQ_UNSET
        self._buffer = b""

    def feed(self, frame: bytes) -> bytes | None:
        """Return a complete Reticulum packet, or ``None`` if more is needed."""
        if len(frame) < HEADER_L:
            return None

        header = frame[0]
        data = bytes(frame[HEADER_L:])
        sequence = header >> 4

        if header & FLAG_SPLIT:
            if self._seq == SEQ_UNSET or self._seq != sequence:
                self._seq = sequence
                self._buffer = data
                return None
            packet = self._buffer + data
            self.reset()
            return packet or None

        self.reset()
        return data or None
