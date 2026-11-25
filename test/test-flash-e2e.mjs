// End to end: a synthetic image through both phases against an emulated board that has the real board's quirks
// (download mode reads/writes only the first 32 MiB; fastboot writes anywhere, in sparse pieces).
import { RockUsb } from "../site/flash/rockusb.mjs";
import { Fastboot } from "../site/flash/fastboot.mjs";
import { phaseDownloadMode, phaseFastboot } from "../site/flash/flasher.mjs";
import { parseGpt, crc32 } from "../site/flash/gpt.mjs";
import { execFileSync, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import fs from "node:fs"; import os from "node:os"; import path from "node:path";

const have = (t) => spawnSync("sh", ["-c", `command -v ${t}`]).status === 0;
if (!["mkfs.fat", "mcopy", "mtype", "fsck.fat"].every(have)) { console.log("skip: needs dosfstools and mtools"); process.exit(0); }
let failed = 0; const ok = (c, m) => { if (!c) { failed++; console.log("FAIL: " + m); } else console.log("ok:   " + m); };
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "e2e-")); const f = (n) => path.join(tmp, n);
const run = (c, a, o = {}) => execFileSync(c, a, { encoding: o.bin ? "buffer" : "utf8", stdio: ["ignore", "pipe", "pipe"] });

// ---- the synthetic image: GPT | gap | bootfs (32 MiB FAT16) | rootfs (10 MiB + odd tail) | backup GPT
const BOOT_SECT = 65536, ROOT_BYTES = 10 * 1024 * 1024 + 1000, ROOT_SECT = Math.ceil(ROOT_BYTES / 512);
fs.writeFileSync(f("boot.img"), Buffer.alloc(BOOT_SECT * 512)); run("mkfs.fat", ["-F", "16", "-n", "BOOTFS", f("boot.img")]);
fs.writeFileSync(f("boot.scr"), "a boot script\n"); run("mcopy", ["-i", f("boot.img"), f("boot.scr"), "::boot.scr"]);
const bootfs = fs.readFileSync(f("boot.img")), rootfs = randomBytes(ROOT_SECT * 512);
const BOOT_FIRST = 32768, ROOT_FIRST = BOOT_FIRST + BOOT_SECT, ROOT_LAST = ROOT_FIRST + ROOT_SECT - 1;
const g = new Uint8Array(17408), dv = new DataView(g.buffer); g.set([0x55, 0xaa], 510); g.set(new TextEncoder().encode("EFI PART"), 512);
dv.setUint32(520, 0x10000, true); dv.setUint32(524, 92, true); dv.setBigUint64(536, 1n, true); dv.setBigUint64(544, BigInt(ROOT_LAST + 33), true);
dv.setBigUint64(552, 34n, true); dv.setBigUint64(560, BigInt(ROOT_LAST), true); dv.setBigUint64(584, 2n, true); dv.setUint32(592, 128, true); dv.setUint32(596, 128, true);
const ent = (i, a, b, n) => { const o = 1024 + i * 128; g.fill(0x11, o, o + 16); g.fill(0x22, o + 16, o + 32); dv.setBigUint64(o + 32, BigInt(a), true); dv.setBigUint64(o + 40, BigInt(b), true); [...n].forEach((c, k) => dv.setUint16(o + 56 + k * 2, c.charCodeAt(0), true)); };
ent(0, BOOT_FIRST, ROOT_FIRST - 1, "bootfs"); ent(1, ROOT_FIRST, ROOT_LAST, "rootfs");
dv.setUint32(600, crc32(g.subarray(1024, 1024 + 16384)), true); dv.setUint32(528, crc32(g.subarray(512, 512 + 92)), true);
const loader = randomBytes((BOOT_FIRST - 64) * 512);   // stands in for idbloader + U-Boot
const gap = Buffer.alloc(64 * 512 - g.length);
const image = Buffer.concat([Buffer.from(g), gap, loader, bootfs, rootfs, Buffer.alloc(33 * 512)]);
async function* openImage() { for (let o = 0; o < image.length; o += 3000011) yield new Uint8Array(image.subarray(o, Math.min(o + 3000011, image.length))); }

