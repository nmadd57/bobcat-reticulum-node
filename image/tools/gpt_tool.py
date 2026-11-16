#!/usr/bin/env python3
"""Append a partition to a GPT disk image, or check an image's GPT.

  gpt_tool.py add   IMAGE --name NAME --size-mib N [--number 7]
  gpt_tool.py check IMAGE

`add` extends the image file so the new partition fits after the last existing
one, writes the partition entry, and rewrites the primary and backup headers
(CRCs included). The existing partitions and their data are not touched.
Prints "<start byte> <size bytes>" of the new partition.
"""

import argparse
import struct
import sys
import uuid
import zlib

SECTOR = 512
MIB = 1024 * 1024
# Microsoft basic data: what Windows, macOS and Linux all mount as plain FAT.
BASIC_DATA = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"

HDR_FMT = "<8sIIIIQQQQ16sQIII"      # 92 bytes
HDR_LEN = struct.calcsize(HDR_FMT)


class GptError(Exception):
    pass


def read_header(f, lba):
    f.seek(lba * SECTOR)
    raw = f.read(HDR_LEN)
    if len(raw) < HDR_LEN:
        raise GptError(f"no header at LBA {lba}")
    (sig, rev, hsize, hcrc, _res, cur, bak, first, last, guid,
     ent_lba, n_ent, ent_size, ent_crc) = struct.unpack(HDR_FMT, raw)
    if sig != b"EFI PART":
        raise GptError(f"no GPT signature at LBA {lba}")
    zeroed = raw[:16] + b"\0\0\0\0" + raw[20:]
    if zlib.crc32(zeroed[:hsize]) & 0xFFFFFFFF != hcrc:
        raise GptError(f"header CRC mismatch at LBA {lba}")
    return {"rev": rev, "hsize": hsize, "cur": cur, "bak": bak, "first": first,
            "last": last, "guid": guid, "ent_lba": ent_lba, "n_ent": n_ent,
            "ent_size": ent_size, "ent_crc": ent_crc}


def read_entries(f, h):
    f.seek(h["ent_lba"] * SECTOR)
    data = f.read(h["n_ent"] * h["ent_size"])
    if len(data) != h["n_ent"] * h["ent_size"]:
        raise GptError("partition entry array is truncated")
    if zlib.crc32(data) & 0xFFFFFFFF != h["ent_crc"]:
        raise GptError("partition entry array CRC mismatch")
    return bytearray(data)


