// Add (or replace) one file in the root directory of a FAT16 or FAT32 filesystem image held in memory, with a
// proper long file name. Used to put bobcat-install.conf into the boot partition before it is flashed.
const ENC = new TextEncoder();

function parse(img) {
  const dv = new DataView(img.buffer, img.byteOffset, img.byteLength);
  const bps = dv.getUint16(11, true), spc = img[13], reserved = dv.getUint16(14, true), nfats = img[16];
  const rootEntries = dv.getUint16(17, true);
  const total = dv.getUint16(19, true) || dv.getUint32(32, true);
  const fatSize = dv.getUint16(22, true) || dv.getUint32(36, true);
  if (img[510] !== 0x55 || img[511] !== 0xaa || !bps || !spc || !nfats || !fatSize) throw new Error("not a FAT filesystem");
  const rootSectors = Math.ceil((rootEntries * 32) / bps);
  const dataStart = reserved + nfats * fatSize + rootSectors;
  const clusters = Math.floor((total - dataStart) / spc);
  const type = clusters < 4085 ? 12 : clusters < 65525 ? 16 : 32;
  if (type === 12) throw new Error("FAT12 is not supported");
  return { dv, bps, spc, reserved, nfats, rootEntries, fatSize, rootSectors, dataStart, clusters, type,
    rootCluster: type === 32 ? dv.getUint32(44, true) : 0, fsinfo: type === 32 ? dv.getUint16(48, true) : 0,
    cbytes: bps * spc };
}