// the temporary 8 MiB boot partition the page would fetch
fs.writeFileSync(f("flash.img"), Buffer.alloc(8 * 1024 * 1024)); run("mkfs.fat", ["-F", "12", "-s", "4", "-n", "BOBFLASH", f("flash.img")]);
fs.writeFileSync(f("fb.scr"), "fastboot usb 0\n"); run("mcopy", ["-i", f("flash.img"), f("fb.scr"), "::boot.scr"]);
const flashFat = new Uint8Array(fs.readFileSync(f("flash.img")));

// ---- one emulated eMMC behind two USB personalities
const DISK = 200000, disk = new Uint8Array(DISK * 512), events = [];
class Usb { constructor(h) { this.h = h; this.inq = []; this.configuration = { interfaces: [h.iface] }; }
  async open() {} async selectConfiguration() {} async claimInterface() {} async releaseInterface() {} async close() {}
  async transferOut(ep, d) { await this.h.out(new Uint8Array(d), this); return { status: "ok" }; }
  async transferIn(ep, len) { const h = this.inq[0], t = h.subarray(0, len); this.inq[0] = h.subarray(t.length); if (!this.inq[0].length) this.inq.shift(); return { status: "ok", data: new DataView(t.buffer.slice(t.byteOffset, t.byteOffset + t.length)) }; } }
const csw = (tag) => { const c = new Uint8Array(13), v = new DataView(c.buffer); v.setUint32(0, 0x53425355, true); v.setUint32(4, tag, true); return c; };
const rockHandler = { iface: { interfaceNumber: 0, alternate: { interfaceClass: 0xff, interfaceSubclass: 6, interfaceProtocol: 5, endpoints: [{ direction: "out", endpointNumber: 2 }, { direction: "in", endpointNumber: 1 }] } }, pending: null,
  async out(d, u) {
    if (this.pending) { const p = this.pending; this.pending = null; if (p.lba + p.n <= 65536) disk.set(d, p.lba * 512); else events.push("DROPPED write past 32 MiB"); u.inq.push(csw(p.tag)); return; }
    const v = new DataView(d.buffer, d.byteOffset), tag = v.getUint32(4, true), op = d[15], lba = v.getUint32(17, false), n = v.getUint16(22, false);
    if (op === 0x1a) { const i = new Uint8Array(11); new DataView(i.buffer).setUint32(0, DISK, true); u.inq.push(i, csw(tag)); }
    else if (op === 0x14) { const o = new Uint8Array(n * 512).fill(0xcc); if (lba + n <= 65536) o.set(disk.subarray(lba * 512, (lba + n) * 512)); u.inq.push(o, csw(tag)); }
    else if (op === 0x15) this.pending = { lba, n, tag };
    else if (op === 0xff) events.push("rockusb reset");
  } };
function applySparse(piece, base) {   // reference-style decoder
  const v = new DataView(piece.buffer, piece.byteOffset), chunks = v.getUint32(20, true); let o = 28, pos = 0;
  for (let i = 0; i < chunks; i++) { const t = v.getUint16(o, true), sz = v.getUint32(o + 4, true); o += 12; if (t === 0xcac1) { disk.set(piece.subarray(o, o + sz * 4096), base + pos * 4096); o += sz * 4096; } pos += sz; }
}
const fbHandler = { iface: { interfaceNumber: 0, alternate: { interfaceClass: 0xff, interfaceSubclass: 0x42, interfaceProtocol: 3, endpoints: [{ direction: "out", endpointNumber: 1 }, { direction: "in", endpointNumber: 1 }] } }, dl: null,
  parts() { const t = parseGpt(disk.subarray(0, 17408)); return Object.fromEntries(t.entries.map((e) => [e.name, e])); },
  async out(d, u) {
    const T = (s) => new TextEncoder().encode(s);
    if (this.dl) { this.dl.chunks.push(d.slice()); this.dl.got += d.length; if (this.dl.got === this.dl.size) { this.last = Buffer.concat(this.dl.chunks); this.dl = null; u.inq.push(T("OKAY")); } return; }
    const c = new TextDecoder().decode(d), P = this.parts();
    if (c === "getvar:max-download-size") u.inq.push(T("OKAY0x04000000"));
    else if (c.startsWith("getvar:partition-size:")) { const e = P[c.slice(22)]; u.inq.push(T(e ? "OKAY0x" + ((e.last - e.first + 1) * 512).toString(16) : "FAILunknown")); }
    else if (c.startsWith("download:")) { this.dl = { size: parseInt(c.slice(9), 16), got: 0, chunks: [] }; u.inq.push(T("DATA" + c.slice(9))); }
    else if (c.startsWith("flash:")) { const e = P[c.slice(6)]; if (!e) u.inq.push(T("FAILcannot find partition")); else { applySparse(new Uint8Array(this.last), e.first * 512); events.push("flash " + c.slice(6)); u.inq.push(T("OKAY")); } }
    else if (c === "reboot") { events.push("fastboot reboot"); u.inq.push(T("OKAY")); }
  } };

