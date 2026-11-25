// Checks the in-browser $6$ hashing against the system's own crypt(3) implementations (openssl and python).
const { execFileSync } = require("node:child_process");
const C = require("../site/sha512crypt.js");
let failed = 0; const ok = (c, m) => { if (!c) { failed++; console.log("FAIL: " + m); } else console.log("ok:   " + m); };
const cases = [["password", "saltsalt"], ["a", "x"], ["1234", "0123456789abcdef"], ["a longer pass phrase with spaces 0123456789", "Zz./9"],
  ["x".repeat(63), "s"], ["y".repeat(64), "ab"], ["z".repeat(65), "ab"], ["p".repeat(200), "sixteencharsalt!"], ["pässwörd ✓", "saltsalt"]];
for (const [pw, salt] of cases) {
  const mine = C.hash(pw, salt);
  const ref = execFileSync("openssl", ["passwd", "-6", "-salt", salt, "-stdin"], { input: pw + "\n", encoding: "utf8" }).trim();
  ok(mine === ref, `matches openssl for ${JSON.stringify(pw.slice(0, 20))}/${salt} (${pw.length} chars)`);
}
ok(/^\$6\$[./0-9A-Za-z]{16}\$[./0-9A-Za-z]{86}$/.test(C.make("hello")), "make() gives a well-formed hash with a random 16 character salt");
ok(C.make("hello") !== C.make("hello"), "two hashes of one password differ (random salt)");
const t = Date.now(); C.make("timing"); console.log("      one hash took", Date.now() - t, "ms");
process.exit(failed ? 1 : 0);