export function addFile(img, name, data, opts = {}) {
  const f = parse(img), now = opts.now || new Date();
  const fatAt = (n) => f.reserved * f.bps + n * f.fatSize * f.bps;
  const getFat = (c) => f.type === 16 ? f.dv.getUint16(fatAt(0) + c * 2, true) : f.dv.getUint32(fatAt(0) + c * 4, true) & 0x0fffffff;
  const setFat = (c, v) => { for (let i = 0; i < f.nfats; i++) {
    if (f.type === 16) f.dv.setUint16(fatAt(i) + c * 2, v, true);
    else f.dv.setUint32(fatAt(i) + c * 4, (f.dv.getUint32(fatAt(i) + c * 4, true) & 0xf0000000) | (v & 0x0fffffff), true); } };
  const EOC = f.type === 16 ? 0xffff : 0x0fffffff, isEnd = (v) => v >= (f.type === 16 ? 0xfff8 : 0x0ffffff8);
  const clusterAt = (c) => (f.dataStart + (c - 2) * f.spc) * f.bps;

  // root directory slots as [byte offset] lists
  const dirOffsets = [];
  if (f.type === 16) { const base = (f.reserved + f.nfats * f.fatSize) * f.bps; for (let i = 0; i < f.rootEntries; i++) dirOffsets.push(base + i * 32); }
  else { for (let c = f.rootCluster; c >= 2 && !isEnd(c); c = getFat(c)) for (let i = 0; i < f.cbytes / 32; i++) dirOffsets.push(clusterAt(c) + i * 32); }

  // 1. remove an existing entry with the same long (or short) name, freeing its clusters
  const wanted = name.toLowerCase();
  let lfnParts = [], lfnStart = -1;
  for (let i = 0; i < dirOffsets.length; i++) {
    const o = dirOffsets[i], first = img[o];
    if (first === 0x00) break;
    if (first === 0xe5) { lfnParts = []; lfnStart = -1; continue; }
    if (img[o + 11] === 0x0f) {
      if (first & 0x40) { lfnParts = []; lfnStart = i; }
      let s = ""; for (const r of [[1, 10], [14, 12], [28, 4]]) for (let k = 0; k < r[1]; k += 2) { const c = f.dv.getUint16(o + r[0] + k, true); if (c && c !== 0xffff) s += String.fromCharCode(c); }
      lfnParts.unshift(s); continue;
    }
    const short = new TextDecoder().decode(img.subarray(o, o + 8)).trimEnd() + (img[o + 8] !== 0x20 ? "." + new TextDecoder().decode(img.subarray(o + 8, o + 11)).trimEnd() : "");
    const long = lfnParts.length ? lfnParts.join("") : short;
    if (!(img[o + 11] & 0x18) && long.toLowerCase() === wanted) {
      for (let c = (f.type === 32 ? f.dv.getUint16(o + 20, true) << 16 : 0) | f.dv.getUint16(o + 26, true); c >= 2 && !isEnd(c); ) { const nx = getFat(c); setFat(c, 0); c = nx; }
      for (let k = lfnStart >= 0 ? lfnStart : i; k <= i; k++) img[dirOffsets[k]] = 0xe5;
    }
    lfnParts = []; lfnStart = -1;
  }

  // 2. a short name that does not collide with any existing one
  const existing = new Set();
  for (const o of dirOffsets) { if (img[o] === 0x00) break; if (img[o] !== 0xe5 && img[o + 11] !== 0x0f) existing.add(new TextDecoder().decode(img.subarray(o, o + 11))); }
  const dot = name.lastIndexOf("."), baseRaw = dot > 0 ? name.slice(0, dot) : name, extRaw = dot > 0 ? name.slice(dot + 1) : "";
  const clean = (s) => s.toUpperCase().replace(/[^A-Z0-9_$%'\-@~!(){}^#&]/g, "");
  const base = clean(baseRaw), ext = clean(extRaw).slice(0, 3);
  const exact83 = base.length <= 8 && baseRaw === baseRaw.toUpperCase() && extRaw === extRaw.toUpperCase() && base === baseRaw && ext === extRaw && extRaw.length <= 3;
  let short11, n = 0;
  do { n++; const stem = exact83 && n === 1 ? base : base.slice(0, 6) + "~" + n; short11 = stem.padEnd(8, " ") + ext.padEnd(3, " "); } while (existing.has(short11));
  const needLfn = !exact83;

  // 3. long-name entries (highest order first) then the short entry
  const entries = [];
  let sum = 0; for (let i = 0; i < 11; i++) sum = ((sum >> 1) | ((sum & 1) << 7)) + short11.charCodeAt(i) & 0xff;
  if (needLfn) {
    const chars = [...name].map((c) => c.charCodeAt(0)); chars.push(0); while (chars.length % 13) chars.push(0xffff);
    const count = chars.length / 13;
    for (let k = count; k >= 1; k--) {
      const e = new Uint8Array(32), ev = new DataView(e.buffer), part = chars.slice((k - 1) * 13, k * 13);
      e[0] = k | (k === count ? 0x40 : 0); e[11] = 0x0f; e[12] = 0; e[13] = sum;
      [[1, 0, 5], [14, 5, 6], [28, 11, 2]].forEach(([off, from, len]) => { for (let j = 0; j < len; j++) ev.setUint16(off + j * 2, part[from + j], true); });
      entries.push(e);
    }
  }

  // 4. clusters for the data
  const need = Math.max(1, Math.ceil(data.length / f.cbytes));
  const free = []; for (let c = 2; c < f.clusters + 2 && free.length < need; c++) if (getFat(c) === 0) free.push(c);
  if (free.length < need) throw new Error("the boot partition has no room for the file");
  for (let i = 0; i < need; i++) setFat(free[i], i + 1 < need ? free[i + 1] : EOC);
  for (let i = 0; i < need; i++) { const o = clusterAt(free[i]); img.fill(0, o, o + f.cbytes); img.set(data.subarray(i * f.cbytes, (i + 1) * f.cbytes), o); }

  const se = new Uint8Array(32), sv = new DataView(se.buffer);
  se.set(ENC.encode(short11), 0); se[11] = 0x20;
  const date = ((now.getFullYear() - 1980) << 9) | ((now.getMonth() + 1) << 5) | now.getDate(), time = (now.getHours() << 11) | (now.getMinutes() << 5) | (now.getSeconds() >> 1);
  sv.setUint16(14, time, true); sv.setUint16(16, date, true); sv.setUint16(18, date, true); sv.setUint16(22, time, true); sv.setUint16(24, date, true);
  if (f.type === 32) sv.setUint16(20, free[0] >>> 16, true);
  sv.setUint16(26, free[0] & 0xffff, true); sv.setUint32(28, data.length, true);
  entries.push(se);

  // 5. find a run of free slots and write the entries
  let run = -1;
  for (let i = 0; i + entries.length <= dirOffsets.length; i++) {
    let okRun = true; for (let k = 0; k < entries.length; k++) { const b = img[dirOffsets[i + k]]; if (b !== 0x00 && b !== 0xe5) { okRun = false; i += k; break; } }
    if (okRun) { run = i; break; }
  }
  if (run < 0) { for (const c of free) setFat(c, 0); throw new Error("the root directory is full"); }
  entries.forEach((e, k) => img.set(e, dirOffsets[run + k]));

  // 6. FAT32: keep the free-cluster hint roughly right
  if (f.type === 32 && f.fsinfo) { const o = f.fsinfo * f.bps; if (f.dv.getUint32(o + 488, true) !== 0xffffffff) f.dv.setUint32(o + 488, Math.max(0, f.dv.getUint32(o + 488, true) - need), true); }
  return { shortName: short11, clusters: free };
}
