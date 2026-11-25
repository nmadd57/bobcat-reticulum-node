// Checks that files the web generator writes are accepted by the installer's own validator.
// Usage: node test/test-site-config.js   (needs bash and python3 with PyYAML, as the installer does)
const { build } = require("../site/config.js");
const { spawnSync } = require("child_process");
const fs = require("fs"), os = require("os"), path = require("path");

const installer = path.join(__dirname, "..", "installer", "install-template.sh");
let failed = 0;
const ok = (c, m) => { if (!c) { failed++; console.log("FAIL: " + m); } else console.log("ok:   " + m); };
const dry = (text) => {
  const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "bobcat-")), "c.conf");
  fs.writeFileSync(f, text);
  const r = spawnSync("bash", [installer, "--dry-run", "--config", f], { encoding: "utf8" });
  return { code: r.status, out: (r.stdout || "") + (r.stderr || "") };
};

const KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl you@laptop";
const cases = {
  "wifi + keys + radio": { wifi: true, wifiSsid: "Home Net", wifiPass: "correct horse battery", hostname: "bobcat-01", timezone: "Europe/Berlin",
    sshKeys: KEY + "\n", github: "octocat, nmadd57", skipWizard: true, frequency: "868000000", bandwidth: "250000", sf: "9", cr: "6", txpower: "13" },
  "static ethernet, no wifi": { wifi: false, ethMode: "static", ethAddress: "192.168.1.50/24", ethGateway: "192.168.1.1", ethDns: "192.168.1.1, 9.9.9.9" },
  "hidden wifi, transport off, ifac, tcp": { wifi: true, wifiSsid: "Hidden", wifiHidden: true, wifiPass: "12345678", transportOff: true,
    ifacName: "mynet", ifacPass: "a shared secret", mode: "gateway", tcpClients: "hub.example.org:4242\n192.168.1.20:4242", tcpPort: "4242" },
  "second user with password and sudo": { wifi: false, userName: "alice", userHash: "$6$abcdefgh$0123456789abcdefghijklmnopqrstuvwxyzABCDEFGH", userSudo: true },
  "second user with keys only": { wifi: false, userName: "bob", userKeys: KEY + "\n" },
  "second user with both": { wifi: false, userName: "carol", userHash: "$6$abcdefgh$0123456789abcdefghijklmnopqrstuvwxyzABCDEFGH", userKeys: KEY, userSudo: true },
  "recovery off": { wifi: false, recovery: false },
  "recovery reboot 45": { wifi: false, recovery: true, reboot: "45" },
};
for (const [name, v] of Object.entries(cases)) {
  const r = build(v, "2026-01-01");
  ok(r.errors.length === 0, `${name}: no form errors`);
  const d = dry(r.text);
  ok(d.code === 0, `${name}: installer dry run accepts it` + (d.code ? "\n" + d.out : ""));
}

const rejects = {
  "user without password or key": { userName: "alice" },
  "user named root": { userName: "root", userHash: "$6$s$h" },
  "user with a bad name": { userName: "Bad Name", userHash: "$6$s$h" },
  "user with plain password": { userName: "alice", userHash: "hunter2" },
  "sudo for a key-only user": { userName: "alice", userKeys: KEY, userSudo: true },
  "user key with options": { userName: "alice", userKeys: "command=\"id\" " + KEY },
  "short wifi pass": { wifi: true, wifiSsid: "x", wifiPass: "short" },
  "bad hostname": { hostname: "-bad-" },
  "key with options": { sshKeys: 'command="id" ' + KEY },
  "bad cidr": { ethMode: "static", ethAddress: "192.168.1.50" },
  "bad tcp": { tcpClients: "nohost" },
  "sf out of range": { sf: "13" },
  "ifac half set": { ifacName: "only-a-name" },
};
for (const [name, v] of Object.entries(rejects)) ok(build({ wifi: false, ...v }, "2026-01-01").errors.length > 0, `rejected: ${name}`);

ok(build({ wifi: false }).empty === true, "empty form writes nothing");
ok(build({ wifi: true, wifiSsid: "a", wifiOpen: true }).text.includes("WIFI_OPEN=yes"), "open network skips the passphrase");
process.exit(failed ? 1 : 0);
