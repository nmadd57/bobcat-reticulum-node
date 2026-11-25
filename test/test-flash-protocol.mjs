// Tests for the rockusb and fastboot clients against emulated boards, and for the exact rockusb command bytes
// against Python's struct (the layout proven on the hardware).
import { RockUsb, cbw } from "../site/flash/rockusb.mjs";
import { Fastboot } from "../site/flash/fastboot.mjs";
import { sparsePiece } from "../site/flash/sparse.mjs";
import { spawnSync } from "node:child_process";

let failed = 0; const ok = (c, m) => { if (!c) { failed++; console.log("FAIL: " + m); } else console.log("ok:   " + m); };
const hex = (u8) => Buffer.from(u8).toString("hex");

// --- 1. command bytes vs Python struct
const py = (code) => spawnSync("python3", ["-c", `import struct;print(struct.pack("<4sIIBBB16s",b"USBC",${code}).hex())`], { encoding: "utf8" }).stdout.trim();
const cdb = (op, sub, lba, n) => `bytes([${op},${sub}])+struct.pack(">I",${lba})+b"\\0"+struct.pack(">H",${n})`;
ok(hex(cbw(7, 0x14, { dataLen: 4096, lba: 65536, sectors: 8 })) === py(`7,4096,0x80,0,10,${cdb(0x14, 0, 65536, 8)}`), "READ_LBA command block matches Python's struct");
ok(hex(cbw(9, 0x15, { dataLen: 65536, dirIn: false, lba: 32768, sectors: 128 })) === py(`9,65536,0,0,10,${cdb(0x15, 0, 32768, 128)}`), "WRITE_LBA command block matches Python's struct");
ok(hex(cbw(3, 0x1a, { dataLen: 11, cdbLen: 6 })) === py(`3,11,0x80,0,6,bytes([0x1a,0])+bytes(7)`), "READ_FLASH_INFO command block (6-byte CDB) matches Python's struct");
ok(cbw(1, 0x14, {}).length === 31, "a command block is 31 bytes");

// --- an emulated USB device
class FakeUsb {
  constructor(handler) { this.handler = handler; this.inq = []; this.opened = false; this.configuration = { interfaces: [handler.iface] }; this.sent = []; }
  async open() { this.opened = true; } async selectConfiguration() {} async claimInterface() {} async releaseInterface() {} async close() {}
  async transferOut(ep, data) { const d = new Uint8Array(data); this.sent.push(d); await this.handler.out(d, this); return { status: "ok", bytesWritten: d.length }; }
  async transferIn(ep, len) {
    if (!this.inq.length) throw new Error("device had nothing to send");
    const head = this.inq[0], take = head.subarray(0, len); this.inq[0] = head.subarray(take.length); if (!this.inq[0].length) this.inq.shift();
    return { status: "ok", data: new DataView(take.buffer.slice(take.byteOffset, take.byteOffset + take.length)) };
  }
}
const rockIface = { interfaceNumber: 0, alternate: { interfaceClass: 0xff, interfaceSubclass: 6, interfaceProtocol: 5, endpoints: [{ direction: "out", endpointNumber: 2 }, { direction: "in", endpointNumber: 1 }] } };
const fbIface = { interfaceNumber: 0, alternate: { interfaceClass: 0xff, interfaceSubclass: 0x42, interfaceProtocol: 3, endpoints: [{ direction: "out", endpointNumber: 1 }, { direction: "in", endpointNumber: 1 }] } };

