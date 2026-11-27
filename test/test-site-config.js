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
  "second user with GitHub keys only": { wifi: false, userName: "erin", userGithub: "octocat, nmadd57" },
  "web interface, default port": { wifi: false, webui: true, webuiHash: "pbkdf2-sha256$200000$00112233445566778899aabbccddeeff$aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899" },
  "web interface, own port": { wifi: false, webui: true, webuiHash: "pbkdf2-sha256$200000$00112233445566778899aabbccddeeff$aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899", webuiPort: "9443" },
  "web interface with a trusted certificate": { wifi: false, webui: true, webuiHash: "pbkdf2-sha256$200000$00112233445566778899aabbccddeeff$aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899", webuiDomain: "Bobcat04.Example.com", webuiToken: "abcdefghijklmnopqrstuvwxyz0123456789ABCD", webuiEmail: "me@example.com" },
  "web interface on port 443 explicitly": { wifi: false, webui: true, webuiHash: "pbkdf2-sha256$200000$00112233445566778899aabbccddeeff$aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899", webuiPort: "443" },
  "recovery off": { wifi: false, recovery: false },
  "recovery reboot 45": { wifi: false, recovery: true, reboot: "45" },
};
function BobcatConfig_hasKey(text, word) { return text.includes(word); }


// WireGuard: configs built from random keys
const key = () => require("node:crypto").randomBytes(32).toString("base64");
const wg = (extra = "", allowed = "10.8.0.0/24") => `[Interface]\nPrivateKey = ${key()}\nAddress = 10.8.0.2/24\n${extra}\n[Peer]\nPublicKey = ${key()}\nEndpoint = vpn.example.com:51820\nAllowedIPs = ${allowed}\nPersistentKeepalive = 25\n`;
  cases["wireguard"] = { wifi: false, wgConfig: wg() };
  cases["wireguard, own interface name"] = { wifi: false, wgConfig: wg(), wgIface: "office" };
  cases["wireguard, full tunnel with DNS and CRLF"] = { wifi: false, wgConfig: wg("DNS = 10.8.0.1", "0.0.0.0/0, ::/0").replace(/\n/g, "\r\n") };
  ok(!BobcatConfig_hasKey(build({ wifi: false, wgConfig: wg() }).text, "PrivateKey") && /^WIREGUARD_CONFIG_B64=[A-Za-z0-9+\/=]+$/m.test(build({ wifi: false, wgConfig: wg() }).text), "the key reaches the settings only inside the base64 line");
  const sample = wg(); const t = build({ wifi: false, wgConfig: sample }).text;
  const decoded = Buffer.from(/^WIREGUARD_CONFIG_B64=(.*)$/m.exec(t)[1], "base64").toString();
  ok(decoded.trim() === sample.trim(), "the base64 setting decodes back to the pasted config");


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
  "user with a bad GitHub name": { userName: "erin", userGithub: "bad--name" },
  "web interface without a password": { webui: true },
  "web interface with a plain password": { webui: true, webuiHash: "hunter2" },
  "web interface port out of range": { webui: true, webuiHash: "pbkdf2-sha256$200000$00112233445566778899aabbccddeeff$aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899", webuiPort: "70000" },
  "web interface on the Reticulum TCP port": { webui: true, webuiHash: "pbkdf2-sha256$200000$00112233445566778899aabbccddeeff$aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899", webuiPort: "4242", tcpPort: "4242" },
  "web interface: a domain without a token": { webui: true, webuiHash: "pbkdf2-sha256$200000$00112233445566778899aabbccddeeff$aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899", webuiDomain: "bobcat.example.com" },
  "web interface: a token without a domain": { webui: true, webuiHash: "pbkdf2-sha256$200000$00112233445566778899aabbccddeeff$aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899", webuiToken: "abcdefghijklmnopqrstuvwxyz0123456789ABCD" },
  "web interface: a domain that is not a name": { webui: true, webuiHash: "pbkdf2-sha256$200000$00112233445566778899aabbccddeeff$aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899", webuiDomain: "bobcat", webuiToken: "abcdefghijklmnopqrstuvwxyz0123456789ABCD" },
  "web interface: something that is not a token": { webui: true, webuiHash: "pbkdf2-sha256$200000$00112233445566778899aabbccddeeff$aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899", webuiDomain: "bobcat.example.com", webuiToken: "short" },
  "web interface: a bad contact address": { webui: true, webuiHash: "pbkdf2-sha256$200000$00112233445566778899aabbccddeeff$aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899", webuiDomain: "bobcat.example.com", webuiToken: "abcdefghijklmnopqrstuvwxyz0123456789ABCD", webuiEmail: "nope" },
  "short wifi pass": { wifi: true, wifiSsid: "x", wifiPass: "short" },
  "bad hostname": { hostname: "-bad-" },
  "key with options": { sshKeys: 'command="id" ' + KEY },
  "bad cidr": { ethMode: "static", ethAddress: "192.168.1.50" },
  "bad tcp": { tcpClients: "nohost" },
  "sf out of range": { sf: "13" },
  "ifac half set": { ifacName: "only-a-name" },
};
rejects["wireguard with a PostUp hook"] = { wgConfig: wg("PostUp = touch /tmp/pwned") };
rejects["wireguard with a SaveConfig"] = { wgConfig: wg("SaveConfig = true") };
rejects["wireguard with an unknown setting"] = { wgConfig: wg("Whatever = 1") };
rejects["wireguard with a bad private key"] = { wgConfig: "[Interface]\nPrivateKey = nope\nAddress = 10.0.0.2/24\n[Peer]\nPublicKey = " + key() + "\nAllowedIPs = 10.0.0.0/8\n" };
rejects["wireguard without a peer"] = { wgConfig: "[Interface]\nPrivateKey = " + key() + "\nAddress = 10.0.0.2/24\n" };
rejects["wireguard with bad AllowedIPs"] = { wgConfig: wg("", "10.8.0.0/99x") };
rejects["wireguard with a bad interface name"] = { wgConfig: wg(), wgIface: "a b" };
for (const [name, v] of Object.entries(rejects)) ok(build({ wifi: false, ...v }, "2026-01-01").errors.length > 0, `rejected: ${name}`);

ok(build({ wifi: false }).empty === true, "empty form writes nothing");
{ const t = build({ wifi: false, webui: true, webuiHash: "pbkdf2-sha256$200000$00112233445566778899aabbccddeeff$aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899", webuiDomain: "Bobcat04.Example.com", webuiToken: "abcdefghijklmnopqrstuvwxyz0123456789ABCD", webuiPort: "443" }).text;
  ok(/^WEBUI_DOMAIN=bobcat04\.example\.com$/m.test(t) && /^CLOUDFLARE_API_TOKEN=abcdefghijklmnopqrstuvwxyz0123456789ABCD$/m.test(t) && !/^WEBUI_PORT=/m.test(t), "the domain is lowercased, the token written, and the default port 443 is left out"); }
ok(build({ wifi: true, wifiSsid: "a", wifiOpen: true }).text.includes("WIFI_OPEN=yes"), "open network skips the passphrase");
process.exit(failed ? 1 : 0);
