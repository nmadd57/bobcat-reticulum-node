// The browser-side PBKDF2 hash must equal Python's hashlib (which is what rnsd-webui verifies with).
const { spawnSync } = require("node:child_process");
const W = require("../site/webuihash.js");
let failed = 0; const ok = (c, m) => { if (!c) { failed++; console.log("FAIL: " + m); } else console.log("ok:   " + m); };
(async () => {
  const salt = "00112233445566778899aabbccddeeff";
  for (const [pw, n] of [["correct horse battery", 1000], ["pässwörd ✓ with spaces", 5000], ["x", 200000]]) {
    const mine = await W.hash(pw, salt, n);
    const py = spawnSync("python3", ["-c", `import hashlib,sys;print('pbkdf2-sha256$${n}$${salt}$'+hashlib.pbkdf2_hmac('sha256',sys.stdin.buffer.read(),bytes.fromhex('${salt}'),${n},dklen=32).hex())`], { input: pw, encoding: "utf8" }).stdout.trim();
    ok(mine === py, `matches Python's hashlib for ${JSON.stringify(pw.slice(0, 12))} at ${n} iterations`);
  }
  const a = await W.make("same"), b = await W.make("same");
  ok(a !== b && /^pbkdf2-sha256\$200000\$[0-9a-f]{32}\$[0-9a-f]{64}$/.test(a), "make() gives a well-formed hash with a random salt");
  process.exit(failed ? 1 : 0);
})();