const logs = [];
const rock = new RockUsb(new Usb(rockHandler)); await rock.open();
await phaseDownloadMode({ rock, openImage: null, openStream: openImage, flashFat, log: (m) => logs.push(m) });
ok(events.includes("rockusb reset") && !events.some((e) => e.startsWith("DROPPED")), "phase 1 reset the board and never wrote past the 32 MiB window");
const t1 = parseGpt(disk.subarray(0, 17408));
ok(t1.headerOk && t1.arrayOk, "phase 1: the table on the board has valid CRCs");
ok(t1.entries[1].name === "rootfs" && t1.entries[1].last === DISK - 34 && t1.entries[0].last === ROOT_FIRST - 1, "phase 1: rootfs extended to the end of the disk, bootfs unchanged");
ok(Buffer.compare(Buffer.from(disk.subarray(BOOT_FIRST * 512, BOOT_FIRST * 512 + flashFat.length)), Buffer.from(flashFat)) === 0, "phase 1: the temporary boot partition is where bootfs starts");
ok(Buffer.compare(Buffer.from(disk.subarray(64 * 512, BOOT_FIRST * 512)), loader) === 0, "phase 1: the image's bootloader region (sector 64 up to bootfs) was written");

const settings = "WIFI_SSID=Home\nHOSTNAME=testnode\nTIMEZONE=America/New_York\n";
const fb = new Fastboot(new Usb(fbHandler)); await fb.open();
const prog = []; await phaseFastboot({ fb, openStream: openImage, settingsText: settings, log: (m) => logs.push(m), progress: (p) => prog.push(p) });
const order = events.filter((e) => e.startsWith("flash") || e.startsWith("fastboot"));
ok(order[0] === "flash rootfs" && order.filter((e) => e === "flash bootfs").length >= 1 && order[order.length - 1] === "fastboot reboot", "phase 2 order: rootfs pieces, then bootfs, then reboot");
const lastRoot = order.lastIndexOf("flash rootfs"), firstBoot = order.indexOf("flash bootfs"); ok(lastRoot < firstBoot, "bootfs is flashed only after all of rootfs");
ok(Buffer.compare(Buffer.from(disk.subarray(ROOT_FIRST * 512, ROOT_FIRST * 512 + ROOT_SECT * 512)), rootfs) === 0, "the rootfs on the board equals the image's rootfs, byte for byte");
const gotBoot = Buffer.from(disk.subarray(BOOT_FIRST * 512, BOOT_FIRST * 512 + BOOT_SECT * 512)); fs.writeFileSync(f("got.img"), gotBoot);
ok(spawnSync("fsck.fat", ["-n", f("got.img")]).status === 0, "the bootfs on the board is a clean FAT filesystem");
ok(run("mtype", ["-i", f("got.img"), "::bobcat-install.conf"]) === settings, "the settings file is in bootfs under its long name, content intact");
ok(run("mtype", ["-i", f("got.img"), "::boot.scr"]) === "a boot script\n", "the image's own boot.scr survived (the temporary partition is gone)");
ok(!/fastboot usb 0/.test(run("mtype", ["-i", f("got.img"), "::boot.scr"])), "the temporary fastboot script is not left behind");
ok(prog.some((p) => p.label === "rootfs" && p.done === ROOT_SECT * 512) && prog.some((p) => p.label === "bootfs" && p.done === BOOT_SECT * 512), "progress reached 100% for both partitions");
fs.rmSync(tmp, { recursive: true });
process.exit(failed ? 1 : 0);
