// Rockchip boot ROM ("Maskrom") download over WebUSB: sends the two loader stages a factory unit needs before it
// answers the flashing protocol. Mirrors rkdeveloptool's `db`: stage 0x471 (DRAM init), then stage 0x472 (USB
// plug), each as vendor control transfers (request 0x0C) in 4096-byte pieces with a CRC-CCITT at the end.
//
// The loader files are Rockchip's (github.com/rockchip-linux/rkbin). They are not stored in this repository: the page
// fetches them from a pinned commit and checks their SHA-256 before sending anything to the board.
export const MASKROM_FILTER = { vendorId: 0x2207, productId: 0x350a };
export const LOADER = {
  commit: "3e288fe814e059dd06833495f845cab04ac20a5c",
  // Tried in order; every download is checked against the SHA-256 below, so a mirror needs no trust.
  sources: [
    "https://raw.githubusercontent.com/rockchip-linux/rkbin/3e288fe814e059dd06833495f845cab04ac20a5c/bin/rk35/",   // upstream
    "https://raw.githubusercontent.com/nmadd57/rkbin/3e288fe814e059dd06833495f845cab04ac20a5c/bin/rk35/",          // fork (same commit)
    "https://raw.githubusercontent.com/nmadd57/rockchip-loader-mirror/main/loaders/",                              // mirror of just these files
  ],
  ddr: { name: "rk3566_ddr_1056MHz_v1.26.bin", sha256: "9966c21aadf00737ccecc2fad6fe3c902ff26956433029f70dfd759d4f60616a" },
  plug: { name: "rk356x_usbplug_v1.17.bin", sha256: "4038b7857b840f539760decc0daf1601b8ff61cc17798101e93b11128a7f333e" },
};
const PIECE = 4096;

// A device with USB version 1.00 and no product string is the boot ROM itself (U-Boot's download mode reports 2.23
// and "USB download gadget"; a loaded USB plug reports a product name).
export function isMaskrom(dev) { return dev.deviceVersionMajor === 1 && dev.deviceVersionMinor === 0 && !dev.productName; }

export function crcCcitt(bytes) {
  let crc = 0xffff;
  for (const b of bytes) {
    for (let i = 0x80; i; i >>= 1) {
      const top = crc & 0x8000;
      crc = (crc << 1) & 0xffff;
      if (top) crc ^= 0x1021;
      if (b & i) crc ^= 0x1021;
    }
  }
  return crc;
}

// The exact byte stream rkdeveloptool sends for one stage: the data, a zero pad byte when the length is one short
// of a piece boundary (so the CRC does not straddle it alone), the big-endian CRC, and a trailing one-byte packet
// when the length is two short.
export function stagePayload(data) {
  let len = data.length, extra = false;
  const rem = len % PIECE;
  if (rem === PIECE - 1) len += 1; else if (rem === PIECE - 2) extra = true;
  const buf = new Uint8Array(len + 2); buf.set(data);
  const crc = crcCcitt(buf.subarray(0, len));
  buf[len] = crc >> 8; buf[len + 1] = crc & 0xff;
  return { buf, extra };
}

async function sendStage(dev, index, data) {
  const { buf, extra } = stagePayload(data);
  for (let o = 0; o < buf.length; o += PIECE) {
    const piece = buf.subarray(o, Math.min(o + PIECE, buf.length));
    const r = await dev.controlTransferOut({ requestType: "vendor", recipient: "device", request: 0x0c, value: 0, index }, piece);
    if (r.status !== "ok" || r.bytesWritten !== piece.length) throw new Error(`the boot ROM refused stage 0x${index.toString(16)}`);
  }
  if (extra) await dev.controlTransferOut({ requestType: "vendor", recipient: "device", request: 0x0c, value: 0, index }, new Uint8Array(1));
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const hex = (u8) => [...u8].map((b) => b.toString(16).padStart(2, "0")).join("");

export async function fetchLoader(fetchFn = fetch, digest = (b) => crypto.subtle.digest("SHA-256", b), log = () => {}, spec = LOADER) {
  const out = {};
  for (const [key, f] of [["ddr", spec.ddr], ["plug", spec.plug]]) {
    const problems = [];
    for (const base of spec.sources) {
      try {
        const r = await fetchFn(base + f.name);
        if (!r.ok) { problems.push(`${new URL(base).pathname.split("/")[1]}: HTTP ${r.status}`); continue; }
        const bytes = new Uint8Array(await r.arrayBuffer());
        if (hex(new Uint8Array(await digest(bytes))) !== f.sha256) { problems.push(`${new URL(base).pathname.split("/")[1]}: checksum mismatch`); continue; }
        out[key] = bytes; if (base !== spec.sources[0]) log(`${f.name}: taken from ${base}`);
        break;
      } catch (e) { problems.push(`${new URL(base).pathname.split("/")[1]}: ${e.message}`); }
    }
    if (!out[key]) throw new Error(`could not get ${f.name} with a matching checksum (${problems.join("; ")}); nothing was sent to the board`);
  }
  return out;
}

// Sends both stages. Afterwards the board drops off USB and comes back as a rockusb device (product "USB-MSC").
export async function bootRom(dev, loader, { log = () => {}, pause = sleep } = {}) {
  if (!dev.opened) await dev.open();
  log("sending the DRAM init stage"); await sendStage(dev, 0x471, loader.ddr);
  await pause(1);
  log("sending the USB stage"); await sendStage(dev, 0x472, loader.plug);
  await pause(1000);
  try { await dev.close(); } catch { /* the device is already re-enumerating */ }
}
