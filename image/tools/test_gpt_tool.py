"""Tests for gpt_tool.py using a synthetic GPT disk image."""

import struct
import subprocess
import sys
import uuid
import zlib
from pathlib import Path

import pytest

TOOL = Path(__file__).with_name("gpt_tool.py")
SECTOR = 512
MIB = 1024 * 1024
HDR = "<8sIIIIQQQQ16sQIII"


def build_disk(path, parts, total_sectors, with_backup=True):
    """parts: list of (number, first_lba, last_lba, name). 128 entries of 128 bytes."""
    n_ent, ent_size = 128, 128
    entries = bytearray(n_ent * ent_size)
    for number, first, last, name in parts:
        e = bytearray(ent_size)
        e[0:16] = uuid.uuid4().bytes_le
        e[16:32] = uuid.uuid4().bytes_le
        struct.pack_into("<QQQ", e, 32, first, last, 0)
        e[56:56 + 72] = name.encode("utf-16le").ljust(72, b"\0")
        entries[(number - 1) * ent_size:number * ent_size] = e
    ent_crc = zlib.crc32(bytes(entries)) & 0xFFFFFFFF
    ent_sectors = n_ent * ent_size // SECTOR
    guid = uuid.uuid4().bytes_le
    first_usable, last_usable = 34, total_sectors - 1 - ent_sectors - 1

    def header(cur, bak, ent_lba):
        raw = struct.pack(HDR, b"EFI PART", 0x10000, 92, 0, 0, cur, bak, first_usable,
                          last_usable, guid, ent_lba, n_ent, ent_size, ent_crc)
        crc = zlib.crc32(raw) & 0xFFFFFFFF
        return (raw[:16] + struct.pack("<I", crc) + raw[20:]).ljust(SECTOR, b"\0")

    with open(path, "wb") as f:
        f.truncate(total_sectors * SECTOR)
        mbr = bytearray(SECTOR)
        mbr[446 + 4] = 0xEE
        struct.pack_into("<II", mbr, 446 + 8, 1, total_sectors - 1)
        mbr[510:512] = b"\x55\xaa"
        f.write(mbr)
        f.write(header(1, total_sectors - 1, 2))
        f.write(bytes(entries))
        # a marker in the data area so we can prove it is not disturbed
        f.seek(40 * SECTOR)
        f.write(b"DATA-MARKER")
        if with_backup:
            back = total_sectors - 1 - ent_sectors
            f.seek(back * SECTOR)
            f.write(bytes(entries))
            f.seek((total_sectors - 1) * SECTOR)
            f.write(header(total_sectors - 1, 1, back))


def run(*args):
    return subprocess.run([sys.executable, "-I", str(TOOL), *args], capture_output=True, text=True)


@pytest.fixture
def disk(tmp_path):
    p = tmp_path / "disk.img"
    # two partitions, numbers 1 and 6 like the real flasher; ends 8 MiB in
    build_disk(p, [(1, 2048, 4095, "uboot"), (6, 8192, 16383, "rootfs")], 16384 + 34)
    return p


def test_check_accepts_a_valid_disk(disk):
    r = run("check", str(disk))
    assert r.returncode == 0, r.stderr
    assert "rootfs" in r.stdout and "uboot" in r.stdout


def test_add_appends_an_aligned_partition_and_grows_the_file(disk):
    before = disk.stat().st_size
    r = run("add", str(disk), "--name", "BOBCFG", "--size-mib", "4", "--number", "7")
    assert r.returncode == 0, r.stderr
    start, size = map(int, r.stdout.split())
    assert start % MIB == 0 and size == 4 * MIB
    assert disk.stat().st_size > before and disk.stat().st_size % SECTOR == 0
    out = run("check", str(disk)).stdout
    assert "7\t%d\t%d\tBOBCFG" % (start, size) in out


def test_add_leaves_existing_partitions_and_data_alone(disk):
    raw_before = disk.read_bytes()
    assert run("add", str(disk), "--name", "BOBCFG", "--size-mib", "4").returncode == 0
    raw_after = disk.read_bytes()
    # everything between the end of the partition table (sector 34) and the old end of the data
    lo, hi = 34 * SECTOR, 16384 * SECTOR
    assert raw_before[lo:hi] == raw_after[lo:hi]
    assert raw_after[40 * SECTOR:40 * SECTOR + 11] == b"DATA-MARKER"


def test_add_updates_the_protective_mbr(disk):
    run("add", str(disk), "--name", "BOBCFG", "--size-mib", "4")
    raw = disk.read_bytes()
    start, count = struct.unpack("<II", raw[446 + 8:446 + 16])
    assert start == 1 and count == len(raw) // SECTOR - 1


def test_add_clears_the_stale_backup_header(tmp_path):
    p = tmp_path / "d.img"
    # the old backup GPT occupies the last 33 sectors after the last partition
    total = 16384 + 34
    build_disk(p, [(1, 2048, 4095, "uboot"), (6, 8192, 16383, "rootfs")], total)
    assert run("add", str(p), "--name", "BOBCFG", "--size-mib", "4").returncode == 0
    raw = p.read_bytes()
    stale = raw[(16384) * SECTOR:(16384 + 33) * SECTOR]
    assert b"EFI PART" not in stale


def test_add_refuses_a_used_number_or_name(disk):
    assert run("add", str(disk), "--name", "X", "--size-mib", "1", "--number", "6").returncode != 0
    assert run("add", str(disk), "--name", "rootfs", "--size-mib", "1", "--number", "7").returncode != 0


def test_check_detects_corruption(disk):
    assert run("add", str(disk), "--name", "BOBCFG", "--size-mib", "4").returncode == 0
    raw = bytearray(disk.read_bytes())
    raw[2 * SECTOR + 60] ^= 0xFF           # inside the primary partition array
    disk.write_bytes(bytes(raw))
    r = run("check", str(disk))
    assert r.returncode != 0 and "CRC" in r.stderr


def test_check_detects_a_missing_backup(tmp_path):
    p = tmp_path / "nobackup.img"
    build_disk(p, [(1, 2048, 4095, "uboot")], 8192 + 34, with_backup=False)
    assert run("check", str(p)).returncode != 0
