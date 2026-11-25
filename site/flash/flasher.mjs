// The two phases of a USB flash, and the byte-stream plumbing between them. UI-free: callers pass the connected
// devices, a function that opens the image as a stream of bytes, and callbacks for progress and log lines.
import { extendPartition, parseGpt } from "./gpt.mjs";
import { addFile } from "./fat.mjs";
import { sparsePieces } from "./sparse.mjs";
import { SECTOR } from "./rockusb.mjs";

export function same(a, b) { if (a.length !== b.length) return false; for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false; return true; }
export const GPT_BYTES = 34 * SECTOR;
export const FLASH_FAT_SECTOR = 32768;          // where the image's bootfs starts; the temporary boot partition goes here

// Sequential reader over an async iterable of byte chunks.
export class ByteReader {
  constructor(iterable) { this.it = iterable[Symbol.asyncIterator](); this.buf = new Uint8Array(0); this.pos = 0; this.done = false; }
  async fill() { const r = await this.it.next(); if (r.done) { this.done = true; return false; } this.buf = r.value; return true; }
  async read(n) {
    const out = new Uint8Array(n); let got = 0;
    while (got < n) {
      if (this.pos >= this.buf.length) { this.pos = 0; if (!(await this.fill())) throw new Error("the image ended early"); }
      const take = Math.min(n - got, this.buf.length - this.pos); out.set(this.buf.subarray(this.pos, this.pos + take), got); got += take; this.pos += take;
    }
    return out;
  }
  async close() { try { await this.it.return?.(); } catch {} }
  async skip(n) { while (n > 0) { if (this.pos >= this.buf.length) { this.pos = 0; if (!(await this.fill())) throw new Error("the image ended early"); } const t = Math.min(n, this.buf.length - this.pos); this.pos += t; n -= t; } }
  async *take(n) {
    while (n > 0) {
      if (this.pos >= this.buf.length) { this.pos = 0; if (!(await this.fill())) throw new Error("the image ended early"); }
      const t = Math.min(n, this.buf.length - this.pos); yield this.buf.subarray(this.pos, this.pos + t); this.pos += t; n -= t;
    }
  }
}

export async function readLayout(openStream) {
  const r = new ByteReader(openStream()); let gpt; try { gpt = await r.read(GPT_BYTES); } finally { await r.close(); }
  const g = parseGpt(gpt); if (!g.headerOk || !g.arrayOk) throw new Error("the image's partition table is damaged");
  const boot = g.entries.find((e) => e.name === "bootfs"), root = g.entries.find((e) => e.name === "rootfs");
  if (!boot || !root) throw new Error("the image has no bootfs and rootfs partitions");
  if (boot.last + 1 !== root.first) throw new Error("bootfs and rootfs are not contiguous in the image");
  return { gpt, boot, root };
}

// Phase 1, in download mode: write the partition table and the temporary fastboot boot partition, then reset.
export async function phaseDownloadMode({ rock, openStream, flashFat, log = () => {}, progress = () => {} }) {
  const layout = await readLayout(openStream);
  const info = await rock.flashInfo(); log(`eMMC: ${info.sectors} sectors (${(info.sectors * SECTOR / 2 ** 30).toFixed(1)} GiB)`);
  const table = extendPartition(layout.gpt, "rootfs", info.sectors);
  if (flashFat.length !== 8 * 1024 * 1024) throw new Error("the temporary boot partition must be 8 MiB");
  if (FLASH_FAT_SECTOR + flashFat.length / SECTOR > 65536) throw new Error("the temporary boot partition does not fit in the first 32 MiB");
  log("writing the partition table"); await rock.writeLba(0, table);
  log("writing the temporary boot partition"); await rock.writeLba(FLASH_FAT_SECTOR, flashFat, (d, t) => progress({ label: "boot area", done: d, total: t }));
  log("verifying what was written");
  const back = await rock.readLba(0, 34); if (!same(back, table)) throw new Error("the partition table did not read back correctly");
  const fat = await rock.readLba(FLASH_FAT_SECTOR, flashFat.length / SECTOR); if (!same(fat, flashFat)) throw new Error("the boot area did not read back correctly");
  log("verified; resetting the board into fastboot"); await rock.reset();
  return { diskSectors: info.sectors };
}

// Phase 2, in fastboot: rootfs first, then bootfs (with the settings file added) so the temporary boot partition is
// replaced last, then reboot.
export async function phaseFastboot({ fb, openStream, settingsText, log = () => {}, progress = () => {} }) {
  const { boot, root } = await readLayout(openStream);
  const max = await fb.maxDownload(), bootSize = await fb.partitionSize("bootfs"), rootSize = await fb.partitionSize("rootfs");
  log(`fastboot: ${max / 2 ** 20} MiB download buffer; bootfs ${bootSize / 2 ** 20} MiB, rootfs ${(rootSize / 2 ** 30).toFixed(2)} GiB`);
  const bootBytes = (boot.last - boot.first + 1) * SECTOR, rootBytes = (root.last - root.first + 1) * SECTOR;
  if (bootBytes > bootSize || rootBytes > rootSize) throw new Error("a partition on the board is smaller than the image's");
  const r = new ByteReader(openStream());
  try {
  await r.skip(boot.first * SECTOR);
  const bootfs = new Uint8Array(bootBytes); let o = 0; for await (const c of r.take(bootBytes)) { bootfs.set(c, o); o += c.length; }
  if (settingsText && settingsText.trim()) { const res = addFile(bootfs, "bobcat-install.conf", new TextEncoder().encode(settingsText)); log(`settings file added to the boot partition (${res.shortName.trim()})`); }
  else log("no settings: the first boot will install with defaults and needs a wired network");
  let done = 0;
  for await (const p of sparsePieces(r.take(rootBytes), rootBytes, rootSize, max - 4 * 4096)) {
    await fb.flash("rootfs", p.bytes); done += p.dataBytes; progress({ label: "rootfs", done, total: rootBytes });
  }
  log("rootfs written; writing bootfs last");
  done = 0;
  for await (const p of sparsePieces((async function* () { yield bootfs; })(), bootBytes, bootSize, max - 4 * 4096)) {
    await fb.flash("bootfs", p.bytes); done += p.dataBytes; progress({ label: "bootfs", done, total: bootBytes });
  }
  log("rebooting into the new system"); await fb.reboot();
  } finally { await r.close(); }
}
