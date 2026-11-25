// Tests for the web flasher's pure modules (sparse encoder, GPT patcher). Cross-checked with independent Python code.
import { sparsePiece, sparsePieces, BLK } from "../site/flash/sparse.mjs";
import { parseGpt, extendPartition, crc32 } from "../site/flash/gpt.mjs";
import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import fs from "node:fs"; import os from "node:os"; import path from "node:path";

let failed = 0; const ok = (c, m) => { if (!c) { failed++; console.log("FAIL: " + m); } else console.log("ok:   " + m); };
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "flash-"));

// --- an independent sparse-format reader (written from the Android spec, sharing nothing with sparse.mjs)
const PY_SPARSE = `
import struct, sys
def apply(piece, out):
    magic, maj, mnr, fh, ch, blk, total, chunks, crc = struct.unpack("<IHHHHIIII", piece[:28])
    assert magic == 0xed26ff3a and maj == 1 and fh == 28 and ch == 12 and blk == 4096, "bad header"
    o = 28; pos = 0
    for _ in range(chunks):
        t, _r, sz, tot = struct.unpack("<HHII", piece[o:o+12]); o += 12
        if t == 0xcac1:
            assert tot == 12 + sz * blk, "raw size mismatch"; out[pos*blk:(pos+sz)*blk] = piece[o:o+sz*blk]; o += sz*blk
        elif t == 0xcac3:
            assert tot == 12, "dont-care size"
        else: raise SystemExit("unknown chunk %x" % t)
        pos += sz
    assert pos == total, "chunks cover %d blocks, header says %d" % (pos, total)
    assert o == len(piece), "trailing bytes"
    return total
total_bytes = int(sys.argv[1]); out = bytearray(total_bytes)
for f in sys.argv[2:]:
    apply(open(f, "rb").read(), out)
sys.stdout.buffer.write(out)
`;
fs.writeFileSync(path.join(tmp, "apply.py"), PY_SPARSE);

async function* chunked(buf, size) { for (let o = 0; o < buf.length; o += size) yield buf.subarray(o, Math.min(o + size, buf.length)); }

// 1. several pieces, odd stream chunking, data not a multiple of the block size, partition bigger than the data
{
  const dataLen = 5 * 1024 * 1024 + 1234, part = 12 * 1024 * 1024;
  const data = randomBytes(dataLen), files = []; let n = 0;
  for await (const p of sparsePieces(chunked(data, 777777), dataLen, part, 1024 * 1024)) { const f = path.join(tmp, `p${n++}.simg`); fs.writeFileSync(f, p.bytes); files.push(f); ok(p.bytes.length <= 1024 * 1024, `piece ${n} is within the size limit (${p.bytes.length})`); }
  ok(n >= 5, `data was split into several pieces (${n})`);
  const r = spawnSync("python3", [path.join(tmp, "apply.py"), String(part), ...files], { maxBuffer: 64 * 1024 * 1024 });
  ok(r.status === 0, "independent reader accepts every piece" + (r.status ? ": " + r.stderr : ""));
  const out = r.stdout;
  ok(Buffer.compare(out.subarray(0, dataLen), data) === 0, "applying the pieces reproduces the data byte for byte");
  ok(out.subarray(dataLen).every((b) => b === 0), "the rest of the partition (and the padding) is zeros");
}
// 2. a piece that starts mid-partition still covers the whole partition
{
  const piece = sparsePiece(100, 40, randomBytes(BLK * 10));
  const dv = new DataView(piece.buffer, piece.byteOffset);
  ok(dv.getUint32(16, true) === 100 && dv.getUint32(20, true) === 3, "a mid-partition piece declares 100 blocks and three chunks");
}
// 3. errors
{
  let threw = false; try { sparsePiece(10, 9, new Uint8Array(BLK * 2)); } catch { threw = true; } ok(threw, "data past the end of the partition is refused");
  threw = false; try { for await (const _ of sparsePieces(chunked(new Uint8Array(3 * BLK), BLK), 3 * BLK, 2 * BLK)) {} } catch { threw = true; } ok(threw, "an image larger than its partition is refused");
}
// 4. GPT: build a synthetic 2-partition table, check the parser, then extend the last partition
{
  const DISK = 122142720, g = new Uint8Array(17408), dv = new DataView(g.buffer);
  g.set([0x55, 0xaa], 510);
  g.set(new TextEncoder().encode("EFI PART"), 512); dv.setUint32(520, 0x10000, true); dv.setUint32(524, 92, true);
  dv.setBigUint64(536, 1n, true); dv.setBigUint64(544, 5554175n, true); dv.setBigUint64(552, 34n, true); dv.setBigUint64(560, 5554142n, true);
  dv.setBigUint64(584, 2n, true); dv.setUint32(592, 128, true); dv.setUint32(596, 128, true);
  const ent = (i, first, last, name) => { const o = 1024 + i * 128; g.fill(0xab, o, o + 16); g.fill(0xcd, o + 16, o + 32); dv.setBigUint64(o + 32, BigInt(first), true); dv.setBigUint64(o + 40, BigInt(last), true); [...name].forEach((c, k) => dv.setUint16(o + 56 + k * 2, c.charCodeAt(0), true)); };
  ent(0, 32768, 557055, "bootfs"); ent(1, 557056, 5554142, "rootfs");
  dv.setUint32(600, crc32(g.subarray(1024, 1024 + 128 * 128)), true); dv.setUint32(528, 0, true); dv.setUint32(528, crc32(g.subarray(512, 512 + 92)), true);
  const a = parseGpt(g); ok(a.headerOk && a.arrayOk, "synthetic table: both CRCs valid"); ok(a.entries.length === 2 && a.entries[1].name === "rootfs" && a.entries[1].last === 5554142, "entries parsed (bootfs, rootfs)");
  const e = extendPartition(g, "rootfs", DISK), b = parseGpt(e);
  ok(b.headerOk && b.arrayOk, "extended table: both CRCs still valid");
  ok(b.entries[1].last === DISK - 34 && b.entries[0].last === 557055, "rootfs now ends at the last usable sector; bootfs is untouched");
  const dv2 = new DataView(e.buffer); ok(Number(dv2.getBigUint64(544, true)) === DISK - 1 && Number(dv2.getBigUint64(560, true)) === DISK - 34, "header's backup-LBA and last-usable fields updated");
  // cross-check the CRCs with Python's zlib on the exact bytes
  fs.writeFileSync(path.join(tmp, "gpt.bin"), e);
  const py = spawnSync("python3", ["-c", `import zlib,struct,sys
d=open(sys.argv[1],"rb").read(); h=bytearray(d[512:512+92]); c=struct.unpack("<I",h[16:20])[0]; h[16:20]=bytes(4)
print(int(zlib.crc32(bytes(h))==c), int(zlib.crc32(d[1024:1024+16384])==struct.unpack("<I",d[512+88:512+92])[0]))`, path.join(tmp, "gpt.bin")], { encoding: "utf8" });
  ok(py.stdout.trim() === "1 1", "Python's zlib agrees with both CRCs");
  let threw = false; try { extendPartition(g, "bootfs", DISK); } catch { threw = true; } ok(threw, "extending a partition that is not the last one is refused");
  threw = false; try { extendPartition(g, "nope", DISK); } catch { threw = true; } ok(threw, "an unknown partition name is refused");
}
fs.rmSync(tmp, { recursive: true });
process.exit(failed ? 1 : 0);
