// SHA-512 crypt ($6$, 5000 rounds), as used by /etc/shadow, in plain JavaScript so a password can be hashed in the
// browser without leaving the page. Follows Ulrich Drepper's specification. Works in the browser and in Node.
(function (root) {
  "use strict";
  const K = [
    0x428a2f98, 0xd728ae22, 0x71374491, 0x23ef65cd, 0xb5c0fbcf, 0xec4d3b2f, 0xe9b5dba5, 0x8189dbbc, 0x3956c25b, 0xf348b538, 0x59f111f1, 0xb605d019, 0x923f82a4, 0xaf194f9b, 0xab1c5ed5, 0xda6d8118,
    0xd807aa98, 0xa3030242, 0x12835b01, 0x45706fbe, 0x243185be, 0x4ee4b28c, 0x550c7dc3, 0xd5ffb4e2, 0x72be5d74, 0xf27b896f, 0x80deb1fe, 0x3b1696b1, 0x9bdc06a7, 0x25c71235, 0xc19bf174, 0xcf692694,
    0xe49b69c1, 0x9ef14ad2, 0xefbe4786, 0x384f25e3, 0x0fc19dc6, 0x8b8cd5b5, 0x240ca1cc, 0x77ac9c65, 0x2de92c6f, 0x592b0275, 0x4a7484aa, 0x6ea6e483, 0x5cb0a9dc, 0xbd41fbd4, 0x76f988da, 0x831153b5,
    0x983e5152, 0xee66dfab, 0xa831c66d, 0x2db43210, 0xb00327c8, 0x98fb213f, 0xbf597fc7, 0xbeef0ee4, 0xc6e00bf3, 0x3da88fc2, 0xd5a79147, 0x930aa725, 0x06ca6351, 0xe003826f, 0x14292967, 0x0a0e6e70,
    0x27b70a85, 0x46d22ffc, 0x2e1b2138, 0x5c26c926, 0x4d2c6dfc, 0x5ac42aed, 0x53380d13, 0x9d95b3df, 0x650a7354, 0x8baf63de, 0x766a0abb, 0x3c77b2a8, 0x81c2c92e, 0x47edaee6, 0x92722c85, 0x1482353b,
    0xa2bfe8a1, 0x4cf10364, 0xa81a664b, 0xbc423001, 0xc24b8b70, 0xd0f89791, 0xc76c51a3, 0x0654be30, 0xd192e819, 0xd6ef5218, 0xd6990624, 0x5565a910, 0xf40e3585, 0x5771202a, 0x106aa070, 0x32bbd1b8,
    0x19a4c116, 0xb8d2d0c8, 0x1e376c08, 0x5141ab53, 0x2748774c, 0xdf8eeb99, 0x34b0bcb5, 0xe19b48a8, 0x391c0cb3, 0xc5c95a63, 0x4ed8aa4a, 0xe3418acb, 0x5b9cca4f, 0x7763e373, 0x682e6ff3, 0xd6b2b8a3,
    0x748f82ee, 0x5defb2fc, 0x78a5636f, 0x43172f60, 0x84c87814, 0xa1f0ab72, 0x8cc70208, 0x1a6439ec, 0x90befffa, 0x23631e28, 0xa4506ceb, 0xde82bde9, 0xbef9a3f7, 0xb2c67915, 0xc67178f2, 0xe372532b,
    0xca273ece, 0xea26619c, 0xd186b8c7, 0x21c0c207, 0xeada7dd6, 0xcde0eb1e, 0xf57d4f7f, 0xee6ed178, 0x06f067aa, 0x72176fba, 0x0a637dc5, 0xa2c898a6, 0x113f9804, 0xbef90dae, 0x1b710b35, 0x131c471b,
    0x28db77f5, 0x23047d84, 0x32caab7b, 0x40c72493, 0x3c9ebe0a, 0x15c9bebc, 0x431d67c4, 0x9c100d4c, 0x4cc5d4be, 0xcb3e42b6, 0x597f299c, 0xfc657e2a, 0x5fcb6fab, 0x3ad6faec, 0x6c44198c, 0x4a475817];
  const H0 = [0x6a09e667, 0xf3bcc908, 0xbb67ae85, 0x84caa73b, 0x3c6ef372, 0xfe94f82b, 0xa54ff53a, 0x5f1d36f1, 0x510e527f, 0xade682d1, 0x9b05688c, 0x2b3e6c1f, 0x1f83d9ab, 0xfb41bd6b, 0x5be0cd19, 0x137e2179];
  const W = new Uint32Array(160);

  // 64-bit words are kept as (hi, lo) pairs of 32-bit integers.
  function sha512(msg) {
    const n = msg.length, padded = new Uint8Array(((n + 17 + 127) >> 7) << 7);
    padded.set(msg); padded[n] = 0x80;
    const dv = new DataView(padded.buffer), bits = n * 8;
    dv.setUint32(padded.length - 8, Math.floor(bits / 4294967296)); dv.setUint32(padded.length - 4, bits >>> 0);
    const h = Uint32Array.from(H0);
    for (let off = 0; off < padded.length; off += 128) {
      for (let i = 0; i < 32; i++) W[i] = dv.getUint32(off + i * 4);
      for (let i = 16; i < 80; i++) {
        const h15 = W[(i - 15) * 2], l15 = W[(i - 15) * 2 + 1], h2 = W[(i - 2) * 2], l2 = W[(i - 2) * 2 + 1];
        const s0h = ((h15 >>> 1) | (l15 << 31)) ^ ((h15 >>> 8) | (l15 << 24)) ^ (h15 >>> 7);
        const s0l = ((l15 >>> 1) | (h15 << 31)) ^ ((l15 >>> 8) | (h15 << 24)) ^ ((l15 >>> 7) | (h15 << 25));
        const s1h = ((h2 >>> 19) | (l2 << 13)) ^ ((l2 >>> 29) | (h2 << 3)) ^ (h2 >>> 6);
        const s1l = ((l2 >>> 19) | (h2 << 13)) ^ ((h2 >>> 29) | (l2 << 3)) ^ ((l2 >>> 6) | (h2 << 26));
        const lo = (W[(i - 16) * 2 + 1] >>> 0) + (s0l >>> 0) + (W[(i - 7) * 2 + 1] >>> 0) + (s1l >>> 0);
        W[i * 2 + 1] = lo;
        W[i * 2] = (W[(i - 16) * 2] + s0h + W[(i - 7) * 2] + s1h + Math.floor(lo / 4294967296)) >>> 0;
      }
      let ah = h[0], al = h[1], bh = h[2], bl = h[3], ch = h[4], cl = h[5], dh = h[6], dl = h[7],
        eh = h[8], el = h[9], fh = h[10], fl = h[11], gh = h[12], gl = h[13], hh = h[14], hl = h[15];
      for (let i = 0; i < 80; i++) {
        const S1h = ((eh >>> 14) | (el << 18)) ^ ((eh >>> 18) | (el << 14)) ^ ((el >>> 9) | (eh << 23));
        const S1l = ((el >>> 14) | (eh << 18)) ^ ((el >>> 18) | (eh << 14)) ^ ((eh >>> 9) | (el << 23));
        const chh = (eh & fh) ^ (~eh & gh), chl = (el & fl) ^ (~el & gl);
        const t1l = (hl >>> 0) + (S1l >>> 0) + (chl >>> 0) + K[i * 2 + 1] + (W[i * 2 + 1] >>> 0);
        const t1h = (hh + S1h + chh + K[i * 2] + W[i * 2] + Math.floor(t1l / 4294967296)) >>> 0, t1lo = t1l >>> 0;
        const S0h = ((ah >>> 28) | (al << 4)) ^ ((al >>> 2) | (ah << 30)) ^ ((al >>> 7) | (ah << 25));
        const S0l = ((al >>> 28) | (ah << 4)) ^ ((ah >>> 2) | (al << 30)) ^ ((ah >>> 7) | (al << 25));
        const mjh = (ah & bh) ^ (ah & ch) ^ (bh & ch), mjl = (al & bl) ^ (al & cl) ^ (bl & cl);
        const t2l = (S0l >>> 0) + (mjl >>> 0), t2h = (S0h + mjh + Math.floor(t2l / 4294967296)) >>> 0, t2lo = t2l >>> 0;
        hh = gh; hl = gl; gh = fh; gl = fl; fh = eh; fl = el;
        const nel = (dl >>> 0) + t1lo; el = nel >>> 0; eh = (dh + t1h + Math.floor(nel / 4294967296)) >>> 0;
        dh = ch; dl = cl; ch = bh; cl = bl; bh = ah; bl = al;
        const nal = t1lo + t2lo; al = nal >>> 0; ah = (t1h + t2h + Math.floor(nal / 4294967296)) >>> 0;
      }
      const v = [ah, al, bh, bl, ch, cl, dh, dl, eh, el, fh, fl, gh, gl, hh, hl];
      for (let i = 0; i < 16; i += 2) {
        const lo = (h[i + 1] >>> 0) + (v[i + 1] >>> 0);
        h[i + 1] = lo; h[i] = (h[i] + v[i] + Math.floor(lo / 4294967296)) >>> 0;
      }
    }
    const out = new Uint8Array(64), ov = new DataView(out.buffer);
    for (let i = 0; i < 16; i++) ov.setUint32(i * 4, h[i]);
    return out;
  }

  const cat = (...parts) => { const o = new Uint8Array(parts.reduce((a, p) => a + p.length, 0)); let k = 0; for (const p of parts) { o.set(p, k); k += p.length; } return o; };
  const rep = (b, n) => { const o = new Uint8Array(n); for (let i = 0; i < n; i++) o[i] = b[i % b.length]; return o; };
  const ALPHA = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
  const ORDER = [[0, 21, 42], [22, 43, 1], [44, 2, 23], [3, 24, 45], [25, 46, 4], [47, 5, 26], [6, 27, 48], [28, 49, 7], [50, 8, 29], [9, 30, 51], [31, 52, 10], [53, 11, 32],
    [12, 33, 54], [34, 55, 13], [56, 14, 35], [15, 36, 57], [37, 58, 16], [59, 17, 38], [18, 39, 60], [40, 61, 19], [62, 20, 41]];

  function hash(password, salt, rounds) {
    const enc = new TextEncoder(), pw = enc.encode(password), s = enc.encode(salt), R = rounds || 5000;
    const B = sha512(cat(pw, s, pw));
    const parts = [pw, s];
    for (let n = pw.length; n > 0; n -= 64) parts.push(B.subarray(0, Math.min(64, n)));
    for (let i = pw.length; i > 0; i >>= 1) parts.push(i & 1 ? B : pw);
    let A = sha512(cat(...parts));
    const P = rep(sha512(rep(pw, pw.length * pw.length)), pw.length);
    const S = rep(sha512(rep(s, s.length * (16 + A[0]))), s.length);
    for (let i = 0; i < R; i++) {
      A = sha512(cat(i & 1 ? P : A, i % 3 ? S : new Uint8Array(0), i % 7 ? P : new Uint8Array(0), i & 1 ? A : P));
    }
    let out = "";
    const emit = (w, n) => { for (let i = 0; i < n; i++) { out += ALPHA[w & 63]; w >>>= 6; } };
    for (const [a, b, c] of ORDER) emit((A[a] << 16) | (A[b] << 8) | A[c], 4);
    emit(A[63], 2);
    return "$6$" + (R === 5000 ? "" : "rounds=" + R + "$") + salt + "$" + out;
  }

  function randomSalt() {
    const r = new Uint8Array(16); (root.crypto || require("node:crypto").webcrypto).getRandomValues(r);
    let s = ""; for (const b of r) s += ALPHA[b & 63]; return s;
  }

  const api = { sha512, hash, randomSalt, make: (password) => hash(password, randomSalt()) };
  if (typeof module === "object" && module.exports) module.exports = api; else root.Sha512Crypt = api;
})(typeof self !== "undefined" ? self : globalThis);
