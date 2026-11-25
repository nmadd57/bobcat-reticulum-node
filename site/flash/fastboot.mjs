// Standard fastboot over WebUSB (interface class ff/42/03), as served by U-Boot's `fastboot usb 0`.
export const FASTBOOT_FILTER = { classCode: 0xff, subclassCode: 0x42, protocolCode: 0x03 };
const DEC = new TextDecoder(), ENC = new TextEncoder();
export const MAX_DATA_PACKET = 1024 * 1024;

export class Fastboot {
  constructor(device) { this.dev = device; this.log = () => {}; }
  async open() {
    const d = this.dev; await d.open();
    if (!d.configuration) await d.selectConfiguration(1);
    const iface = d.configuration.interfaces.find((i) => i.alternate.interfaceClass === 0xff && i.alternate.interfaceSubclass === 0x42 && i.alternate.interfaceProtocol === 0x03);
    if (!iface) throw new Error("no fastboot interface on this device");
    await d.claimInterface(iface.interfaceNumber); this.iface = iface.interfaceNumber;
    for (const e of iface.alternate.endpoints) { if (e.direction === "out") this.epOut = e.endpointNumber; else this.epIn = e.endpointNumber; }
  }
  async close() { try { await this.dev.releaseInterface(this.iface); await this.dev.close(); } catch {} }
  async send(text) { await this.dev.transferOut(this.epOut, ENC.encode(text)); }
  // Read replies until one that ends the command. INFO lines are collected; FAIL throws.
  async reply() {
    const info = [];
    for (;;) {
      const r = await this.dev.transferIn(this.epIn, 64);
      if (r.status === "stall") throw new Error("USB stall");
      const t = DEC.decode(new Uint8Array(r.data.buffer, r.data.byteOffset, r.data.byteLength)), kind = t.slice(0, 4), rest = t.slice(4);
      if (kind === "INFO") { info.push(rest); this.log(rest); continue; }
      if (kind === "OKAY" || kind === "DATA") return { kind, text: rest, info };
      if (kind === "FAIL") throw new Error("device refused: " + rest);
      throw new Error("unexpected fastboot reply: " + t);
    }
  }
  async command(text) { await this.send(text); return this.reply(); }
  async getvar(name) { const r = await this.command("getvar:" + name); return r.text; }
  async maxDownload() { const v = await this.getvar("max-download-size"); return parseInt(v, 16); }
  async partitionSize(name) { return parseInt(await this.getvar("partition-size:" + name), 16); }
  async download(bytes, progress) {
    const hex = bytes.length.toString(16).padStart(8, "0");
    const r = await this.command("download:" + hex);
    if (r.kind !== "DATA" || parseInt(r.text, 16) !== bytes.length) throw new Error("device did not accept the download size");
    for (let o = 0; o < bytes.length; o += MAX_DATA_PACKET) { await this.dev.transferOut(this.epOut, bytes.subarray(o, Math.min(o + MAX_DATA_PACKET, bytes.length))); if (progress) progress(Math.min(o + MAX_DATA_PACKET, bytes.length), bytes.length); }
    await this.reply();
  }
  async flash(partition, bytes, progress) { await this.download(bytes, progress); await this.command("flash:" + partition); }
  async reboot() { await this.send("reboot"); try { await this.reply(); } catch {} }
}
