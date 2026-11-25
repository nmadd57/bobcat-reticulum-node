// Tests the FAT writer against real filesystems: build with mkfs.fat, add a file in JS, check with fsck.fat and mtools.
import { addFile } from "../site/flash/fat.mjs";
import { execFileSync, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import fs from "node:fs"; import os from "node:os"; import path from "node:path";

const have = (t) => spawnSync("sh", ["-c", `command -v ${t}`]).status === 0;
if (!["mkfs.fat", "mcopy", "mdir", "mtype", "fsck.fat"].every(have)) { console.log("skip: needs dosfstools and mtools"); process.exit(0); }
let failed = 0; const ok = (c, m) => { if (!c) { failed++; console.log("FAIL: " + m); } else console.log("ok:   " + m); };
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "fat-")); const f = (n) => path.join(tmp, n);
const run = (cmd, args, o = {}) => execFileSync(cmd, args, { encoding: o.bin ? "buffer" : "utf8", stdio: ["ignore", "pipe", "pipe"], ...o });
const fsck = (img) => spawnSync("fsck.fat", ["-n", img], { encoding: "utf8" });

function make(name, bits, mb) {
  const img = f(name); fs.writeFileSync(img, Buffer.alloc(mb * 1024 * 1024)); run("mkfs.fat", ["-F", String(bits), "-n", "TESTBOOT", img]);
  fs.writeFileSync(f("a.txt"), "first file\n"); fs.writeFileSync(f("LongNameFile.TXT"), randomBytes(5000));
  run("mcopy", ["-i", img, f("a.txt"), "::a.txt"]); run("mcopy", ["-i", img, f("LongNameFile.TXT"), "::LongNameFile.TXT"]);
  return img;
}
function viaJs(img, name, data) { const buf = new Uint8Array(fs.readFileSync(img)); const r = addFile(buf, name, data, { now: new Date(2026, 10, 25, 12, 0, 0) }); fs.writeFileSync(img, buf); return r; }
const readBack = (img, name) => run("mtype", ["-i", img, "::" + name], { bin: true });

for (const [bits, mb] of [[16, 64], [32, 64], [16, 256]]) {
  const img = make(`fat${bits}-${mb}.img`, bits, mb), data = randomBytes(3000);
  const r = viaJs(img, "bobcat-install.conf", new Uint8Array(data));
  ok(fsck(img).status === 0, `FAT${bits}/${mb} MiB: fsck.fat finds no errors after adding the file` + (fsck(img).status ? "\n" + fsck(img).stdout : ""));
  ok(Buffer.compare(readBack(img, "bobcat-install.conf"), data) === 0, `FAT${bits}/${mb} MiB: the file reads back by its long name, byte for byte`);
  ok(/bobcat-install\.conf/.test(run("mdir", ["-i", img, "::"])), `FAT${bits}/${mb} MiB: mdir lists the long name (short name ${r.shortName.trim()})`);
  ok(Buffer.compare(readBack(img, "LongNameFile.TXT"), fs.readFileSync(f("LongNameFile.TXT"))) === 0 && readBack(img, "a.txt").toString() === "first file\n", `FAT${bits}/${mb} MiB: the files already there are intact`);
}
{ // replace an existing file with a bigger one; the old clusters must be freed
  const img = make("rep.img", 16, 64); viaJs(img, "bobcat-install.conf", new Uint8Array(randomBytes(9000)));
  const bigger = randomBytes(20000); viaJs(img, "bobcat-install.conf", new Uint8Array(bigger));
  ok(fsck(img).status === 0, "replacing a file: fsck.fat clean (no lost clusters)");
  ok(Buffer.compare(readBack(img, "bobcat-install.conf"), bigger) === 0, "replacing a file: the new content is read back");
  ok((run("mdir", ["-i", img, "::"]).match(/bobcat-install\.conf/g) || []).length === 1, "replacing a file: only one directory entry remains");
}
{ // short-name collision: another file already owns BOBCAT~1.CON
  const img = make("col.img", 32, 64); fs.writeFileSync(f("o.conf"), "other\n"); run("mcopy", ["-i", img, f("o.conf"), "::bobcat-other.conf"]);
  const r = viaJs(img, "bobcat-install.conf", new Uint8Array(Buffer.from("settings\n")));
  ok(r.shortName !== "BOBCAT~1CON", `a colliding short name is avoided (got ${r.shortName.trim()})`);
  ok(fsck(img).status === 0 && readBack(img, "bobcat-install.conf").toString() === "settings\n" && readBack(img, "bobcat-other.conf").toString() === "other\n", "both files are fine after the collision");
}
{ // an exact 8.3 name needs no long-name entries; an empty-ish and a cluster-exact file
  const img = make("e.img", 16, 64); viaJs(img, "README.TXT", new Uint8Array(Buffer.from("hi\n")));
  ok(fsck(img).status === 0 && readBack(img, "README.TXT").toString() === "hi\n", "an exact 8.3 name works");
  const cl = 512 * 4, d = randomBytes(cl * 3); viaJs(img, "exact.dat", new Uint8Array(d));
  ok(fsck(img).status === 0 && Buffer.compare(readBack(img, "exact.dat"), d) === 0, "a file that is an exact multiple of the cluster size works");
}
fs.rmSync(tmp, { recursive: true });
process.exit(failed ? 1 : 0);