// --- 2. a board that behaves like the real one in download mode: real data below 32 MiB, 0xCC filler above it
function rockBoard(diskSectors) {
  const mem = new Uint8Array(32 * 1024 * 1024); const state = { pending: null, resets: 0 };
  return { iface: rockIface, mem, state,
    async out(d, dev) {
      if (state.pending) { const { lba, n, tag } = state.pending; state.pending = null; mem.set(d, lba * 512); dev.inq.push(csw(tag, 0)); return; }
      const dv = new DataView(d.buffer, d.byteOffset); if (dv.getUint32(0, true) !== 0x43425355) throw new Error("bad signature");
      const tag = dv.getUint32(4, true), len = dv.getUint32(8, true), op = d[15], lba = dv.getUint32(17, false), n = dv.getUint16(22, false);
      if (op === 0x1a) { const info = new Uint8Array(11); new DataView(info.buffer).setUint32(0, diskSectors, true); dev.inq.push(info, csw(tag, 0)); }
      else if (op === 0x14) { const out = new Uint8Array(n * 512).fill(0xcc); if (lba + n <= 65536) out.set(mem.subarray(lba * 512, (lba + n) * 512)); dev.inq.push(out, csw(tag, 0)); }
      else if (op === 0x15) { state.pending = { lba, n, tag }; }
      else if (op === 0xff) { state.resets++; }
      else throw new Error("unknown op " + op);
    } };
}
function csw(tag, status) { const c = new Uint8Array(13), dv = new DataView(c.buffer); dv.setUint32(0, 0x53425355, true); dv.setUint32(4, tag, true); c[12] = status; return c; }
{
  const board = rockBoard(122142720), dev = new FakeUsb(board), r = new RockUsb(dev); await r.open();
  ok((await r.flashInfo()).sectors === 122142720, "flashInfo reads the disk size in sectors");
  const data = new Uint8Array(300 * 512).map((_, i) => (i * 7 + 3) & 255), seen = [];
  await r.writeLba(32768, data, (d, t) => seen.push(d));
  ok(seen.length === 3 && seen[2] === 300, "a 300-sector write goes out in three chunks (128+128+44) with progress");
  ok(Buffer.compare(Buffer.from(await r.readLba(32768, 300)), Buffer.from(data)) === 0, "data written is read back byte for byte");
  ok((await r.readLba(65536, 8)).every((b) => b === 0xcc), "reading past 32 MiB returns the 0xCC filler, as on the real board");
  let threw = false; try { await r.writeLba(0, new Uint8Array(100)); } catch { threw = true; } ok(threw, "a write that is not whole sectors is refused");
  await r.reset(); ok(board.state.resets === 1, "reset sends the reset command and tolerates the device not answering");
}

// --- 3. a fastboot board
function fbBoard() {
  const flashes = [], st = { downloading: null, got: 0, parts: [], buf: [] }, partitions = { bootfs: 268435456, rootfs: 2563645440 };
  const text = (s) => new TextEncoder().encode(s);
  return { iface: fbIface, flashes, st,
    async out(d, dev) {
      if (st.downloading) { st.buf.push(d.slice()); st.got += d.length; if (st.got === st.downloading) { st.last = Buffer.concat(st.buf); st.downloading = null; dev.inq.push(text("OKAY")); } return; }
      const c = new TextDecoder().decode(d);
      if (c === "getvar:max-download-size") dev.inq.push(text("OKAY0x04000000"));
      else if (c.startsWith("getvar:partition-size:")) { const p = c.slice(22); partitions[p] ? dev.inq.push(text("OKAY0x" + partitions[p].toString(16))) : dev.inq.push(text("FAILunknown variable")); }
      else if (c.startsWith("download:")) { st.downloading = parseInt(c.slice(9), 16); st.got = 0; st.buf = []; dev.inq.push(text("DATA" + c.slice(9))); }
      else if (c.startsWith("flash:")) { const p = c.slice(6); if (!partitions[p]) dev.inq.push(text("FAILcannot find partition")); else { flashes.push({ p, bytes: st.last }); dev.inq.push(text("INFOwriting " + p), text("OKAY")); } }
      else if (c === "reboot") dev.inq.push(text("OKAY"));
      else dev.inq.push(text("FAILunknown command"));
    } };
}
{
  const b = fbBoard(), dev = new FakeUsb(b), f = new Fastboot(dev); await f.open();
  ok(await f.maxDownload() === 0x04000000, "maxDownload reads 64 MiB");
  ok(await f.partitionSize("rootfs") === 2563645440, "partitionSize reads a partition's size");
  const infos = []; f.log = (t) => infos.push(t);
  const piece = sparsePiece(8, 2, new Uint8Array(4096 * 3).fill(9));
  await f.flash("rootfs", piece);
  ok(b.flashes.length === 1 && b.flashes[0].p === "rootfs" && Buffer.compare(b.flashes[0].bytes, Buffer.from(piece)) === 0, "a sparse piece is downloaded and flashed intact");
  ok(infos.includes("writing rootfs"), "INFO lines from the device are passed to the log");
  let msg = ""; try { await f.flash("nope", piece); } catch (e) { msg = e.message; } ok(/cannot find partition/.test(msg), "a FAIL reply becomes an error with the device's reason");
  // a large download goes out in 1 MiB packets
  const big = new Uint8Array(3 * 1024 * 1024 + 5), before = dev.sent.length; await f.download(big);
  ok(dev.sent.length - before === 1 + 4 && b.st.last.length === big.length, "a 3 MiB download is sent as the size command plus four packets");
  await f.reboot(); ok(new TextDecoder().decode(dev.sent[dev.sent.length - 1]) === "reboot", "reboot sends the reboot command");
}
process.exit(failed ? 1 : 0);
