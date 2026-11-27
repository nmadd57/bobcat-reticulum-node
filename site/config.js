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
    userName: (v) => (bad(/^[a-z_][a-z0-9_-]{0,31}$/, v) || v === "root") && "lowercase letters, digits, - and _, starting with a letter or _ (not root)",
    hash: (v) => bad(/^\$(6|5|y)\$[^\s:]+\$[^\s:]+$/, v) && "a crypt hash such as $6$salt$hash",
    domain: (v) => bad(/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/, v.toLowerCase()) && "a full domain name such as bobcat.example.com",
    cfToken: (v) => bad(/^[A-Za-z0-9_-]{20,100}$/, v) && "that does not look like a Cloudflare API token (use one with the Zone / DNS / Edit permission)",
    email: (v) => bad(/^[^@\s]+@[^@\s]+\.[^@\s]+$/, v) && "an email address",
    webuiHash: (v) => bad(/^(pbkdf2-sha256\$[0-9]{1,7}\$[0-9a-f]{2,}\$[0-9a-f]{2,}|scrypt\$[0-9]+\$[0-9]+\$[0-9]+\$[0-9a-f]+\$[0-9a-f]+)$/, v) && "a pbkdf2-sha256$... hash (type a password and the page makes one)",
    timezone: (v) => bad(/^[A-Za-z0-9_+\-]+(\/[A-Za-z0-9_+\-]+)*$/, v) && "a timezone name like Europe/Berlin",
  };

  // A wg-quick config, checked as data (the same rules as the installer): no script hooks, only plain WireGuard settings.
  function wireguardProblems(text) {
    const problems = [], b64 = /^[A-Za-z0-9+/]{43}=$/, cidr = /^[0-9A-Fa-f:.]+\/[0-9]{1,3}$/;
    let section = "", iface = 0, priv = false, addr = false, peers = 0, pub = false, allowed = false;
    const problem = (m) => { if (!problems.includes(m)) problems.push(m); };
    const peerDone = () => { if (section === "peer" && !(pub && allowed)) problem("every [Peer] needs a PublicKey and AllowedIPs"); };
    if (text.length > 8192) problem("the config is larger than 8 KiB");
    if (/[^\x20-\x7e\s]/.test(text)) problem("the config contains control or non-ASCII characters");
    for (let raw of text.split(/\r?\n/)) {
      const line = raw.replace(/#.*/, "").trim();
      if (!line) continue;
      const sec = /^\[([A-Za-z]+)\]$/.exec(line);
      if (sec) {
        peerDone();
        const name = sec[1].toLowerCase();
        if (name === "interface") { if (iface++) problem("only one [Interface] section is allowed"); section = "interface"; }
        else if (name === "peer") { section = "peer"; peers++; pub = false; allowed = false; }
        else { problem("unknown section [" + sec[1] + "]"); section = ""; }
        continue;
      }
      const kv = /^([A-Za-z]+)\s*=\s*(.*)$/.exec(line);
      if (!kv) { problem("not a 'Key = value' line: " + line.slice(0, 40)); continue; }
      const key = kv[1].toLowerCase(), val = kv[2];
      if (["preup", "postup", "predown", "postdown", "saveconfig"].includes(key)) { problem(kv[1] + " is not supported: script hooks would run commands as root (the settings are data, never code)"); continue; }
      const num = (re, lo, hi) => re.test(val) && +val >= lo && +val <= hi;
      switch (section + ":" + key) {
        case "interface:privatekey": priv = true; if (!b64.test(val)) problem("PrivateKey is not a WireGuard key (44 characters of base64)"); break;
        case "interface:address": addr = true; val.split(/[\s,]+/).filter(Boolean).forEach((i) => { if (!cidr.test(i)) problem("Address '" + i + "' must look like 10.0.0.2/24"); }); break;
        case "interface:listenport": if (!num(/^\d+$/, 1, 65535)) problem("ListenPort must be 1-65535"); break;
        case "interface:dns": if (!/^[A-Za-z0-9.:,\s-]+$/.test(val)) problem("DNS has odd characters"); break;
        case "interface:mtu": if (!num(/^\d+$/, 576, 9000)) problem("MTU must be 576-9000"); break;
        case "interface:table": if (!/^(off|auto|\d+)$/.test(val)) problem("Table must be off, auto or a number"); break;
        case "interface:fwmark": if (!/^(off|0x[0-9a-fA-F]+|\d+)$/.test(val)) problem("FwMark must be off or a number"); break;
        case "peer:publickey": pub = true; if (!b64.test(val)) problem("PublicKey is not a WireGuard key (44 characters of base64)"); break;
        case "peer:presharedkey": if (!b64.test(val)) problem("PresharedKey is not a WireGuard key (44 characters of base64)"); break;
        case "peer:allowedips": allowed = true; val.split(/[\s,]+/).filter(Boolean).forEach((i) => { if (!cidr.test(i)) problem("AllowedIPs '" + i + "' must look like 10.0.0.0/24"); }); break;
        case "peer:endpoint": { const m = /^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\]):(\d{1,5})$/.exec(val); if (!m || +m[2] < 1 || +m[2] > 65535) problem("Endpoint must look like host:port"); break; }
        case "peer:persistentkeepalive": if (!num(/^\d+$/, 0, 65535)) problem("PersistentKeepalive must be 0-65535"); break;
        default: problem("'" + kv[1] + "' is not a setting this installer accepts in [" + (section || "no section") + "]");
      }
    }
    peerDone();
    if (!(iface && priv && addr)) problem("the config needs an [Interface] with a PrivateKey and an Address");
    if (peers < 1) problem("the config needs at least one [Peer]");
    return problems;
  }
  const toBase64 = (text) => (typeof btoa === "function" ? btoa(unescape(encodeURIComponent(text))) : Buffer.from(text, "utf8").toString("base64"));

  const SECTIONS = [
    ["Wi-Fi (this hardware: 2.4 GHz only)", ["WIFI_SSID", "WIFI_PASS", "WIFI_HIDDEN", "WIFI_OPEN"]],
    ["Ethernet", ["ETH_MODE", "ETH_ADDRESS", "ETH_GATEWAY", "ETH_DNS"]],
    ["Operating system", ["HOSTNAME", "TIMEZONE", "SSH_AUTHORIZED_KEY", "SSH_GITHUB_USER", "ROOT_PASSWORD_HASH", "USER_NAME", "USER_PASSWORD_HASH", "USER_SSH_KEY", "USER_SSH_GITHUB_USER", "USER_SUDO", "SKIP_FIRSTLOGIN_WIZARD"]],
    ["Radio (must match the other nodes)", ["FREQUENCY", "BANDWIDTH", "SPREADINGFACTOR", "CODINGRATE", "TXPOWER"]],
    ["Reticulum", ["TRANSPORT", "INTERFACE_MODE", "IFAC_NETNAME", "IFAC_PASSPHRASE", "TCP_SERVER_PORT", "TCP_CLIENT"]],
    ["VPN (WireGuard)", ["WIREGUARD_CONFIG_B64", "WIREGUARD_INTERFACE"]],
    ["Web interface", ["WEBUI", "WEBUI_PASSWORD_HASH", "WEBUI_PORT", "WEBUI_DOMAIN", "CLOUDFLARE_API_TOKEN", "ACME_EMAIL"]],
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
    if (t("userName")) {
      const e = checks.userName(t("userName")); need("userName", e, e);
      const ukeys = lines(v.userKeys), ubad = ukeys.map(checks.sshKey).find(Boolean); need("userKeys", ubad, ubad);
      const ugh = t("userGithub") ? list(t("userGithub")) : [], ughBad = t("userGithub") ? checks.github(t("userGithub")) : "";
      need("userGithub", ughBad, ughBad);
      const h = !t("userHash") ? (ukeys.length || ugh.length ? "" : "give a password, an SSH key or a GitHub user, or this user cannot log in") : checks.hash(t("userHash")); need("userHash", h, h);
      if (v.userSudo && !t("userHash")) need("userHash", true, "sudo asks for the user's password, so set one");
      if (!e) add("USER_NAME", t("userName"));
      if (t("userHash") && !h) add("USER_PASSWORD_HASH", t("userHash"));
      if (!ubad) ukeys.forEach((k) => add("USER_SSH_KEY", k));
      if (!ughBad) ugh.forEach((u) => add("USER_SSH_GITHUB_USER", u));
      if (v.userSudo) add("USER_SUDO", "yes");
    }
    if (v.webui) {
      const h = !t("webuiHash") ? "set a password for the web interface" : checks.webuiHash(t("webuiHash")); need("webuiHash", h, h);
      let pe = ""; if (t("webuiPort")) { pe = !isInt(t("webuiPort"), 1, 65535) ? "1 to 65535" : t("webuiPort") === t("tcpPort") ? "must differ from the Reticulum TCP port" : ""; need("webuiPort", pe, pe); }
      add("WEBUI", "yes");
      if (!h) add("WEBUI_PASSWORD_HASH", t("webuiHash"));
      if (t("webuiPort") && !pe && t("webuiPort") !== "443") add("WEBUI_PORT", t("webuiPort"));
      if (t("webuiDomain") || t("webuiToken")) {
        const de = !t("webuiDomain") ? "needed with the token" : checks.domain(t("webuiDomain")); need("webuiDomain", de, de);
        const te = !t("webuiToken") ? "needed with the domain" : checks.cfToken(t("webuiToken")); need("webuiToken", te, te);
        if (!de) add("WEBUI_DOMAIN", t("webuiDomain").toLowerCase());
        if (!te) add("CLOUDFLARE_API_TOKEN", t("webuiToken"));
      }
      if (t("webuiEmail")) { const ee = checks.email(t("webuiEmail")); need("webuiEmail", ee, ee); if (!ee) add("ACME_EMAIL", t("webuiEmail")); }
    }
    if (t("wgConfig")) {
      const text = (v.wgConfig || "").replace(/\r\n/g, "\n").trim() + "\n", probs = wireguardProblems(text);
      need("wgConfig", probs.length, probs.slice(0, 2).join("; ") + (probs.length > 2 ? " (and " + (probs.length - 2) + " more)" : ""));
      const ie = t("wgIface") && !/^[A-Za-z0-9_=+.-]{1,15}$/.test(t("wgIface")) ? "1-15 characters: letters, digits and _ = + . -" : ""; need("wgIface", ie, ie);
      if (!probs.length) add("WIREGUARD_CONFIG_B64", toBase64(text));
      if (t("wgIface") && !ie && t("wgIface") !== "wg0") add("WIREGUARD_INTERFACE", t("wgIface"));
    }
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

  const api = { build, checks, literal, wireguardProblems };
  if (typeof module !== "undefined" && module.exports) module.exports = api; else root.BobcatConfig = api;
})(typeof window !== "undefined" ? window : globalThis);
