// Builds a bobcat-install.conf from form values. Pure functions (no DOM), so the same
// file runs in the browser and in the Node test. Mirrors tools/make-config.py.
(function (root) {
  "use strict";

  const bad = (re, v) => !re.test(v);
  const isInt = (v, lo, hi) => /^\d+$/.test(v) && +v >= lo && +v <= hi;
  const isIPv4 = (v) => { const p = v.split("."); return p.length === 4 && p.every((x) => /^\d{1,3}$/.test(x) && +x <= 255); };

  const checks = {
    hostname: (v) => bad(/^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/, v) && "letters, digits and hyphens (no leading or trailing hyphen)",
    ipv4: (v) => !isIPv4(v) && "an IPv4 address like 192.168.1.1",
    cidr: (v) => { const [a, p] = v.split("/"); return (!a || !isIPv4(a) || !/^\d+$/.test(p || "") || +p < 1 || +p > 32) && "an address with prefix, like 192.168.1.50/24"; },
    dns: (v) => v.replace(/ /g, "").split(",").some((x) => !isIPv4(x)) && "comma-separated IPv4 addresses",
    hostport: (v) => { const i = v.lastIndexOf(":"); const h = v.slice(0, i), p = v.slice(i + 1);
      return (i < 0 || !/^[A-Za-z0-9._-]+$/.test(h) || !isInt(p, 1, 65535)) && "host:port, like hub.example.org:4242"; },
    wifiPass: (v) => (v.length < 8 || v.length > 63) && "8 to 63 characters",
    github: (v) => v.replace(/ /g, "").split(",").filter(Boolean).some((u) => !/^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/.test(u) || u.includes("--")) && "not a GitHub username",
    reboot: (v) => !(/^\d+$/.test(v) && (+v === 0 || (+v >= 5 && +v <= 1440))) && "0 (never) or 5 to 1440 minutes",
    ifac: (v) => /["\\]/.test(v) && 'no " or \\ characters',
    sshKey: (v) => bad(/^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\s+[A-Za-z0-9+/=]+(\s.*)?$/, v) && "not a plain SSH public key line (options such as command= are not allowed)",
    hash: (v) => bad(/^\$(6|5|y)\$[^\s:]+\$[^\s:]+$/, v) && "a crypt hash such as $6$salt$hash",
    timezone: (v) => bad(/^[A-Za-z0-9_+\-]+(\/[A-Za-z0-9_+\-]+)*$/, v) && "a timezone name like Europe/Berlin",
  };

  const SECTIONS = [
    ["Wi-Fi (this hardware: 2.4 GHz only)", ["WIFI_SSID", "WIFI_PASS", "WIFI_HIDDEN", "WIFI_OPEN"]],
    ["Ethernet", ["ETH_MODE", "ETH_ADDRESS", "ETH_GATEWAY", "ETH_DNS"]],
    ["Operating system", ["HOSTNAME", "TIMEZONE", "SSH_AUTHORIZED_KEY", "SSH_GITHUB_USER", "ROOT_PASSWORD_HASH", "SKIP_FIRSTLOGIN_WIZARD"]],
    ["Radio (must match the other nodes)", ["FREQUENCY", "BANDWIDTH", "SPREADINGFACTOR", "CODINGRATE", "TXPOWER"]],
    ["Reticulum", ["TRANSPORT", "INTERFACE_MODE", "IFAC_NETNAME", "IFAC_PASSPHRASE", "TCP_SERVER_PORT", "TCP_CLIENT"]],
    ["Self-recovery", ["RESILIENCE", "NETWATCH_REBOOT_MINUTES"]],
  ];

  // the installer takes values literally and strips ONE pair of quotes and leading blanks
  const literal = (v) => (v !== v.trim() || (v.length >= 2 && v[0] === v[v.length - 1] && (v[0] === '"' || v[0] === "'")) ? `"${v}"` : v);
  const lines = (s) => (s || "").split(/\r?\n/).map((x) => x.trim()).filter((x) => x && !x.startsWith("#"));
  const list = (s) => (s || "").split(",").map((x) => x.trim()).filter(Boolean);

  // v: plain object of form values. Returns { text, errors: [{field, message}] }
  function build(v, today) {
    const items = [], errors = [];
    const add = (k, val) => items.push([k, val]);
    const need = (field, ok, message) => { if (ok) errors.push({ field, message }); };
    const t = (k) => (v[k] || "").trim();

    // network
    if (v.wifi) {
      if (!t("wifiSsid")) need("wifiSsid", true, "the network name is required");
      else add("WIFI_SSID", t("wifiSsid"));
      if (v.wifiHidden) add("WIFI_HIDDEN", "yes");
      if (v.wifiOpen) add("WIFI_OPEN", "yes");
      else { const p = v.wifiPass || ""; const e = checks.wifiPass(p); need("wifiPass", e, e); if (!e) add("WIFI_PASS", p); }
    }
    const eth = v.ethMode || "keep";
    if (eth !== "keep") add("ETH_MODE", eth);
    if (eth === "static") {
      let e = !t("ethAddress") ? "required for a static address" : checks.cidr(t("ethAddress")); need("ethAddress", e, e); if (!e) add("ETH_ADDRESS", t("ethAddress"));
      if (t("ethGateway")) { e = checks.ipv4(t("ethGateway")); need("ethGateway", e, e); if (!e) add("ETH_GATEWAY", t("ethGateway")); }
      if (t("ethDns")) { e = checks.dns(t("ethDns")); need("ethDns", e, e); if (!e) add("ETH_DNS", t("ethDns").replace(/ /g, "")); }
    }

    // system
    if (t("hostname")) { const e = checks.hostname(t("hostname")); need("hostname", e, e); if (!e) add("HOSTNAME", t("hostname")); }
    if (t("timezone")) { const e = checks.timezone(t("timezone")); need("timezone", e, e); if (!e) add("TIMEZONE", t("timezone")); }
    const keys = lines(v.sshKeys);
    const badKey = keys.map(checks.sshKey).find(Boolean);
    need("sshKeys", badKey, badKey);
    if (!badKey) keys.forEach((k) => add("SSH_AUTHORIZED_KEY", k));
    if (t("github")) { const e = checks.github(t("github")); need("github", e, e); if (!e) list(t("github")).forEach((u) => add("SSH_GITHUB_USER", u)); }
    if (t("rootHash")) { const e = checks.hash(t("rootHash")); need("rootHash", e, e); if (!e) add("ROOT_PASSWORD_HASH", t("rootHash")); }
    if (v.skipWizard) add("SKIP_FIRSTLOGIN_WIZARD", "yes");

    // radio: only what differs from the defaults
    const radio = [["FREQUENCY", "frequency", "915000000", (x) => !isInt(x, 150000000, 960000000) && "150000000 to 960000000 Hz"],
      ["BANDWIDTH", "bandwidth", "125000", (x) => !["125000", "250000", "500000"].includes(x) && "125000, 250000 or 500000"],
      ["SPREADINGFACTOR", "sf", "8", (x) => !isInt(x, 7, 12) && "7 to 12"],
      ["CODINGRATE", "cr", "5", (x) => !isInt(x, 5, 8) && "5 to 8"],
      ["TXPOWER", "txpower", "14", (x) => !isInt(x, 12, 16) && "12 to 16 dBm"]];
    for (const [key, field, def, chk] of radio) {
      const x = t(field) || def; const e = chk(x); need(field, e, e);
      if (!e && x !== def) add(key, x);
    }

    // reticulum
    if (v.transportOff) add("TRANSPORT", "no");
    if (t("ifacName") || t("ifacPass")) {
      for (const [f, k] of [["ifacName", "IFAC_NETNAME"], ["ifacPass", "IFAC_PASSPHRASE"]]) {
        const x = v[f] || ""; const e = !x.trim() ? "both IFAC fields are needed" : checks.ifac(x); need(f, e, e); if (!e) add(k, x);
      }
    }
    if ((v.mode || "full") !== "full") add("INTERFACE_MODE", v.mode);
    for (const h of lines(v.tcpClients)) { const e = checks.hostport(h); need("tcpClients", e, `${h}: ${e}`); if (!e) add("TCP_CLIENT", h); }
    if (t("tcpPort")) { const e = !isInt(t("tcpPort"), 1, 65535) && "1 to 65535"; need("tcpPort", e, e); if (!e) add("TCP_SERVER_PORT", t("tcpPort")); }

    // self-recovery
    if (v.recovery === false) add("RESILIENCE", "no");
    else if (t("reboot") && t("reboot") !== "20") { const e = checks.reboot(t("reboot")); need("reboot", e, e); if (!e) add("NETWATCH_REBOOT_MINUTES", t("reboot")); }

    // render: same layout as tools/make-config.py
    const out = [
      "# bobcat-install.conf, made by the web config generator on " + (today || new Date().toISOString().slice(0, 10)),
      "# Put this file, with exactly this name, on the BOBCFG partition of the flasher",
      "# SD card before powering the Bobcat on. Reference: docs/config-reference.md", "",
    ];
    for (const [title, keys2] of SECTIONS) {
      const block = items.filter(([k]) => keys2.includes(k));
      if (!block.length) continue;
      out.push(`# ===== ${title}`, ...block.map(([k, x]) => `${k}=${literal(x)}`), "");
    }
    return { text: out.join("\n"), errors, empty: items.length === 0 };
  }

  const api = { build, checks, literal };
  if (typeof module !== "undefined" && module.exports) module.exports = api; else root.BobcatConfig = api;
})(typeof window !== "undefined" ? window : globalThis);
