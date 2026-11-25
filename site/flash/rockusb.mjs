// Rockchip "rockusb" client over WebUSB: U-Boot's download mode (Recovery + Reset, USB id 2207:350a).
// Only the first 32 MiB of the eMMC are readable and writable in this mode on the boards tested.
export const ROCKUSB_FILTER = { vendorId: 0x2207, productId: 0x350a };
const OP = { READ_FLASH_INFO: 0x1a, READ_CHIP_INFO: 0x1b, READ_LBA: 0x14, WRITE_LBA: 0x15, DEVICE_RESET: 0xff };
const CBW_SIG = 0x43425355, CSW_SIG = 0x53425355;
export const SECTOR = 512, CHUNK_SECTORS = 128;

// 31-byte command block wrapper: signature, tag, transfer length, flags, LUN, CDB length, 16-byte CDB.
export function cbw(tag, op, { dataLen = 0, dirIn = true, sub = 0, lba = 0, sectors = 0, cdbLen = 10 } = {}) {
  const b = new Uint8Array(31), dv = new DataView(b.buffer);
  dv.setUint32(0, CBW_SIG, true); dv.setUint32(4, tag, true); dv.setUint32(8, dataLen, true);
  b[12] = dirIn ? 0x80 : 0; b[13] = 0; b[14] = cdbLen;
  b[15] = op; b[16] = sub; dv.setUint32(17, lba, false); b[21] = 0; dv.setUint16(22, sectors, false);
  return b;
}

export class RockUsb {
  constructor(device) { this.dev = device; this.tag = 0; this.log = () => {}; }
  async open() {
    const d = this.dev; await d.open();
    if (!d.configuration) await d.selectConfiguration(1);
    const iface = d.configuration.interfaces.find((i) => i.alternate.interfaceClass === 0xff) || d.configuration.interfaces[0];
    await d.claimInterface(iface.interfaceNumber);
    this.iface = iface.interfaceNumber;
    for (const e of iface.alternate.endpoints) { if (e.direction === "out") this.epOut = e.endpointNumber; else this.epIn = e.endpointNumber; }
    if (!this.epOut || !this.epIn) throw new Error("rockusb endpoints not found");
  }
  async close() { try { await this.dev.releaseInterface(this.iface); await this.dev.close(); } catch {} }
  async readExact(n) {
    const out = new Uint8Array(n); let got = 0;
    while (got < n) { const r = await this.dev.transferIn(this.epIn, n - got); if (r.status === "stall") throw new Error("USB stall"); const v = new Uint8Array(r.data.buffer, r.data.byteOffset, r.data.byteLength); if (!v.length) throw new Error("USB read returned no data"); out.set(v, got); got += v.length; }
    return out;
  }
  async csw(tag) {
    const c = await this.readExact(13), dv = new DataView(c.buffer);
    if (dv.getUint32(0, true) !== CSW_SIG || dv.getUint32(4, true) !== tag) throw new Error("unexpected USB response");
    return c[12];
  }
  async cmd(op, o, outData) {
    const tag = ++this.tag;
    await this.dev.transferOut(this.epOut, cbw(tag, op, o));
    let data = null;
    if (o.dataLen && o.dirIn !== false) data = await this.readExact(o.dataLen);
    else if (o.dataLen) await this.dev.transferOut(this.epOut, outData);
    const status = await this.csw(tag);
    if (status !== 0) throw new Error(`device reported status ${status}`);
    return data;
  }
  // 11 bytes: flash size in sectors (little endian u32) first. READ_FLASH_INFO uses a 6-byte CDB.
  async flashInfo() {
    const d = await this.cmd(OP.READ_FLASH_INFO, { dataLen: 11, cdbLen: 6 });
    return { sectors: new DataView(d.buffer).getUint32(0, true), raw: d };
  }
  async readLba(lba, sectors) {
    const parts = [];
    for (let s = 0; s < sectors; s += CHUNK_SECTORS) { const n = Math.min(CHUNK_SECTORS, sectors - s); parts.push(await this.cmd(OP.READ_LBA, { dataLen: n * SECTOR, lba: lba + s, sectors: n })); }
    const out = new Uint8Array(sectors * SECTOR); let o = 0; for (const p of parts) { out.set(p, o); o += p.length; }
    return out;
  }
  async writeLba(lba, data, progress) {
    if (data.length % SECTOR) throw new Error("data must be a whole number of sectors");
    const total = data.length / SECTOR;
    for (let s = 0; s < total; s += CHUNK_SECTORS) {
      const n = Math.min(CHUNK_SECTORS, total - s);
      await this.cmd(OP.WRITE_LBA, { dataLen: n * SECTOR, dirIn: false, lba: lba + s, sectors: n }, data.subarray(s * SECTOR, (s + n) * SECTOR));
      if (progress) progress(s + n, total);
    }
  }
  // Software reset. The device drops off the bus, so a missing reply is expected.
  async reset() {
    const tag = ++this.tag;
    await this.dev.transferOut(this.epOut, cbw(tag, OP.DEVICE_RESET, { dirIn: false, cdbLen: 6 }));
    try { await this.csw(tag); } catch {}
  }
}
