// PBKDF2-HMAC-SHA256 password hashes for the rnsd web interface, made with the browser's WebCrypto so the password
// never leaves the page. Format: pbkdf2-sha256$<iterations>$<salt hex>$<hash hex> (what rnsd-webui and the installer accept).
(function (root) {
  "use strict";
  const ITERATIONS = 200000;
  const hex = (u8) => [...u8].map((b) => b.toString(16).padStart(2, "0")).join("");
  const unhex = (s) => Uint8Array.from(s.match(/../g) || [], (h) => parseInt(h, 16));
  const subtle = () => (root.crypto && root.crypto.subtle) || require("node:crypto").webcrypto.subtle;
  const random = (n) => (root.crypto && root.crypto.getRandomValues ? root.crypto : require("node:crypto").webcrypto).getRandomValues(new Uint8Array(n));

  async function hash(password, saltHex, iterations) {
    const salt = unhex(saltHex), n = iterations || ITERATIONS;
    const key = await subtle().importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveBits"]);
    const bits = await subtle().deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations: n }, key, 256);
    return `pbkdf2-sha256$${n}$${saltHex}$${hex(new Uint8Array(bits))}`;
  }
  const api = { hash, make: (password) => hash(password, hex(random(16))), ITERATIONS };
  if (typeof module === "object" && module.exports) module.exports = api; else root.WebuiHash = api;
})(typeof self !== "undefined" ? self : globalThis);