def parse_entries(data, size):
    out = []
    for i in range(len(data) // size):
        e = data[i * size:(i + 1) * size]
        if e[:16] == b"\0" * 16:
            continue
        first, last = struct.unpack("<QQ", e[32:48])
        out.append((i + 1, first, last, e[56:128].decode("utf-16le").rstrip("\0")))
    return out


def pack_header(h, cur, bak, ent_lba, ent_crc):
    raw = struct.pack(HDR_FMT, b"EFI PART", h["rev"], HDR_LEN, 0, 0, cur, bak,
                      h["first"], h["last"], h["guid"], ent_lba, h["n_ent"],
                      h["ent_size"], ent_crc)
    crc = zlib.crc32(raw) & 0xFFFFFFFF
    raw = raw[:16] + struct.pack("<I", crc) + raw[20:]
    return raw.ljust(SECTOR, b"\0")


def check(path):
    with open(path, "rb") as f:
        f.seek(0, 2)
        total = f.tell() // SECTOR
        prim = read_header(f, 1)
        ents = read_entries(f, prim)
        back = read_header(f, total - 1)
        bents = read_entries(f, back)
        if bents != ents:
            raise GptError("primary and backup partition arrays differ")
        if prim["bak"] != total - 1 or back["cur"] != total - 1 or back["bak"] != 1:
            raise GptError("header LBAs do not match the file size")
        parts = parse_entries(ents, prim["ent_size"])
        prev_end = 0
        for number, first, last, name in sorted(parts, key=lambda p: p[1]):
            if first <= prev_end and prev_end:
                raise GptError(f"partition {number} ({name}) overlaps the previous one")
            if first < prim["first"] or last > prim["last"]:
                raise GptError(f"partition {number} ({name}) is outside the usable area")
            prev_end = last
    return parts


def add(path, name, size_mib, number):
    size_sectors = size_mib * MIB // SECTOR
    with open(path, "r+b") as f:
        prim = read_header(f, 1)
        ents = read_entries(f, prim)
        existing = parse_entries(ents, prim["ent_size"])
        if not 1 <= number <= prim["n_ent"]:
            raise GptError("partition number out of range")
        slot = (number - 1) * prim["ent_size"]
        if ents[slot:slot + 16] != b"\0" * 16:
            raise GptError(f"partition {number} is already in use")
        if any(n == name for _, _, _, n in existing):
            raise GptError(f"a partition named {name!r} already exists")

        align = MIB // SECTOR
        start = max(last for _, _, last, _ in existing) + 1
        start = (start + align - 1) // align * align
        end = start + size_sectors - 1
        ent_sectors = (prim["n_ent"] * prim["ent_size"] + SECTOR - 1) // SECTOR
        # room after the partition for the backup entry array and header, rounded to 1 MiB
        total = (end + 1 + ent_sectors + 1 + align - 1) // align * align

        entry = bytearray(prim["ent_size"])
        entry[0:16] = uuid.UUID(BASIC_DATA).bytes_le
        entry[16:32] = uuid.uuid4().bytes_le
        struct.pack_into("<QQQ", entry, 32, start, end, 0)
        entry[56:56 + 72] = name.encode("utf-16le")[:72].ljust(72, b"\0")
        ents[slot:slot + prim["ent_size"]] = entry
        ent_crc = zlib.crc32(bytes(ents)) & 0xFFFFFFFF

        prim["last"] = total - 1 - ent_sectors - 1
        if end > prim["last"]:
            raise GptError("internal error: partition does not fit")

        # The old backup header and entry array sit between the last partition
        # and the new one; once the disk grows they are stale, so clear them.
        old_last = max(last for _, _, last, _ in existing)
        gap = start - (old_last + 1)
        if gap > 0:
            f.seek((old_last + 1) * SECTOR)
            f.write(b"\0" * (gap * SECTOR))

        f.truncate(total * SECTOR)
        back_ents_lba = total - 1 - ent_sectors
        f.seek(back_ents_lba * SECTOR)
        f.write(bytes(ents).ljust(ent_sectors * SECTOR, b"\0"))
        f.seek((total - 1) * SECTOR)
        f.write(pack_header(prim, total - 1, 1, back_ents_lba, ent_crc))

        f.seek(prim["ent_lba"] * SECTOR)
        f.write(bytes(ents))
        f.seek(1 * SECTOR)
        f.write(pack_header(prim, 1, total - 1, prim["ent_lba"], ent_crc))

        # Protective MBR: keep it describing the whole (now larger) disk.
        f.seek(446)
        mbr = bytearray(f.read(16))
        if mbr[4] == 0xEE:
            struct.pack_into("<II", mbr, 8, 1, min(total - 1, 0xFFFFFFFF))
            f.seek(446)
            f.write(mbr)
    return start * SECTOR, size_sectors * SECTOR


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add")
    a.add_argument("image")
    a.add_argument("--name", required=True)
    a.add_argument("--size-mib", type=int, required=True)
    a.add_argument("--number", type=int, default=7)
    c = sub.add_parser("check")
    c.add_argument("image")
    args = ap.parse_args()
    try:
        if args.cmd == "add":
            start, size = add(args.image, args.name, args.size_mib, args.number)
            check(args.image)
            print(start, size)
        else:
            for number, first, last, name in check(args.image):
                print(f"{number}\t{first * SECTOR}\t{(last - first + 1) * SECTOR}\t{name}")
    except GptError as exc:
        sys.exit(f"gpt_tool: {exc}")


if __name__ == "__main__":
    main()
