// GUID partition table helpers: parse the first 34 sectors and re-issue them with the root partition extended
// to the end of the disk, with both CRCs recomputed.
const T = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
export function crc32(u8) { let c = 0xffffffff; for (let i = 0; i < u8.length; i++) c = T[(c ^ u8[i]) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; }

const u64 = (dv, o) => Number(dv.getBigUint64(o, true));

export function parseGpt(buf) {              // buf: 34 sectors (17408 bytes) or more
  if (buf.length < 17408) throw new Error("need the first 34 sectors");
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const sig = String.fromCharCode(...buf.subarray(512, 520));
  if (sig !== "EFI PART") throw new Error("no GPT header at sector 1");
  const hs = dv.getUint32(512 + 12, true), crcStored = dv.getUint32(512 + 16, true);
  const h = buf.slice(512, 512 + hs); new DataView(h.buffer).setUint32(16, 0, true);
  const n = dv.getUint32(512 + 80, true), es = dv.getUint32(512 + 84, true);
  const arr = buf.subarray(1024, 1024 + n * es);
  const entries = [];
  for (let i = 0; i < n; i++) {
    const e = arr.subarray(i * es, (i + 1) * es);
    if (e.slice(0, 16).every((b) => b === 0)) continue;
    const ev = new DataView(e.buffer, e.byteOffset, e.byteLength);
    let name = ""; for (let k = 56; k < 128; k += 2) { const c = ev.getUint16(k, true); if (!c) break; name += String.fromCharCode(c); }
    entries.push({ index: i, first: u64(ev, 32), last: u64(ev, 40), name });
  }
  return { entries, entrySize: es, entryCount: n, headerOk: crc32(h) === crcStored,
    arrayOk: crc32(arr) === dv.getUint32(512 + 88, true) };
}

// Same table, but the partition called `name` ends at the last usable sector of a disk of `diskSectors` sectors.
export function extendPartition(buf, name, diskSectors) {
  const g = parseGpt(buf);
  const target = g.entries.find((e) => e.name === name); if (!target) throw new Error("no partition named " + name);
  if (g.entries.some((e) => e.first > target.first)) throw new Error(name + " is not the last partition");
  const out = buf.slice(0, 17408), dv = new DataView(out.buffer);
  const lastUsable = diskSectors - 34;
  dv.setBigUint64(1024 + target.index * g.entrySize + 40, BigInt(lastUsable), true);
  dv.setBigUint64(512 + 32, BigInt(diskSectors - 1), true);      // where the backup header would be
  dv.setBigUint64(512 + 48, BigInt(lastUsable), true);           // last usable sector
  dv.setUint32(512 + 88, crc32(out.subarray(1024, 1024 + g.entryCount * g.entrySize)), true);
  const hs = dv.getUint32(512 + 12, true); dv.setUint32(512 + 16, 0, true);
  dv.setUint32(512 + 16, crc32(out.subarray(512, 512 + hs)), true);
  return out;
}
