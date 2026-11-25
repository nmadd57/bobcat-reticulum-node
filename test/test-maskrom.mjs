// Tests for the boot ROM download: CRC against Python's, the byte stream against a transcription of rkdeveloptool's rules.
import { crcCcitt, stagePayload, bootRom, fetchLoader, isMaskrom, LOADER } from "../site/flash/maskrom.mjs";
import { spawnSync } from "node:child_process";
import { randomBytes, createHash } from "node:crypto";
let failed = 0; const ok = (c, m) => { if (!c) { failed++; console.log("FAIL: " + m); } else console.log("ok:   " + m); };

for (const n of [0, 1, 2, 100, 4096, 59240]) {
  const d = randomBytes(n);
  const py = spawnSync("python3", ["-c", `import sys,binascii;print(binascii.crc_hqx(sys.stdin.buffer.read(),0xffff))`], { input: d, encoding: "utf8" }).stdout.trim();
  ok(crcCcitt(d) === +py, `CRC-CCITT matches Python's crc_hqx for ${n} bytes`);
}
for (const [len, wantLen, wantExtra] of [[100, 102, false], [4095, 4098, false], [4094, 4096, true], [4096, 4098, false], [8190, 8192, true], [8191, 8194, false], [59240, 59242, false]]) {
  const d = randomBytes(len), { buf, extra } = stagePayload(d);
  const crc = crcCcitt(buf.subarray(0, buf.length - 2));
  ok(buf.length === wantLen && extra === wantExtra && (buf[buf.length - 2] << 8 | buf[buf.length - 1]) === crc && Buffer.compare(Buffer.from(buf.subarray(0, len)), d) === 0, `payload for ${len} bytes: ${wantLen} bytes sent${wantExtra ? " plus a one-byte packet" : ""}, CRC last`);
}
class Dev { constructor() { this.calls = []; this.opened = false; this.closed = false; }
  async open() { this.opened = true; } async close() { this.closed = true; }
  async controlTransferOut(s, data) { this.calls.push({ s, data: new Uint8Array(data) }); return { status: "ok", bytesWritten: data.length }; } }
{
  const ddr = randomBytes(59240), plug = randomBytes(98708), dev = new Dev(), log = [], pauses = [];
  await bootRom(dev, { ddr, plug }, { log: (m) => log.push(m), pause: async (ms) => pauses.push(ms) });
  const by = (i) => dev.calls.filter((c) => c.s.index === i);
  ok(dev.calls.every((c) => c.s.requestType === "vendor" && c.s.recipient === "device" && c.s.request === 0x0c && c.s.value === 0), "every transfer is a vendor request 0x0C to the device");
  ok(by(0x471).length === 15 && by(0x472).length === 25, "stage 0x471 goes out in 15 pieces and 0x472 in 25");
  ok(by(0x471).every((c) => c.data.length <= 4096) && by(0x472).every((c) => c.data.length <= 4096), "no piece is longer than 4096 bytes");
  ok(Buffer.compare(Buffer.concat(by(0x471).map((c) => Buffer.from(c.data))).subarray(0, ddr.length), ddr) === 0 && Buffer.compare(Buffer.concat(by(0x472).map((c) => Buffer.from(c.data))).subarray(0, plug.length), plug) === 0, "the stages carry the loader bytes unchanged");
  const first = dev.calls.findIndex((c) => c.s.index === 0x472), lastDdr = dev.calls.map((c) => c.s.index).lastIndexOf(0x471);
  ok(lastDdr < first, "the DRAM stage is fully sent before the USB stage");
  ok(pauses[0] === 1 && pauses[1] === 1000 && dev.opened && dev.closed, "waits 1 ms then 1 s, opens and closes the device");
  ok(log.length === 2, "progress is logged for both stages");
}
ok(isMaskrom({ deviceVersionMajor: 1, deviceVersionMinor: 0, productName: undefined }) && !isMaskrom({ deviceVersionMajor: 2, deviceVersionMinor: 2, productName: "USB download gadget" }) && !isMaskrom({ deviceVersionMajor: 1, deviceVersionMinor: 0, productName: "USB-MSC" }), "only the boot ROM (1.00, no product name) counts as Maskrom");
{ // fetchLoader: checksums are checked and the sources are tried in order
  const sha = (b) => createHash("sha256").update(b).digest();
  const good = { ddr: Buffer.from("ddr-bytes"), plug: Buffer.from("plug-bytes") };
  const L = { ...LOADER, ddr: { ...LOADER.ddr, sha256: createHash("sha256").update(good.ddr).digest("hex") }, plug: { ...LOADER.plug, sha256: createHash("sha256").update(good.plug).digest("hex") } };
  const mk = (behaviour) => async (url) => {
    const name = url.split("/").pop(), which = LOADER.sources.findIndex((b) => url.startsWith(b)), act = behaviour[which];
    if (act === "404") return { ok: false, status: 404 };
    if (act === "throw") throw new Error("network down");
    const data = act === "bad" ? Buffer.from("tampered") : name === LOADER.ddr.name ? good.ddr : good.plug;
    return { ok: true, arrayBuffer: async () => new Uint8Array(data).buffer };
  };
  const logs = [];
  let r = await fetchLoader(mk(["ok", "ok", "ok"]), sha, (m) => logs.push(m), L);
  ok(Buffer.compare(Buffer.from(r.ddr), good.ddr) === 0 && logs.length === 0, "upstream is used first, and nothing else is logged");
  r = await fetchLoader(mk(["404", "ok", "ok"]), sha, (m) => logs.push(m), L);
  ok(Buffer.compare(Buffer.from(r.plug), good.plug) === 0 && logs.some((m) => m.includes("nmadd57/rkbin")), "when upstream is gone the fork is used, and the log says so");
  logs.length = 0; r = await fetchLoader(mk(["throw", "404", "ok"]), sha, (m) => logs.push(m), L);
  ok(Buffer.compare(Buffer.from(r.ddr), good.ddr) === 0 && logs.some((m) => m.includes("rockchip-loader-mirror")), "when upstream and fork are gone the mirror is used");
  r = await fetchLoader(mk(["bad", "bad", "ok"]), sha, () => {}, L);
  ok(Buffer.compare(Buffer.from(r.ddr), good.ddr) === 0, "a source serving different bytes is skipped, not trusted");
  let msg = ""; try { await fetchLoader(mk(["bad", "bad", "bad"]), sha, () => {}, L); } catch (e) { msg = e.message; }
  ok(/checksum mismatch/.test(msg) && /nothing was sent/.test(msg), "if every source fails the checksum nothing is sent");
  msg = ""; try { await fetchLoader(mk(["404", "404", "throw"]), sha, () => {}, L); } catch (e) { msg = e.message; }
  ok(/HTTP 404/.test(msg) && /network down/.test(msg), "the error names what went wrong at each source");
}
process.exit(failed ? 1 : 0);
